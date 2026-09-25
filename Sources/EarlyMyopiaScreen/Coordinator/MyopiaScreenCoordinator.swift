import Combine
import Foundation
import SwiftUI

/// Drives the screening flow: setup to distance lock, warm-up, high-contrast acuity,
/// randomized low-contrast red/green, and results. An `ObservableObject` that publishes the state
/// SwiftUI screens render.
///
/// The acuity rules live in ``AcuityStaircaseEngine``; sizing in ``OptotypeSizing`` (against the
/// injected ``ScreenCalibrationProviding``); colors in ``ContrastPalette``; distance policy in
/// ``DistanceStabilityEvaluator`` + ``DistanceBandGate``. The coordinator wires them together,
/// owns the session record, and enforces the protocol (e.g. all three scored conditions always
/// run — the 20/25 result is recorded, never a flow branch — randomized condition order,
/// distance-invalid pause/repeat, provenance-validated scoring).
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
    /// Where the operator-initiated distance capture stands (lock screen only). The Capture
    /// button is live only in `.ready`; `.holding` carries the whole-second countdown.
    @Published private(set) var captureState: DistanceCaptureState = .waitingForSubject
    /// Transient "that didn't work — try again" notice after a voided hold; clears itself after
    /// `captureRetryNoticeSeconds` (gold retry-notice behavior).
    @Published private(set) var captureRetryNotice: String?
    /// True during the inter-stimulus blank: a stimulus is committed but the square renders black
    /// and the letter is hidden, so one letter never swaps straight into the next. Recognition is
    /// deliberately NOT armed until it clears — an answer must never be timed from a blank field.
    @Published private(set) var isBlankInterval = false
    /// Operator-facing "Heard" line: what the live recognizer last transcribed and how it
    /// classified, for the letter it was shown against. Display only — trials are resolved
    /// solely through the `recognizeOneLetter` callback — and kept across the inter-letter
    /// transition so the operator can still read the previous letter's result; nil when no
    /// service narrates (mock, keypad) and after every presentation teardown.
    @Published private(set) var lastHeard: HeardDiagnostic?

    /// State machine of the operator-initiated capture (port of the gold `CaptureState`).
    enum DistanceCaptureState: Equatable {
        /// No fresh in-band reading to capture — the subject is out of position or untracked.
        case waitingForSubject
        /// A fresh in-band reading exists; waiting on the operator to tap Capture.
        case ready
        /// Hold countdown running; the phone and subject have to stay put.
        case holding(remainingSeconds: Int)
        /// Distance captured; transitioning to warm-up.
        case captured
    }

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
    /// The operator-initiated capture hold (tap anchors it; 2 s steady completes it).
    private var holdTracker: DistanceHoldTracker
    private var captureRetryDismissTask: Task<Void, Never>?
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
    private var currentLetter = ""
    private var stimulusShownAt: Date?
    private var mutableSession: MyopiaScreenSession
    /// Bumped whenever recognition is cancelled so a callback already in flight becomes a no-op.
    private var recognitionGeneration = 0
    private var retryPolicy: RetryEscalationPolicy
    /// Consecutive scored voice trials that ended in the no-input window; the backstop hands the
    /// next letter to the keypad at `config.noInputTrialsBeforeEscalation`.
    private var consecutiveNoInputTrials = 0
    private var promptThrottle: PromptThrottle
    /// Set when `listen()` was deferred because the announcer was speaking; the speech-finished
    /// event re-arms it after the configured delay.
    private var pendingListenAfterSpeech = false
    private var speechEventsSub: AnyCancellable?
    private var captureEventsSub: AnyCancellable?
    private var diagnosticsSub: AnyCancellable?
    private var okDismissTask: Task<Void, Never>?
    /// The in-flight inter-stimulus blank; cancelled by every presentation teardown path.
    private var blankIntervalTask: Task<Void, Never>?
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
        self.holdTracker = DistanceHoldTracker(
            durationSeconds: config.holdDurationSeconds,
            toleranceCM: config.holdToleranceCM)
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
        mutableSession.staircaseProtocol = StaircaseProtocolMetadata(
            config: config.staircaseConfig(gated: true))

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
                          !self.isBlankInterval,
                          self.currentStimulus != nil else { return }
                    self.listen()
                }
            }
        }
        captureEventsSub = (speech as? ContinuousCaptureControlling)?.captureEvents
            .sink { [weak self] event in
                MainActor.assumeIsolated { self?.handleCaptureEvent(event) }
            }
        diagnosticsSub = (speech as? RecognitionDiagnosticsProviding)?.diagnostics
            .sink { [weak self] diagnostic in
                MainActor.assumeIsolated { self?.handleDiagnostic(diagnostic) }
            }
    }

    /// Mirrors the recognizer's narration into ``lastHeard``. A `.listening` diagnostic arrives
    /// as soon as the next letter is armed — 0.25 s after the previous one resolved — so it must
    /// NOT wipe that letter's result; it only fills an empty line. Every other kind replaces it.
    private func handleDiagnostic(_ diagnostic: RecognitionDiagnostic) {
        if case .listening = diagnostic.kind, lastHeard != nil { return }
        // A deferral narrates a window that is still open; one that lands after the trial
        // resolved or was cancelled must not overwrite the result the operator is reading.
        if case .deferredDeadline = diagnostic.kind, listeningStatus != .listening { return }
        lastHeard = HeardDiagnostic(
            text: HeardDiagnosticFormatter.text(for: diagnostic, shownLetter: currentLetter),
            shownLetter: currentLetter,
            at: diagnostic.at)
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
            // The engine was rebuilt; re-arm recognition on the letter still on screen (never
            // mid-blank — the letter is not visible yet).
            guard isTrialPhase, !isPausedForDistance, !isBlankInterval,
                  currentStimulus != nil else { return }
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
        resetCaptureFlow()
    }

    /// Restores brightness and stops providers. Call on disappear, abort, or backgrounding.
    func teardown() {
        presentationEpoch &+= 1
        pendingListenAfterSpeech = false
        cancelBlankInterval()
        resetCaptureFlow()
        distance.stop()
        // Through cancelRecognition so the generation bumps: a service callback already
        // dispatched to the main queue must find a dead context, exactly as on back-navigation.
        cancelRecognition()
        capture?.endCaptureSession()
        announcer.setMicrophoneCaptureActive(false)
        announcer.stop()
        lastHeard = nil
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
        cancelBlankInterval()
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
            resetCaptureFlow()
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
            resetCaptureFlow()
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
            resetCaptureFlow()
            // A manual skip means no capture backs this run — a value left over from an
            // abandoned earlier lock must not be exported as if it did.
            mutableSession.lockedDistanceCM = nil
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
        cancelBlankInterval()
        cancelRecognition()
        announcer.stop()
        okDismissTask?.cancel()
        guidance = .hidden
        isPausedForDistance = false
        currentStimulus = nil
        currentSizingDistanceCM = nil
        engine = nil
        activeCondition = nil
        currentLetter = ""
        stimulusShownAt = nil
        consecutiveNoInputTrials = 0
        lastHeard = nil
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
        // The abandoned run's captured distance must not describe the re-run's lock: it is
        // rewritten by the next hold completion, or stays nil if the lock phase is skipped.
        mutableSession.lockedDistanceCM = nil
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
        resetCaptureFlow()
        promptThrottle.reset()
        guidance = .hidden
        phase = .distanceLock
    }

    // MARK: - Distance handling

    private func handleDistanceUpdate(_ validity: DistanceValidity) {
        if case .valid(let sample) = validity {
            liveDistanceCM = sample.distanceCM
        }
        let status = stability.evaluate(validity)

        switch phase {
        case .distanceLock:
            distanceStatus = status
            // The operator decides when to capture (gold user-initiated flow): a valid reading
            // alone only ENABLES the Capture button; nothing advances until a tapped hold
            // completes its steady window.
            if holdTracker.isActive {
                handleHoldUpdate(validity)
            } else {
                captureState = captureReadiness(validity)
                updateLockPhaseGuidance(for: status)
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

    // MARK: - Operator-initiated distance capture (gold DistanceOptimization hold flow)

    /// Starts the capture hold when the operator taps Capture Distance. The reading at the moment
    /// of the tap becomes the anchor the rest of the hold is judged against. The button is
    /// disabled outside `.ready`, but a tap can land in the same run-loop turn as a tracking
    /// loss, so the fresh pull-side sample is re-checked here (gold rule).
    func beginDistanceCapture() {
        guard phase == .distanceLock, !holdTracker.isActive,
              let sample = distance.validSample(maximumAge: config.maximumSampleAgeSeconds),
              config.validDistanceRangeCM.contains(sample.distanceCM) else { return }
        clearCaptureRetryNotice()
        holdTracker.begin(with: sample)
        captureState = .holding(
            remainingSeconds: max(1, Int(config.holdDurationSeconds.rounded(.up))))
        // The countdown replaces the pill while holding.
        okDismissTask?.cancel()
        guidance = .hidden
        announcer.speak(.holdStill)
    }

    private func handleHoldUpdate(_ validity: DistanceValidity) {
        // The hold must also stay inside the valid band, not just the ±tolerance anchor
        // envelope: an anchor near the band edge could otherwise complete with the subject
        // outside the band — recording an out-of-band lockedDistanceCM and dropping warm-up
        // straight into a distance pause (the same trap the in-band arming rule closes).
        if case .valid(let sample) = validity,
           !config.validDistanceRangeCM.contains(sample.distanceCM) {
            holdTracker.cancel()
            captureState = .waitingForSubject
            showCaptureRetryNotice(for: .movedTooMuch)
            return
        }
        switch holdTracker.update(with: validity) {
        case .progress(let remaining):
            captureState = .holding(remainingSeconds: remaining)
        case .completed(let meanCM, _):
            // The captured value is the mean of the whole steady window — where the subject
            // actually locked — recorded even though the protocol's target distance is fixed.
            mutableSession.lockedDistanceCM = meanCM
            captureState = .captured
            showLockedConfirmation()
            advanceToWarmup()
        case .voided(let reason):
            captureState = captureReadiness(validity)
            showCaptureRetryNotice(for: reason)
        case nil:
            break
        }
    }

    /// The Capture button is live only on a fresh IN-BAND reading. Gold enables it on any valid
    /// sample (the user chooses their own test distance there); Myotect's target is fixed, so
    /// capturing out of band would only walk the child into an immediate trial pause.
    private func captureReadiness(_ validity: DistanceValidity) -> DistanceCaptureState {
        if case .valid(let sample) = validity,
           config.validDistanceRangeCM.contains(sample.distanceCM) {
            return .ready
        }
        return .waitingForSubject
    }

    /// Lock-phase pill: directional guidance only. Once the subject is in band the enabled
    /// Capture button speaks for itself (gold: the status row goes quiet in `.ready`).
    private func updateLockPhaseGuidance(for status: DistanceStatus) {
        okDismissTask?.cancel()
        switch status {
        case .tooFar:
            guidance = .moveCloser
        case .tooClose:
            guidance = .moveFarther
        case .noFace:
            guidance = .warning(message: "I can't see you. Step back into view.")
        case .holdSteady, .locked:
            guidance = .hidden
        }
        // While a void notice is up, its spoken "try again" is playing — the announcer
        // SUPERSEDES rather than queues, so a guidance prompt now would cut it off mid-word.
        // Guidance speech resumes once the notice clears (~2.5 s), like gold's quiet screen.
        guard captureRetryNotice == nil else { return }
        speakGuidanceIfNeeded(for: status)
    }

    private func showCaptureRetryNotice(for reason: DistanceHoldTracker.VoidReason) {
        let notice: String
        let spoken: SpokenPrompt
        switch reason {
        case .movedTooMuch:
            notice = "Moved too much — try again"
            spoken = .movedTooMuch
        case .faceLost:
            notice = "Lost your face — try again"
            spoken = .lostFace
        }
        captureRetryNotice = notice
        announcer.speak(spoken)
        captureRetryDismissTask?.cancel()
        captureRetryDismissTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(
                nanoseconds: UInt64(config.captureRetryNoticeSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.captureRetryNotice = nil
        }
    }

    private func clearCaptureRetryNotice() {
        captureRetryDismissTask?.cancel()
        captureRetryDismissTask = nil
        captureRetryNotice = nil
    }

    /// Returns the capture flow to its starting point: any half-finished hold discarded, any
    /// stale retry message cleared, the button back to waiting on a reading.
    private func resetCaptureFlow() {
        holdTracker.cancel()
        clearCaptureRetryNotice()
        captureState = .waitingForSubject
    }

    /// Pauses the active presentation because distance can no longer be trusted (out of band,
    /// face lost, session interrupted/failed, or stale). The in-flight answer is invalidated
    /// and the letter is HIDDEN. This is deliberately stricter than the gold app, which keeps
    /// the letter visible when merely out of band (hiding only on invalid tracking): a child
    /// who walks up to the phone must never get to read the letter that will be re-presented
    /// after re-lock.
    private func pauseForDistance(status: DistanceStatus) {
        isPausedForDistance = true
        cancelBlankInterval()
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
    /// advances; failures re-prompt with a fresh letter (blanked while the first re-prompt plays,
    /// as on the scored path) until the cap escalates to the keypad.
    ///
    /// A spoken skip counts as a completed practice letter (a heard "skip" proves the voice path
    /// works). Silence deliberately KEEPS the retry → keypad path here rather than the scored
    /// trials' no-input rule: the no-input rule — recorded but uncounted, fresh letter — and its
    /// backstop apply to scored trials only (user decision, PROTOCOL §3).
    private func handleWarmupOutcome(_ outcome: RecognitionOutcome) {
        switch outcome {
        case .letter, .skipped:
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
                guard withPrompt else {
                    presentWarmupLetter()
                    return
                }
                // As on the scored path: blank while the re-prompt plays (the microphone is off
                // during speech) and present the fresh letter in the completion.
                isBlankInterval = true
                let epoch = presentationEpoch
                announcer.speak(.tryAgain) { [weak self] in
                    guard let self, epoch == self.presentationEpoch,
                          !self.isPausedForDistance, self.phase == .warmup else { return }
                    self.presentWarmupLetter()
                }
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
        let gated = condition == .highContrast
        engine = AcuityStaircaseEngine(config: config.staircaseConfig(
            gated: gated,
            startAcuity: gated ? nil : lowContrastStartAcuity))
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
            // A keypad escalation closes the block's capture session (the microphone path just
            // proved unusable). The first voice letter after it re-opens the warm engine and the
            // interruption/route observers — idempotent while a session is already open.
            capture?.beginCaptureSession()
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
        case .skipped:
            // "Skip" is an answer: the child cannot see the letter. Scored as a miss, never
            // retried (PROTOCOL §7).
            consecutiveNoInputTrials = 0
            score(response: TrialResult.NonLetterResponse.skipped, condition: condition,
                  engine: engine, responseDistanceCM: responseDistanceCM)
        case .unrecognized(.silence) where inputMode == .voice:
            // The (soft) no-input window elapsed with no speech-length sound and no usable text
            // from an ARMED microphone (a never-armed mic is .serviceFailure; a filler /
            // unintelligible pass earlier in the window is reported as that outcome, so this
            // really is silence). Since 2026-09-03 the trial is RECORDED as an incorrect
            // "no input registered" row but does NOT count toward the staircase: the level does
            // not move and a FRESH letter replaces it (PROTOCOL §7). Then the backstop: enough
            // silent letters in a row hand the NEXT presentation to the keypad — in voice mode
            // nothing else tells the operator, and it is the only exit from a same-level loop.
            consecutiveNoInputTrials += 1
            let escalateNext = consecutiveNoInputTrials >= config.noInputTrialsBeforeEscalation
            score(response: TrialResult.NonLetterResponse.noInput, condition: condition,
                  engine: engine, responseDistanceCM: responseDistanceCM,
                  provesVoicePath: false, countsTowardStaircase: false)
            if escalateNext, isTrialPhase, !isPausedForDistance, currentStimulus != nil {
                consecutiveNoInputTrials = 0
                retryPolicy.noteNoInputEscalation()
                escalateCurrentPresentation()
            }
        case .ambiguous, .unrecognized:
            if case .manualFallback = inputMode {
                // Keypad "No response": scored as incorrect (clinical decision) — the staircase
                // must be able to terminate for a child who cannot see or will not answer,
                // exactly like a missed letter on a physical chart.
                consecutiveNoInputTrials = 0
                score(response: TrialResult.NonLetterResponse.clinicianNoResponse,
                      condition: condition, engine: engine,
                      responseDistanceCM: responseDistanceCM)
                return
            }
            listeningStatus = operatorStatus(for: outcome)
            switch retryPolicy.actionForFailedAttempt() {
            case .retry(let withPrompt):
                // The first retry carries a spoken re-prompt; later retries stay silent so a
                // hesitant child isn't nagged every few seconds.
                guard withPrompt else {
                    repeatCurrentTrial()
                    return
                }
                // Blank the square while the re-prompt plays (the microphone is deliberately off
                // during speech) and re-present in the completion, as the phase intro does: a
                // letter that invites an answer nobody can hear would end as a no-input row.
                isBlankInterval = true
                let epoch = presentationEpoch
                announcer.speak(.tryAgain) { [weak self] in
                    guard let self, epoch == self.presentationEpoch,
                          !self.isPausedForDistance, self.isTrialPhase else { return }
                    self.repeatCurrentTrial()
                }
            case .escalateToManual:
                escalateCurrentPresentation()
            }
        case .serviceFailure(let failure):
            serviceAlert = failure
            listeningStatus = .micUnavailable
            _ = retryPolicy.actionForServiceFailure()
            escalateCurrentPresentation()
        case .letter(let response):
            consecutiveNoInputTrials = 0
            score(response: response, condition: condition, engine: engine,
                  responseDistanceCM: responseDistanceCM)
        }
    }

    /// The single resolution path for voice letters, spoken skips, voice no-input, and keypad
    /// entries (including "no response"). Non-letter responses are the
    /// ``TrialResult/NonLetterResponse`` sentinels and are incorrect by construction.
    ///
    /// `provesVoicePath` is false for a voice no-input: silence says nothing about whether the
    /// microphone path works, so it must not clear the consecutive-escalation streak — otherwise
    /// a child who never speaks could bounce keypad → voice → keypad forever without manual mode
    /// ever becoming sticky.
    ///
    /// `countsTowardStaircase` is false for a voice no-input (user decision 2026-09-03,
    /// superseding the 09-02 "silence scores a miss" rule): the row is recorded, the engine is
    /// NOT fed, the level does not move, and a fresh letter is presented in its place. Every
    /// other resolution counts, including keypad "No response" (`-`) and a spoken skip.
    private func score(response: String, condition: ColorCondition, engine: AcuityStaircaseEngine,
                       responseDistanceCM: Double, provesVoicePath: Bool = true,
                       countsTowardStaircase: Bool = true) {
        // A response is resolved only when the sizing lineage of the letter on screen is still
        // valid against the LIVE calibration (gold-standard rule): a mid-session calibration
        // change pauses instead of mis-scoring.
        guard let provenance = currentStimulus?.spec.provenance,
              let liveCalibration = calibration.currentCalibration,
              provenance.matches(liveCalibration) else {
            pausePresentation()
            return
        }
        retryPolicy.trialResolved(byVoice: provesVoicePath && inputMode == .voice)
        // Escalation is per-trial: a resolved keypad trial hands the NEXT trial back to voice,
        // unless enough consecutive escalations made manual mode sticky.
        inputMode = retryPolicy.isStickyManual ? .manualFallback(sticky: true) : .voice
        let correct = response == currentLetter
        recordTrial(condition: condition, response: response, correct: correct,
                    responseDistanceCM: responseDistanceCM, provenance: provenance,
                    countsTowardStaircase: countsTowardStaircase)
        guard countsTowardStaircase else {
            // Logged, never scored: the engine's counters are untouched, so the replacement
            // letter is presented at the same level and reuses the same within-level slot.
            presentTrial()
            return
        }
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
        case .letter, .skipped, .serviceFailure: return .idle
        }
    }

    /// `countsTowardStaircase` is written EXPLICITLY on every row (true or false), never nil:
    /// nil then means exactly "written before 2026-09-03", all of which were counted.
    private func recordTrial(condition: ColorCondition, response: String, correct: Bool,
                             responseDistanceCM: Double, provenance: SizingProvenance,
                             countsTowardStaircase: Bool = true) {
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
            // Recorded BEFORE the engine consumes the response, so this is the 1-based
            // within-level number of the trial being answered (gold `nextTrialNumber`). An
            // uncounted row never feeds the engine, so its replacement reuses the same number.
            trialNumber: engine?.nextTrialNumber ?? 0,
            timestamp: Date(),
            provenance: provenance,
            countsTowardStaircase: countsTowardStaircase)
        mutableSession.trials.append(trial)
    }

    // MARK: - Condition completion

    /// Where the low-contrast staircases begin: ``ScreenConfig/lowContrastStartOffsetSteps`` rungs
    /// COARSER (bigger letters) than the finest line the child actually PASSED under high
    /// contrast. A low-contrast letter is harder to read than the same-size high-contrast one, so
    /// the run is anchored to the child's own demonstrated acuity rather than a fixed level.
    ///
    /// Derived on demand from the recorded result rather than held as run state, so it follows
    /// `mutableSession.highContrast` for free: `resetRunStateForBack()` clears it (a re-run
    /// re-derives), and `clearTrialRunState()` preserves it (a forward skip between the two
    /// low-contrast conditions keeps the same anchor). Nil means the operator skipped the gate
    /// with Next and there is nothing to anchor to — fall back to the protocol start.
    ///
    /// The anchor can be any rung: low contrast runs regardless of the 20/25 result, and when no
    /// high-contrast line was passed `finestAcuityDenominator` is the coarser terminal line, so
    /// the clamp to the coarsest rung (20/200) in `acuityLevel(coarserBy:than:)` is load-bearing.
    private var lowContrastStartAcuity: Int {
        guard let reached = mutableSession.highContrast?.finestAcuityDenominator else {
            return config.startAcuity
        }
        return config.acuityLevel(coarserBy: config.lowContrastStartOffsetSteps, than: reached)
    }

    private func finishCondition(_ condition: ColorCondition, result: AcuityLevelResult) {
        let conditionResult = AcuityConditionResult(
            condition: condition,
            finestAcuityDenominator: result.finestAcuityReached,
            logMAR: result.logMAR,
            reachedGate: result.reachedGate)

        switch condition {
        case .highContrast:
            // `reachedGate` is recorded for analysis only. The low-contrast conditions ALWAYS
            // run (user decision 2026-09-03): a below-20/25 high-contrast result must never
            // silently drop red and teal. The only way a scored condition is skipped is an
            // explicit operator Next, confirmed in the root view.
            mutableSession.highContrast = conditionResult
            beginLowContrastSequence()
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
        cancelBlankInterval()
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

        // Inter-stimulus blank. The stimulus is committed FIRST and blanked in the SAME run-loop
        // turn, so SwiftUI never gets a frame with the new letter visible before the interval
        // starts. A zero duration presents synchronously, which is what keeps the coordinator
        // tests deterministic.
        blankIntervalTask?.cancel()
        guard config.interstimulusBlankSeconds > 0 else {
            isBlankInterval = false
            revealCurrentStimulus()
            return
        }
        isBlankInterval = true
        let epoch = presentationEpoch
        blankIntervalTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(
                nanoseconds: UInt64(config.interstimulusBlankSeconds * 1_000_000_000))
            // Reveal only the exact presentation this task was spawned for: same presentation
            // context, blank still owed, not paused, letter still committed.
            guard !Task.isCancelled, epoch == self.presentationEpoch, self.isBlankInterval,
                  !self.isPausedForDistance, self.currentStimulus != nil else { return }
            self.isBlankInterval = false
            self.revealCurrentStimulus()
        }
    }

    /// The tail of a presentation, run once the letter is actually visible: prompt (when
    /// configured) and arm recognition. Never called while blanked.
    private func revealCurrentStimulus() {
        if config.speakEveryTrialPrompt, phase != .warmup {
            announcer.speak(.sayTheLetter)
        }
        listen()
    }

    /// Ends any in-flight blank and returns the square to its normal rendering. Called from every
    /// presentation teardown path so a cancelled blank can never leave the square stuck black.
    private func cancelBlankInterval() {
        blankIntervalTask?.cancel()
        blankIntervalTask = nil
        isBlankInterval = false
    }

    /// Sizing distance: a fresh valid sample from the provider, or nothing — the presentation
    /// pauses rather than size from an aged or assumed distance (gold rule: never size from a
    /// sample older than `maximumSampleAgeSeconds`). There is deliberately no nominal-distance
    /// fallback either.
    private func sizedSpec(acuity: Int) -> OptotypeRenderSpec? {
        guard let cal = sessionCalibration else { return nil }
        guard let distanceCM = distance.validSample(
            maximumAge: config.maximumSampleAgeSeconds)?.distanceCM else { return nil }
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
        cancelBlankInterval()
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
    ///
    /// Deliberately runs during an inter-stimulus blank too: it republishes the SAME letter at a
    /// fresher size, nothing is visible while blanked, and the letter then appears at the newer
    /// size. No blank is started here — this is not a letter transition.
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
