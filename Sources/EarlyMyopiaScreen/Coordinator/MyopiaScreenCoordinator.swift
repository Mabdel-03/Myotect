import Combine
import Foundation
import SwiftUI

/// Drives the screening flow: setup to distance lock, warm-up, high-contrast gate,
/// randomized low-contrast red/green, and results. An `ObservableObject` that publishes the state
/// SwiftUI screens render.
///
/// The acuity rules live in ``AcuityStaircaseEngine``; sizing in ``OptotypeSizing`` (against the
/// injected ``ScreenCalibrationProviding``); colors in ``ContrastPalette``; distance policy in
/// ``DistanceStabilityEvaluator`` + ``DistanceBandGate``. The coordinator wires them together,
/// owns the session record, and enforces the protocol (e.g. the gate blocking low-contrast,
/// randomized condition order, distance-invalid pause/repeat, provenance-validated scoring).
@MainActor
final class MyopiaScreenCoordinator: ObservableObject {

    // MARK: Published state
    @Published private(set) var phase: ScreenPhase = .setup
    /// The optotype currently shown (letter + colors + size in points). Nil between trials.
    @Published private(set) var currentStimulus: Stimulus?
    /// Live distance guidance shown on the distance-lock screen.
    @Published private(set) var distanceStatus: DistanceStatus = .noFace
    @Published private(set) var liveDistanceCM: Double = 0
    /// True when a trial is paused because distance left the valid band.
    @Published private(set) var isPausedForDistance = false
    /// Warm-up progress (0...config.warmupLetterCount).
    @Published private(set) var warmupCompleted = 0
    /// The finished session, available on the results screen.
    @Published private(set) var session: MyopiaScreenSession?
    /// How the current trial takes its answer: live voice, or the clinician keypad after
    /// escalation. Sticky manual mode persists across trials until explicitly restored.
    @Published private(set) var inputMode: TrialInputMode = .voice
    /// Operator-facing status of the recognition channel (never shown to the child).
    @Published private(set) var listeningStatus: ListeningStatus = .idle
    /// A structural recognition failure needing operator action (Settings deep link / keypad).
    @Published var serviceAlert: RecognitionServiceFailure?
    /// Distance-guidance pill state (lock screen and in-trial overlay).
    @Published private(set) var guidance: DistanceGuidanceState = .hidden

    enum TrialInputMode: Equatable {
        case voice
        case manualFallback(sticky: Bool)
    }

    enum ListeningStatus: Equatable {
        case idle, listening, heardFiller, heardNothing, heardUnintelligible,
             ambiguousAnswer, speaking, escalatedToClinician, micUnavailable
    }

    /// Read-only snapshot of the in-progress session record (trials/results accumulated so far),
    /// before `session` is published at completion. Exposed for observation and testing.
    var currentSessionSnapshot: MyopiaScreenSession { mutableSession }

    struct Stimulus: Equatable {
        let letter: String
        let condition: ColorCondition
        let colors: OptotypeColors
        /// The full sizing spec the view renders from. Because a damped re-size candidate is never
        /// published, this is by construction the spec actually on screen — the sole source of
        /// provenance when the presentation is scored.
        let spec: OptotypeRenderSpec
        let acuityDenominator: Int

        var fontPoints: Double { Double(spec.fontPointSize) }
    }

    // MARK: Dependencies
    let config: ScreenConfig
    private let distance: DistanceProvider
    private let speech: LetterRecognitionService
    /// Clinician keypad service — always present so escalation has somewhere to go.
    let fallback: ManualClinicianService
    /// Patient-facing audio prompts. Silent + synchronous by default (tests/previews); the root
    /// view injects the real `SpeechAnnouncer`.
    private let announcer: PatientAudioPrompting
    private let calibration: ScreenCalibrationProviding
    private let brightness: BrightnessController
    private let store: SessionStore
    /// Short side of the screen in points; bounds the derived optotype square.
    private let screenShortSidePoints: Double
    /// Deterministic order for the two low-contrast conditions. Injected for tests; nil means random.
    private let lowContrastOrderOverride: [ColorCondition]?

    // MARK: Run state
    private var stability: DistanceStabilityEvaluator
    /// Boundary hysteresis for in-trial pause/resume (pause at the band edge, resume only inside
    /// the inset band after a fresh dwell lock).
    private let bandGate: DistanceBandGate
    /// Last sample the provider vouched for; used to size a re-presented stimulus when the
    /// instantaneous pull happens to miss (e.g. between anchor updates).
    private var lastValidSample: DistanceSample?
    /// Distance the currently visible stimulus was sized for (recorded per trial).
    private var currentSizingDistanceCM: Double?
    /// The validated calibration snapshotted when the session began; every stimulus in the
    /// session is sized against it, and scoring re-validates provenance against the LIVE
    /// calibration so a mid-session change can never mis-score.
    private var sessionCalibration: ScreenCalibration?
    /// Derived per-device colored-square side, computed once at session begin.
    private(set) var squareSidePoints: Double = 0
    private var engine: AcuityStaircaseEngine?
    private var activeCondition: ColorCondition?
    private var lowContrastOrder: [ColorCondition] = []
    private var lowContrastResults: [ColorCondition: AcuityConditionResult] = [:]
    private var trialNumber = 0
    private var trialCounter = 0
    private var currentLetter = ""
    private var stimulusShownAt: Date?
    private var mutableSession: MyopiaScreenSession
    /// Bumped whenever recognition is cancelled so a callback already in flight becomes a no-op.
    private var recognitionGeneration = 0
    private var retryPolicy: RetryEscalationPolicy
    private var promptThrottle: PromptThrottle
    /// Set when `listen()` was deferred because the announcer was speaking; the speech-finished
    /// event re-arms it after the configured delay.
    private var pendingListenAfterSpeech = false
    private var speechEventsSub: AnyCancellable?
    private var captureEventsSub: AnyCancellable?
    private var okDismissTask: Task<Void, Never>?
    /// Bumped whenever the presentation context is torn down (phase clear, back-navigation,
    /// teardown), so a deferred prompt completion or re-arm task from the old context no-ops.
    private var presentationEpoch = 0

    private var isTrialPhase: Bool {
        switch phase {
        case .warmup, .highContrastGate, .lowContrast: return true
        default: return false
        }
    }

    /// The continuous-capture side of the speech service, when it has one (the mock does not).
    private var capture: ContinuousCaptureControlling? { speech as? ContinuousCaptureControlling }

    init(config: ScreenConfig = ScreenConfig(),
         distance: DistanceProvider,
         speech: LetterRecognitionService,
         fallback: ManualClinicianService = ManualClinicianService(),
         announcer: PatientAudioPrompting? = nil,
         calibration: ScreenCalibrationProviding,
         brightness: BrightnessController = BrightnessController(),
         store: SessionStore = SessionStore(),
         screenShortSidePoints: Double = 393,
         lowContrastOrderOverride: [ColorCondition]? = nil,
         now: Date = Date(),
         sessionID: String = UUID().uuidString,
         deviceModel: String? = nil,
         appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") {
        // `UIDevice.current` is main-actor isolated; resolve it here (this init is @MainActor)
        // rather than in a nonisolated default-argument context.
        let resolvedDeviceModel = deviceModel ?? UIDevice.current.model
        self.config = config
        self.distance = distance
        self.speech = speech
        self.fallback = fallback
        self.announcer = announcer ?? SilentAnnouncer()
        self.calibration = calibration
        self.brightness = brightness
        self.store = store
        self.screenShortSidePoints = screenShortSidePoints
        self.lowContrastOrderOverride = lowContrastOrderOverride
        self.retryPolicy = RetryEscalationPolicy(config: config.retryConfig)
        self.promptThrottle = PromptThrottle(minInterval: config.distancePromptMinIntervalSeconds)
        self.stability = DistanceStabilityEvaluator(
            target: config.targetDistanceCM,
            validRange: config.validDistanceRangeCM,
            window: config.distanceStableWindowSeconds,
            maxStandardDeviation: config.maxDistanceSDCM)
        self.bandGate = DistanceBandGate(
            band: config.validDistanceRangeCM,
            maxInsetCM: config.resumeInsetMaxCM,
            insetFraction: config.resumeInsetFraction)
        self.mutableSession = MyopiaScreenSession(
            sessionID: sessionID,
            startedAt: now,
            completedAt: nil,
            appVersion: appVersion,
            deviceModel: resolvedDeviceModel,
            ppiUsed: 0,
            targetDistanceCM: config.targetDistanceCM,
            weberContrast: config.lowContrastWeber,
            letterSet: config.letterSet,
            highContrast: nil,
            lowContrastRed: nil,
            lowContrastGreen: nil,
            duochromeDeltaLogMAR: nil,
            interpretation: "notComputed",
            trials: [],
            aborted: false,
            abortReason: nil)

        speechEventsSub = self.announcer.events.sink { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, event == .finished, self.pendingListenAfterSpeech else { return }
                self.pendingListenAfterSpeech = false
                let epoch = self.presentationEpoch
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let delay = self.config.listenResumeAfterSpeechSeconds
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    // Re-arm only the exact deferred state this task was spawned for: same
                    // presentation context, still waiting on speech, letter still up.
                    guard epoch == self.presentationEpoch,
                          self.listeningStatus == .speaking,
                          !self.isPausedForDistance,
                          self.currentStimulus != nil else { return }
                    self.listen()
                }
            }
        }
        captureEventsSub = (speech as? ContinuousCaptureControlling)?.captureEvents
            .sink { [weak self] event in
                MainActor.assumeIsolated { self?.handleCaptureEvent(event) }
            }
    }

    private func handleCaptureEvent(_ event: CaptureEvent) {
        switch event {
        case .captureStarted:
            // The engine applied .playAndRecord and OWNS the session now: the announcer must
            // speak under it rather than flipping to .playback (which would silence the tap).
            announcer.setMicrophoneCaptureActive(true)
        case .interruptionBegan:
            cancelRecognition()
        case .interruptionEnded, .routeChanged:
            // The engine was rebuilt; re-arm recognition on the letter still on screen.
            guard isTrialPhase, !isPausedForDistance, currentStimulus != nil else { return }
            listen()
        case .failed(let failure):
            serviceAlert = failure
            guard isTrialPhase else { return }
            listeningStatus = .micUnavailable
            _ = retryPolicy.actionForServiceFailure()
            escalateCurrentPresentation()
        }
    }

    // MARK: - Lifecycle

    /// Called when the setup screen's checks all pass.
    ///
    /// Provider callbacks (`onUpdate`, recognition completion) are contractually delivered on the
    /// main thread, so we hop straight onto the main actor with `assumeIsolated` rather than a
    /// deferred `Task`. This keeps the flow synchronous and deterministic for tests.
    /// Nil when the display can hold the protocol's worst-case optotype (or calibration is still
    /// pending, which the calibration row covers); otherwise a blocking setup message.
    var displayFitProblem: String? {
        guard case .validated(let cal) = calibration.status else { return nil }
        do {
            _ = try config.optotypeSquareSide(calibration: cal,
                                              screenShortSidePoints: screenShortSidePoints)
            return nil
        } catch {
            let coarsest = config.acuityLevels.max() ?? 200
            let farCM = Int(config.validDistanceRangeCM.upperBound)
            return "This display is too small for the 20/\(coarsest) letter at \(farCM) cm."
        }
    }

    /// `startInManualMode` starts the whole screening on the clinician keypad (sticky) — the
    /// setup screen offers it when the speech model failed to load or the microphone was denied,
    /// so a broken voice path never blocks a screening entirely.
    func beginAfterSetup(startInManualMode: Bool = false) {
        // Hard gate (the setup UI already blocks; this is the backstop): a session never starts
        // without a validated calibration and a display that fits the worst-case optotype.
        guard case .validated(let cal) = calibration.status,
              let square = try? config.optotypeSquareSide(
                  calibration: cal, screenShortSidePoints: screenShortSidePoints) else { return }
        if startInManualMode {
            // Register stickiness in the policy too, or the first resolved letter's
            // inputMode recomputation would silently revert to voice.
            retryPolicy.forceStickyManual()
            inputMode = .manualFallback(sticky: true)
        }
        sessionCalibration = cal
        squareSidePoints = square
        mutableSession.calibration = cal
        mutableSession.ppiUsed = cal.pointsPerMillimeter * cal.nativeScale * 25.4
        brightness.lock(level: config.testBrightness)
        // The provider is headless and owned by the coordinator: it runs from here until
        // teardown()/completeSession(), so live distance keeps flowing through warm-up and every
        // trial — no view controls the session lifecycle.
        distance.onUpdate = { [weak self] validity in
            MainActor.assumeIsolated { self?.handleDistanceUpdate(validity) }
        }
        distance.start()
        phase = .distanceLock
        stability.reset()
    }

    /// Restores brightness and stops providers. Call on disappear, abort, or backgrounding.
    func teardown() {
        presentationEpoch &+= 1
        pendingListenAfterSpeech = false
        distance.stop()
        speech.cancel()
        capture?.endCaptureSession()
        fallback.cancel()
        announcer.setMicrophoneCaptureActive(false)
        announcer.stop()
        brightness.restore()
    }

    func abort(reason: String) {
        mutableSession.aborted = true
        mutableSession.abortReason = reason
        teardown()
        phase = .aborted(reason: reason)
    }

    /// Forwarded from the root view on scene-background. Cancels any in-flight recognition,
    /// pauses an active trial (it will only resume after a fresh dwell re-lock), and restores
    /// brightness. ARKit interrupts its own session on background; the provider's interruption
    /// handling covers the session side.
    func handleBackground() {
        presentationEpoch &+= 1
        pendingListenAfterSpeech = false
        cancelRecognition()
        capture?.endCaptureSession()
        announcer.setMicrophoneCaptureActive(false)
        announcer.stop()
        switch phase {
        case .warmup, .highContrastGate, .lowContrast:
            isPausedForDistance = true
            guidance = .warning(message: "Screening paused")
        case .distanceLock:
            stability.reset()
        default:
            break
        }
        brightness.restore()
    }

    /// Forwarded from the root view on return to foreground. Re-locks brightness and restarts the
    /// provider if the interruption left it idle. A paused trial stays paused until the child
    /// re-locks inside the resume band — foreground alone never resumes scoring.
    func handleForeground() {
        switch phase {
        case .distanceLock, .warmup, .highContrastGate, .lowContrast:
            brightness.lock(level: config.testBrightness)
            if distance.state == .idle { distance.start() }
            if isTrialPhase, inputMode == .voice {
                capture?.beginCaptureSession()
            }
        default:
            break
        }
    }

    // MARK: - Manual navigation

    /// Returns to the START of the phase preceding the current one and re-runs it cleanly.
    /// From `.setup` (or a terminal phase) there is no in-flow predecessor, so this returns `false`
    /// and the caller dismisses the whole flow. Returns `true` when a back transition was handled.
    @discardableResult
    func goBack() -> Bool {
        switch phase {
        case .setup, .results, .aborted:
            return false
        case .distanceLock:
            resetRunStateForBack()
            distance.stop()
            capture?.endCaptureSession()
            announcer.setMicrophoneCaptureActive(false)
            currentStimulus = nil
            phase = .setup
            return true
        case .warmup:
            resetRunStateForBack()
            restartDistanceLock()
            return true
        case .highContrastGate:
            resetRunStateForBack()
            enterWarmup()
            return true
        case .lowContrast:
            resetRunStateForBack()
            startCondition(.highContrast)
            return true
        }
    }

    /// Manually advances to the START of the next phase, skipping the current test WITHOUT recording
    /// a result for it. Already-recorded earlier results are kept. Returns `false` on a terminal
    /// phase (no successor). The setup case mirrors the "Begin" action.
    @discardableResult
    func goNext() -> Bool {
        switch phase {
        case .results, .aborted:
            return false
        case .setup:
            beginAfterSetup()       // setup to distanceLock (same as Begin)
            return true
        case .distanceLock:
            // The distance provider is already running from beginAfterSetup(); just enter warm-up.
            clearTrialRunState()
            enterWarmup()
            return true
        case .warmup:
            clearTrialRunState()
            startCondition(.highContrast)
            return true
        case .highContrastGate:
            // Skip the gate with no recorded result and proceed to the low-contrast sequence.
            clearTrialRunState()
            beginLowContrastSequence()
            return true
        case .lowContrast:
            // Skip the current low-contrast condition (no result) and run the next, or complete.
            clearTrialRunState()
            advanceLowContrast()
            return true
        }
    }

    /// Clears transient per-trial run state (engine, active condition, in-flight recognition) so the
    /// next phase starts clean. Unlike ``resetRunStateForBack()`` this keeps the session record,
    /// used when skipping FORWARD, where earlier results should be preserved.
    private func clearTrialRunState() {
        // Invalidate deferred work FIRST: announcer.stop() below fires any pending prompt
        // completion synchronously, and it must find a dead context.
        presentationEpoch &+= 1
        pendingListenAfterSpeech = false
        cancelRecognition()
        announcer.stop()
        okDismissTask?.cancel()
        guidance = .hidden
        isPausedForDistance = false
        currentStimulus = nil
        currentSizingDistanceCM = nil
        engine = nil
        activeCondition = nil
        trialNumber = 0
        currentLetter = ""
        stimulusShownAt = nil
    }

    /// Rolls back transient run state and the session record that the abandoned phase wrote, so the
    /// re-run starts clean. Does not touch the brightness lock or the distance provider lifecycle.
    private func resetRunStateForBack() {
        clearTrialRunState()
        // A clean phase re-run also clears the alert and a NON-sticky keypad escalation; sticky
        // manual mode was the clinician's explicit choice and survives.
        serviceAlert = nil
        if case .manualFallback(sticky: false) = inputMode {
            inputMode = .voice
        }
        mutableSession.trials.removeAll()
        mutableSession.highContrast = nil
        mutableSession.lowContrastRed = nil
        mutableSession.lowContrastGreen = nil
        mutableSession.duochromeDeltaLogMAR = nil
        mutableSession.interpretation = "notComputed"
        lowContrastOrder = []
        lowContrastResults = [:]
    }

    /// Re-enters the distance-lock phase. `onUpdate` is already wired and brightness already locked
    /// from the initial `beginAfterSetup()`, so we only restart the provider and stability window.
    private func restartDistanceLock() {
        capture?.endCaptureSession()
        announcer.setMicrophoneCaptureActive(false)
        distance.stop()
        distance.start()
        stability.reset()
        promptThrottle.reset()
        guidance = .hidden
        phase = .distanceLock
    }

    // MARK: - Distance handling

    private func handleDistanceUpdate(_ validity: DistanceValidity) {
        if case .valid(let sample) = validity {
            lastValidSample = sample
            liveDistanceCM = sample.distanceCM
        }
        let status = stability.evaluate(validity)

        switch phase {
        case .distanceLock:
            distanceStatus = status
            if status == .locked {
                showLockedConfirmation()
                advanceToWarmup()
            } else {
                updateGuidance(for: status)
            }
        case .warmup, .highContrastGate, .lowContrast:
            distanceStatus = status
            // During trials, leaving the valid band (or losing a trustworthy measurement at all)
            // pauses and invalidates the in-flight answer. Resuming requires BOTH a fresh dwell
            // lock and re-entry into the inset resume band, so the boundary cannot chatter.
            switch validity {
            case .valid(let sample):
                if !isPausedForDistance, bandGate.shouldPause(distanceCM: sample.distanceCM) {
                    pauseForDistance(status: status)
                } else if isPausedForDistance, status == .locked,
                          bandGate.isWithinResumeBand(distanceCM: sample.distanceCM) {
                    resumeFromDistancePause()
                } else if isPausedForDistance {
                    updateGuidance(for: status, pausedDistanceCM: sample.distanceCM)
                } else {
                    // In band and running: track the live distance, half-pixel damped.
                    resizeVisibleStimulus(distanceCM: sample.distanceCM)
                }
            case .outOfRange, .missing, .stale, .unsupported, .interrupted, .failed:
                if !isPausedForDistance {
                    pauseForDistance(status: status)
                } else {
                    updateGuidance(for: status)
                }
            }
        default:
            break
        }
    }

    /// Pauses the active presentation because distance can no longer be trusted (out of band,
    /// face lost, session interrupted/failed, or stale). The in-flight answer is invalidated
    /// and the letter is HIDDEN — a child who walks up to the phone must never get to read the
    /// letter that will be re-presented after re-lock (gold-standard rule).
    private func pauseForDistance(status: DistanceStatus) {
        isPausedForDistance = true
        currentStimulus = nil
        currentSizingDistanceCM = nil
        cancelRecognition()
        updateGuidance(for: status)
    }

    /// Resumes after a fresh dwell lock inside the resume band: the same letter re-presents,
    /// after a brief auto-dismissing "locked in" confirmation.
    private func resumeFromDistancePause() {
        isPausedForDistance = false
        showLockedConfirmation()
        promptThrottle.reset()
        repeatCurrentPresentation()
    }

    /// Maps the evaluated status onto the guidance pill and (throttled) spoken direction. A child
    /// at 2 m cannot read small on-screen text, so directional guidance is spoken as well.
    ///
    /// `pausedDistanceCM` guards against a hysteresis live-lock: a paused child parked INSIDE
    /// the valid band but OUTSIDE the resume band would dwell-lock and still not resume — "hold
    /// still" forever. They get directional guidance toward the resume band instead.
    private func updateGuidance(for status: DistanceStatus, pausedDistanceCM: Double? = nil) {
        okDismissTask?.cancel()
        var effective = status
        if status == .holdSteady || status == .locked,
           let cm = pausedDistanceCM, !bandGate.isWithinResumeBand(distanceCM: cm) {
            effective = cm < bandGate.resumeBand.lowerBound ? .tooClose : .tooFar
        }
        switch effective {
        case .tooFar:
            guidance = .moveCloser
        case .tooClose:
            guidance = .moveFarther
        case .noFace:
            guidance = .warning(message: "I can't see you. Step back into view.")
        case .holdSteady, .locked:
            guidance = .holdSteady
        }
        speakGuidanceIfNeeded(for: effective)
    }

    private func speakGuidanceIfNeeded(for status: DistanceStatus) {
        let prompt: SpokenPrompt?
        switch status {
        case .tooFar: prompt = .moveCloser
        case .tooClose: prompt = .moveFarther
        case .noFace: prompt = .stepIntoView
        case .holdSteady, .locked: prompt = nil
        }
        guard let prompt, promptThrottle.shouldSpeak(prompt) else { return }
        announcer.speak(prompt)
    }

    /// Green "locked in" pill that auto-dismisses (port of the gold OK pill behavior).
    private func showLockedConfirmation() {
        guidance = .ok
        okDismissTask?.cancel()
        okDismissTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(config.guidanceOKDismissSeconds * 1_000_000_000))
            guard !Task.isCancelled, self.guidance == .ok else { return }
            self.guidance = .hidden
        }
    }

    // MARK: - Phase transitions

    private func advanceToWarmup() {
        guard phase == .distanceLock else { return }
        enterWarmup()
    }

    private func enterWarmup() {
        phase = .warmup
        warmupCompleted = 0
        retryPolicy.beginTrial()
        if inputMode == .voice {
            capture?.beginCaptureSession()
        }
        let epoch = presentationEpoch
        announcer.speak(.warmupIntro) { [weak self] in
            guard let self, self.phase == .warmup, epoch == self.presentationEpoch else { return }
            self.presentWarmupLetter()
        }
    }

    /// NOTE: deliberately does NOT reset the retry budget — warm-up retries present a fresh
    /// letter, and resetting per letter would defeat the dead-microphone escalation. The budget
    /// resets on entry, on every resolved letter (`trialResolved`), and after a keypad advance.
    private func presentWarmupLetter() {
        currentLetter = SloanLetter.random(excluding: currentLetter)
        presentStimulus(letter: currentLetter,
                        condition: .highContrast,
                        acuity: config.warmupAcuity)
    }

    /// Warm-up trials are unscored, but the retry/escalation policy applies here too — warm-up is
    /// exactly where a dead microphone is caught before anything is scored. A clean recognition
    /// advances; failures re-prompt with a fresh letter until the cap escalates to the keypad.
    private func handleWarmupOutcome(_ outcome: RecognitionOutcome) {
        switch outcome {
        case .letter:
            retryPolicy.trialResolved(byVoice: inputMode == .voice)
            inputMode = retryPolicy.isStickyManual ? .manualFallback(sticky: true) : .voice
            warmupCompleted += 1
            if warmupCompleted >= config.warmupLetterCount {
                startCondition(.highContrast)
            } else {
                presentWarmupLetter()
            }
        case .ambiguous, .unrecognized:
            if case .manualFallback = inputMode {
                // Keypad "No response" during unscored warm-up: move to a fresh letter with a
                // fresh retry budget.
                retryPolicy.beginTrial()
                presentWarmupLetter()
                return
            }
            listeningStatus = operatorStatus(for: outcome)
            switch retryPolicy.actionForFailedAttempt() {
            case .retry(let withPrompt):
                if withPrompt { announcer.speak(.tryAgain) }
                presentWarmupLetter()
            case .escalateToManual:
                escalateCurrentPresentation()
            }
        case .serviceFailure(let failure):
            serviceAlert = failure
            listeningStatus = .micUnavailable
            _ = retryPolicy.actionForServiceFailure()
            escalateCurrentPresentation()
        }
    }

    private func startCondition(_ condition: ColorCondition) {
        activeCondition = condition
        engine = AcuityStaircaseEngine(config: config.staircaseConfig(gated: condition == .highContrast))
        trialNumber = 0
        if inputMode == .voice {
            capture?.beginCaptureSession()
        }
        switch condition {
        case .highContrast:
            phase = .highContrastGate
            // Spoken once as scoring begins; the low-contrast conditions continue silently.
            let expected = phase
            let epoch = presentationEpoch
            announcer.speak(.testBegins) { [weak self] in
                guard let self, self.phase == expected, epoch == self.presentationEpoch else { return }
                self.presentTrial()
            }
        case .lowContrastRed, .lowContrastGreen:
            phase = .lowContrast(condition)
            presentTrial()
        }
    }

    private func presentTrial() {
        guard let condition = activeCondition, let engine else { return }
        currentLetter = SloanLetter.random(excluding: currentLetter)
        trialNumber += 1
        // A fresh letter resets the retry budget; distance-pause repeats deliberately do not.
        retryPolicy.beginTrial()
        presentStimulus(letter: currentLetter,
                        condition: condition,
                        acuity: engine.currentAcuity)
    }

    private func repeatCurrentPresentation() {
        if phase == .warmup {
            repeatCurrentWarmupLetter()
        } else {
            repeatCurrentTrial()
        }
    }

    /// Re-presents the same warm-up letter after a distance pause.
    private func repeatCurrentWarmupLetter() {
        guard !currentLetter.isEmpty else {
            presentWarmupLetter()
            return
        }
        presentStimulus(letter: currentLetter,
                        condition: .highContrast,
                        acuity: config.warmupAcuity)
    }

    /// Re-presents the same scored letter at the same acuity after a distance pause or ambiguous answer.
    private func repeatCurrentTrial() {
        guard let condition = activeCondition, let engine else { return }
        guard !currentLetter.isEmpty else {
            // Nothing was ever presented (e.g. a pause landed during the condition's spoken
            // intro): start the first trial instead.
            presentTrial()
            return
        }
        presentStimulus(letter: currentLetter,
                        condition: condition,
                        acuity: engine.currentAcuity)
    }

    // MARK: - Recognition

    private func listen() {
        guard !isPausedForDistance else { return }
        // Recognition must never run while the announcer speaks — the prompt's tail would bleed
        // into Whisper's capture window. The speech-finished event re-arms after a settle delay.
        guard !announcer.isSpeaking else {
            pendingListenAfterSpeech = true
            listeningStatus = .speaking
            return
        }
        stimulusShownAt = Date()
        let generation = recognitionGeneration
        let service: LetterRecognitionService
        if case .manualFallback = inputMode {
            service = fallback
            listeningStatus = .escalatedToClinician
        } else {
            service = speech
            listeningStatus = .listening
        }
        service.recognizeOneLetter(timeout: config.recognitionTimeoutSeconds) { [weak self] outcome in
            MainActor.assumeIsolated {
                guard let self, generation == self.recognitionGeneration else { return }
                self.handleOutcome(outcome)
            }
        }
    }

    /// Cancels any in-flight recognition and invalidates a callback that may already be in flight.
    private func cancelRecognition() {
        recognitionGeneration &+= 1
        speech.cancel()
        fallback.cancel()
        listeningStatus = .idle
    }

    private func handleOutcome(_ outcome: RecognitionOutcome) {
        guard !isPausedForDistance else { return }
        // Answers are gated on a fresh, in-band distance sample (gold-standard rule): if the
        // measurement went away between presentation and response, the answer cannot be trusted.
        // The presentation pauses and the same letter repeats after re-lock.
        guard let fresh = distance.validSample(maximumAge: config.maximumSampleAgeSeconds),
              config.validDistanceRangeCM.contains(fresh.distanceCM) else {
            if let stray = distance.validSample(maximumAge: config.maximumSampleAgeSeconds) {
                // Measurement is live but the child left the band: guide them directionally.
                pauseForDistance(status: stray.distanceCM < config.validDistanceRangeCM.lowerBound
                    ? .tooClose : .tooFar)
            } else {
                pauseForDistance(status: .noFace)
            }
            return
        }
        if case .warmup = phase {
            handleWarmupOutcome(outcome)
            return
        }
        handleScoredOutcome(outcome, responseDistanceCM: fresh.distanceCM)
    }

    private func handleScoredOutcome(_ outcome: RecognitionOutcome, responseDistanceCM: Double) {
        guard let engine, let condition = activeCondition else { return }

        switch outcome {
        case .ambiguous, .unrecognized:
            if case .manualFallback = inputMode {
                // Keypad "No response": scored as incorrect (clinical decision) — the staircase
                // must be able to terminate for a child who cannot see or will not answer,
                // exactly like a missed letter on a physical chart.
                score(response: "-", condition: condition, engine: engine,
                      responseDistanceCM: responseDistanceCM)
                return
            }
            listeningStatus = operatorStatus(for: outcome)
            switch retryPolicy.actionForFailedAttempt() {
            case .retry(let withPrompt):
                // The first retry carries a spoken re-prompt; later retries stay silent so a
                // hesitant child isn't nagged every few seconds.
                if withPrompt { announcer.speak(.tryAgain) }
                repeatCurrentTrial()
            case .escalateToManual:
                escalateCurrentPresentation()
            }
        case .serviceFailure(let failure):
            serviceAlert = failure
            listeningStatus = .micUnavailable
            _ = retryPolicy.actionForServiceFailure()
            escalateCurrentPresentation()
        case .letter(let response):
            score(response: response, condition: condition, engine: engine,
                  responseDistanceCM: responseDistanceCM)
        }
    }

    /// The single scored path for voice letters and keypad entries (including "no response").
    private func score(response: String, condition: ColorCondition, engine: AcuityStaircaseEngine,
                       responseDistanceCM: Double) {
        // A response is scored only when the sizing lineage of the letter on screen is still
        // valid against the LIVE calibration (gold-standard rule): a mid-session calibration
        // change pauses instead of mis-scoring.
        guard let provenance = currentStimulus?.spec.provenance,
              let liveCalibration = calibration.currentCalibration,
              provenance.matches(liveCalibration) else {
            pausePresentation()
            return
        }
        retryPolicy.trialResolved(byVoice: inputMode == .voice)
        // Escalation is per-trial: a resolved keypad trial hands the NEXT trial back to voice,
        // unless enough consecutive escalations made manual mode sticky.
        inputMode = retryPolicy.isStickyManual ? .manualFallback(sticky: true) : .voice
        let correct = response == currentLetter
        recordTrial(condition: condition, response: response, correct: correct,
                    responseDistanceCM: responseDistanceCM, provenance: provenance)
        let event = engine.record(correct: correct)
        switch event {
        case .continueSameLevel, .advance, .stepBack:
            presentTrial()
        case .finished(let result):
            finishCondition(condition, result: result)
        }
    }

    /// Hands the current presentation to the clinician keypad and re-arms it. The capture engine
    /// stops — the microphone path just proved unusable.
    private func escalateCurrentPresentation() {
        cancelRecognition()
        capture?.endCaptureSession()
        announcer.setMicrophoneCaptureActive(false)
        inputMode = .manualFallback(sticky: retryPolicy.isStickyManual)
        listeningStatus = .escalatedToClinician
        repeatCurrentPresentation()
    }

    /// Clinician explicitly hands the flow back to voice input (e.g. after fixing the mic).
    func clinicianRestoreVoiceInput() {
        retryPolicy.clinicianRestoredVoice()
        inputMode = .voice
        cancelRecognition()
        capture?.beginCaptureSession()
        if !isPausedForDistance {
            repeatCurrentPresentation()
        }
    }

    private func operatorStatus(for outcome: RecognitionOutcome) -> ListeningStatus {
        switch outcome {
        case .ambiguous: return .ambiguousAnswer
        case .unrecognized(.filler): return .heardFiller
        case .unrecognized(.silence): return .heardNothing
        case .unrecognized(.unintelligible): return .heardUnintelligible
        case .letter, .serviceFailure: return .idle
        }
    }

    private func recordTrial(condition: ColorCondition, response: String, correct: Bool,
                             responseDistanceCM: Double, provenance: SizingProvenance) {
        let latencyMS = stimulusShownAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
        let trial = TrialResult(
            condition: condition,
            acuityDenominator: engine?.currentAcuity ?? 0,
            shownLetter: currentLetter,
            response: response,
            isCorrect: correct,
            distanceCM: responseDistanceCM,
            sizingDistanceCM: currentSizingDistanceCM,
            responseTimeMS: latencyMS,
            trialNumber: trialNumber,
            timestamp: Date(),
            provenance: provenance)
        mutableSession.trials.append(trial)
    }

    // MARK: - Condition completion

    private func finishCondition(_ condition: ColorCondition, result: AcuityLevelResult) {
        let conditionResult = AcuityConditionResult(
            condition: condition,
            finestAcuityDenominator: result.finestAcuityReached,
            logMAR: result.logMAR,
            reachedGate: result.reachedGate)

        switch condition {
        case .highContrast:
            mutableSession.highContrast = conditionResult
            if result.reachedGate {
                beginLowContrastSequence()
            } else {
                // Gate not passed, so do not run the low-contrast conditions.
                mutableSession.interpretation = "highContrastBelowGate"
                completeSession()
            }
        case .lowContrastRed:
            mutableSession.lowContrastRed = conditionResult
            lowContrastResults[condition] = conditionResult
            advanceLowContrast()
        case .lowContrastGreen:
            mutableSession.lowContrastGreen = conditionResult
            lowContrastResults[condition] = conditionResult
            advanceLowContrast()
        }
    }

    private func beginLowContrastSequence() {
        lowContrastOrder = lowContrastOrderOverride ?? ColorCondition.lowContrastConditions.shuffled()
        runNextLowContrast()
    }

    private func advanceLowContrast() {
        if !lowContrastOrder.isEmpty {
            lowContrastOrder.removeFirst()
        }
        runNextLowContrast()
    }

    private func runNextLowContrast() {
        if let next = lowContrastOrder.first {
            startCondition(next)
        } else {
            interpretAndComplete()
        }
    }

    private func interpretAndComplete() {
        mutableSession.recomputeDelta()
        if let delta = mutableSession.duochromeDeltaLogMAR {
            mutableSession.interpretation = delta > 0
                ? "redBetterThanGreen_deltaRecorded"
                : "noRedGreenDifference_deltaRecorded"
        }
        completeSession()
    }

    private func completeSession() {
        mutableSession.completedAt = Date()
        presentationEpoch &+= 1
        currentStimulus = nil
        cancelRecognition()
        // The microphone must not stay hot on the results screen.
        capture?.endCaptureSession()
        announcer.setMicrophoneCaptureActive(false)
        distance.stop()
        brightness.restore()
        _ = try? store.save(mutableSession)
        session = mutableSession
        phase = .results
        guidance = .hidden
        announcer.speak(.allDone)
    }

    // MARK: - Stimulus construction

    /// Presents a letter sized from the CURRENT trusted distance only. On any failure — no
    /// measurement yet, invalid calibration, font unavailable, or the glyph would not fit the
    /// square — the stimulus is hidden and the presentation pauses: a scored letter is never
    /// sized from an assumed distance and never cropped. The existing pause/repeat machinery
    /// re-presents the same letter after re-lock.
    private func presentStimulus(letter: String, condition: ColorCondition, acuity: Int) {
        // A deferred presentation (e.g. a spoken intro's completion) must not fire into a pause;
        // the resume path re-presents the current letter itself.
        guard !isPausedForDistance else { return }
        guard let spec = sizedSpec(acuity: acuity) else {
            pausePresentation()
            return
        }
        let colors = ContrastPalette.colors(for: condition, config: config.contrastConfig())
        currentStimulus = Stimulus(
            letter: letter,
            condition: condition,
            colors: colors,
            spec: spec,
            acuityDenominator: acuity)
        if config.speakEveryTrialPrompt, phase != .warmup {
            announcer.speak(.sayTheLetter)
        }
        listen()
    }

    /// Sizing distance: a fresh valid sample, else the last one the provider vouched for. There
    /// is deliberately no nominal-distance fallback.
    private func sizedSpec(acuity: Int) -> OptotypeRenderSpec? {
        guard let cal = sessionCalibration else { return nil }
        guard let distanceCM = distance.validSample(maximumAge: config.maximumSampleAgeSeconds)?.distanceCM
            ?? lastValidSample?.distanceCM else { return nil }
        guard let font = try? OptotypeSizing.sloanBaseFont(),
              let spec = try? OptotypeSizing.renderSpec(
                  distanceCM: distanceCM,
                  snellenDenominator: acuity,
                  calibration: cal,
                  font: font),
              spec.fitsSquare(side: squareSidePoints, innerMargin: config.optotypeSquareInnerMargin)
        else { return nil }
        currentSizingDistanceCM = distanceCM
        return spec
    }

    /// Hides the stimulus and pauses because it can no longer be presented truthfully.
    private func pausePresentation() {
        currentStimulus = nil
        currentSizingDistanceCM = nil
        isPausedForDistance = true
        cancelRecognition()
        okDismissTask?.cancel()
        guidance = .warning(message: "Waiting for a distance lock…")
    }

    /// Live re-sizing: recompute the spec for the current distance and republish only when the
    /// height moved at least half a physical pixel (or the calibration identity changed). A damped
    /// candidate never overwrites the visible spec, so recorded provenance always describes what
    /// was actually on screen.
    private func resizeVisibleStimulus(distanceCM: Double) {
        guard let stimulus = currentStimulus, let cal = sessionCalibration else { return }
        guard let font = try? OptotypeSizing.sloanBaseFont(),
              let candidate = try? OptotypeSizing.renderSpec(
                  distanceCM: distanceCM,
                  snellenDenominator: stimulus.acuityDenominator,
                  calibration: cal,
                  font: font),
              candidate.fitsSquare(side: squareSidePoints,
                                   innerMargin: config.optotypeSquareInnerMargin)
        else {
            pausePresentation()
            return
        }
        guard OptotypeSizing.needsRender(previousSpec: stimulus.spec, candidateSpec: candidate) else {
            return
        }
        currentSizingDistanceCM = distanceCM
        currentStimulus = Stimulus(
            letter: stimulus.letter,
            condition: stimulus.condition,
            colors: stimulus.colors,
            spec: candidate,
            acuityDenominator: stimulus.acuityDenominator)
    }

    // MARK: - Manual clinician support

    /// Bridges the clinician keypad into the recognition flow.
    func submitManual(letter: String) {
        fallback.submit(letter: letter)
    }

    /// Setup-screen retry after a failed speech-model load.
    func retryWhisperModelPreparation() {
        (speech as? WhisperKitLetterRecognitionService)?.retryModelPreparation()
    }
}
