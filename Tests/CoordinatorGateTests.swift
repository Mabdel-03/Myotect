import XCTest
@testable import Myotect

/// A distance provider whose validity updates are pushed manually by the test, so the coordinator
/// flow is deterministic (no timers). The pull side answers the last pushed validity (or an
/// explicit override, for staleness simulation) so answer-time gating is test-controlled.
private final class ManualDistanceProvider: DistanceProvider {
    var onUpdate: ((DistanceValidity) -> Void)?
    let isAvailable = true
    private(set) var state: DistanceTrackingState = .idle
    private(set) var latestSample: DistanceSample?
    /// When set, `validity(maximumAge:now:)` answers this instead of the last pushed value.
    var validityOverride: DistanceValidity?

    private var lastValidity: DistanceValidity = .missing

    func start() { state = .tracking }
    func stop() { state = .idle }

    func validity(maximumAge: TimeInterval, now: TimeInterval) -> DistanceValidity {
        validityOverride ?? lastValidity
    }

    func push(_ validity: DistanceValidity) {
        if case .valid(let sample) = validity { latestSample = sample }
        lastValidity = validity
        onUpdate?(validity)
    }

    func pushDistance(_ cm: Double, timestamp: TimeInterval) {
        push(.valid(DistanceSample(distanceCM: cm, timestamp: timestamp)))
    }
}

/// A speech service the test answers synchronously. Each pending request is fulfilled via `answer`.
private final class ScriptedSpeechService: LetterRecognitionService {
    let isAvailable = true
    private var pending: ((RecognitionOutcome) -> Void)?
    func recognizeOneLetter(timeout: TimeInterval, onOutcome: @escaping (RecognitionOutcome) -> Void) {
        pending = onOutcome
    }
    func cancel() { pending = nil }
    var hasPending: Bool { pending != nil }
    /// Answers the current pending request.
    func answer(_ outcome: RecognitionOutcome) {
        let p = pending
        pending = nil
        p?(outcome)
    }
    /// Returns the pending closure WITHOUT clearing it, so a test can fire it after a `cancel()` to
    /// simulate a recognition callback already in flight when the coordinator cancels.
    func capturePending() -> ((RecognitionOutcome) -> Void)? { pending }
}

@MainActor
final class CoordinatorGateTests: XCTestCase {

    /// A validated calibration equivalent to the old 326 ppi / 3x test fixture.
    static func testCalibration(pointsPerMillimeter: Double = 326.0 / 3.0 / 25.4,
                                nativeScale: Double = 3.0) -> ScreenCalibration {
        ScreenCalibration(
            pointsPerMillimeter: pointsPerMillimeter,
            nativeScale: nativeScale,
            source: .deviceDatabase,
            screenSignature: "test-device|1179x2556|3.0000",
            schemaVersion: ScreenCalibration.schemaVersion)
    }

    private func makeCoordinator(order: [ColorCondition]? = nil,
                                 calibration: ScreenCalibrationProviding? = nil,
                                 screenShortSidePoints: Double = 393)
        -> (MyopiaScreenCoordinator, ManualDistanceProvider, ScriptedSpeechService) {
        let distance = ManualDistanceProvider()
        let speech = ScriptedSpeechService()
        let coordinator = MyopiaScreenCoordinator(
            config: ScreenConfig(),
            distance: distance,
            speech: speech,
            calibration: calibration
                ?? StaticScreenCalibrationProvider(calibration: Self.testCalibration()),
            screenShortSidePoints: screenShortSidePoints,
            lowContrastOrderOverride: order)
        return (coordinator, distance, speech)
    }

    /// Pushes locked samples to satisfy the stability window and advance to warm-up.
    private func lockDistance(_ distance: ManualDistanceProvider,
                              at cm: Double = 200,
                              start: TimeInterval = 0) {
        for i in 0...10 {
            distance.pushDistance(cm, timestamp: start + Double(i) * 0.1)
        }
    }

    /// Answers `count` warm-up letters (the warm-up shows them as `.highContrast`).
    private func completeWarmup(_ coordinator: MyopiaScreenCoordinator, _ speech: ScriptedSpeechService) {
        for _ in 0..<coordinator.config.warmupLetterCount {
            guard let letter = coordinator.currentStimulus?.letter else { break }
            speech.answer(.letter(letter))
        }
    }

    /// Drives a full condition: answer each trial as correct/incorrect per `correctPerLevel`.
    /// Drives the CURRENT condition only, stopping as soon as the phase changes (so each
    /// condition is exercised by a distinct call).
    private func runCondition(_ coordinator: MyopiaScreenCoordinator,
                              _ speech: ScriptedSpeechService,
                              answerCorrect: (Int) -> Bool,
                              maxTrials: Int = 400) {
        let startPhase = coordinator.phase
        var guardCount = 0
        while speech.hasPending, coordinator.phase == startPhase, guardCount < maxTrials {
            guardCount += 1
            guard let stim = coordinator.currentStimulus else { break }
            let correct = answerCorrect(stim.acuityDenominator)
            let response = correct ? stim.letter : wrongLetter(for: stim.letter)
            speech.answer(.letter(response))
        }
    }

    private func wrongLetter(for letter: String) -> String {
        SloanLetter.all.first { $0 != letter } ?? letter
    }

    func testReachesWarmupAfterDistanceLock() {
        let (coordinator, distance, _) = makeCoordinator()
        coordinator.beginAfterSetup()
        XCTAssertEqual(coordinator.phase, .distanceLock)
        lockDistance(distance)
        XCTAssertEqual(coordinator.phase, .warmup)
    }

    func testGatePassRunsBothLowContrastConditions() {
        let (coordinator, distance, speech) = makeCoordinator(order: [.lowContrastRed, .lowContrastGreen])
        coordinator.beginAfterSetup()
        lockDistance(distance)
        completeWarmup(coordinator, speech)
        XCTAssertEqual(coordinator.phase, .highContrastGate)

        // Pass everything (always correct) so the gate is reached.
        runCondition(coordinator, speech, answerCorrect: { _ in true })
        XCTAssertEqual(coordinator.phase, .lowContrast(.lowContrastRed))

        runCondition(coordinator, speech, answerCorrect: { _ in true })
        XCTAssertEqual(coordinator.phase, .lowContrast(.lowContrastGreen))

        runCondition(coordinator, speech, answerCorrect: { _ in true })
        XCTAssertEqual(coordinator.phase, .results)

        let session = coordinator.session
        XCTAssertNotNil(session?.highContrast)
        XCTAssertNotNil(session?.lowContrastRed)
        XCTAssertNotNil(session?.lowContrastGreen)
        XCTAssertNotNil(session?.duochromeDeltaLogMAR)
    }

    func testGateFailSkipsLowContrast() {
        let (coordinator, distance, speech) = makeCoordinator()
        coordinator.beginAfterSetup()
        lockDistance(distance)
        completeWarmup(coordinator, speech)
        XCTAssertEqual(coordinator.phase, .highContrastGate)

        // Fail at the start (always wrong from acuity 40) so the gate is never reached.
        runCondition(coordinator, speech, answerCorrect: { _ in false })
        XCTAssertEqual(coordinator.phase, .results)

        let session = coordinator.session
        XCTAssertNotNil(session?.highContrast)
        XCTAssertFalse(session?.highContrast?.reachedGate ?? true)
        XCTAssertNil(session?.lowContrastRed)
        XCTAssertNil(session?.lowContrastGreen)
    }

    func testAmbiguousRepeatsSameLetterWithoutAdvancing() {
        let (coordinator, distance, speech) = makeCoordinator()
        coordinator.beginAfterSetup()
        lockDistance(distance)
        completeWarmup(coordinator, speech)

        let firstLetter = coordinator.currentStimulus?.letter
        let firstAcuity = coordinator.currentStimulus?.acuityDenominator
        let trialsBefore = coordinator.currentSessionSnapshot.trials.count

        speech.answer(.ambiguous)

        // Same letter, same acuity, no new scored trial recorded.
        XCTAssertEqual(coordinator.currentStimulus?.letter, firstLetter)
        XCTAssertEqual(coordinator.currentStimulus?.acuityDenominator, firstAcuity)
        XCTAssertEqual(coordinator.currentSessionSnapshot.trials.count, trialsBefore)
        XCTAssertTrue(speech.hasPending)
    }

    func testDistanceInvalidPausesAndResumesWarmupLetter() {
        let (coordinator, distance, speech) = makeCoordinator()
        coordinator.beginAfterSetup()
        lockDistance(distance)
        XCTAssertEqual(coordinator.phase, .warmup)
        XCTAssertTrue(speech.hasPending)

        let firstLetter = coordinator.currentStimulus?.letter
        let firstAcuity = coordinator.currentStimulus?.acuityDenominator

        // In the plausible range but outside the valid band: pauses via the band gate.
        distance.pushDistance(170, timestamp: 5.0)
        XCTAssertTrue(coordinator.isPausedForDistance)
        XCTAssertFalse(speech.hasPending)

        lockDistance(distance, start: 5.1)
        XCTAssertFalse(coordinator.isPausedForDistance)
        XCTAssertEqual(coordinator.phase, .warmup)
        XCTAssertEqual(coordinator.currentStimulus?.letter, firstLetter)
        XCTAssertEqual(coordinator.currentStimulus?.acuityDenominator, firstAcuity)
        XCTAssertTrue(speech.hasPending)
    }

    func testDistanceInvalidPausesAndResumesScoredTrial() {
        let (coordinator, distance, speech) = makeCoordinator()
        coordinator.beginAfterSetup()
        lockDistance(distance)
        completeWarmup(coordinator, speech)
        XCTAssertEqual(coordinator.phase, .highContrastGate)
        XCTAssertFalse(coordinator.isPausedForDistance)

        let firstLetter = coordinator.currentStimulus?.letter
        let firstAcuity = coordinator.currentStimulus?.acuityDenominator
        let trialsBefore = coordinator.currentSessionSnapshot.trials.count

        // An implausible reading is reported as out-of-range, which pauses and cancels recognition.
        distance.push(.outOfRange(rawCM: 50))
        XCTAssertTrue(coordinator.isPausedForDistance)
        XCTAssertFalse(speech.hasPending)

        lockDistance(distance, start: 5.1)
        XCTAssertFalse(coordinator.isPausedForDistance)
        XCTAssertEqual(coordinator.phase, .highContrastGate)
        XCTAssertEqual(coordinator.currentStimulus?.letter, firstLetter)
        XCTAssertEqual(coordinator.currentStimulus?.acuityDenominator, firstAcuity)
        XCTAssertEqual(coordinator.currentSessionSnapshot.trials.count, trialsBefore)
        XCTAssertTrue(speech.hasPending)
    }

    func testStaleDistanceAtAnswerTimeIsNotScoredAndLetterRepeats() {
        let (coordinator, distance, speech) = makeCoordinator()
        coordinator.beginAfterSetup()
        lockDistance(distance)
        completeWarmup(coordinator, speech)
        XCTAssertEqual(coordinator.phase, .highContrastGate)

        let firstLetter = coordinator.currentStimulus?.letter
        let trialsBefore = coordinator.currentSessionSnapshot.trials.count

        // Tracking silently went away between presentation and answer: the pull-side validity is
        // stale, so the answer must be discarded and the presentation paused.
        distance.validityOverride = .missing
        speech.answer(.letter(firstLetter ?? "C"))

        XCTAssertTrue(coordinator.isPausedForDistance)
        XCTAssertEqual(coordinator.currentSessionSnapshot.trials.count, trialsBefore)

        // Recovery: fresh dwell lock re-presents the same letter.
        distance.validityOverride = nil
        lockDistance(distance, start: 10)
        XCTAssertFalse(coordinator.isPausedForDistance)
        XCTAssertEqual(coordinator.currentStimulus?.letter, firstLetter)
        XCTAssertTrue(speech.hasPending)
        XCTAssertEqual(coordinator.currentSessionSnapshot.trials.count, trialsBefore)
    }

    func testResumeRequiresInsetBandNotJustDwellLock() {
        let (coordinator, distance, speech) = makeCoordinator()
        coordinator.beginAfterSetup()
        lockDistance(distance)
        completeWarmup(coordinator, speech)
        XCTAssertEqual(coordinator.phase, .highContrastGate)

        // Pause by leaving the band entirely.
        distance.pushDistance(170, timestamp: 5.0)
        XCTAssertTrue(coordinator.isPausedForDistance)

        // A full dwell lock at 181 cm is inside the valid band (180-240) but OUTSIDE the resume
        // band (183-237): hysteresis keeps the trial paused so the edge cannot chatter.
        lockDistance(distance, at: 181, start: 6)
        XCTAssertTrue(coordinator.isPausedForDistance)

        // A dwell lock comfortably inside the resume band resumes.
        lockDistance(distance, at: 190, start: 8)
        XCTAssertFalse(coordinator.isPausedForDistance)
        XCTAssertTrue(speech.hasPending)
    }

    func testInterruptionMidTrialPausesAndRecoveryResumesSameLetter() {
        let (coordinator, distance, speech) = makeCoordinator()
        coordinator.beginAfterSetup()
        lockDistance(distance)
        completeWarmup(coordinator, speech)
        XCTAssertEqual(coordinator.phase, .highContrastGate)
        let firstLetter = coordinator.currentStimulus?.letter

        // A session interruption (phone call, Control Center) pauses and cancels recognition.
        distance.push(.interrupted)
        XCTAssertTrue(coordinator.isPausedForDistance)
        XCTAssertFalse(speech.hasPending)

        lockDistance(distance, start: 10)
        XCTAssertFalse(coordinator.isPausedForDistance)
        XCTAssertEqual(coordinator.currentStimulus?.letter, firstLetter)
        XCTAssertTrue(speech.hasPending)
    }

    func testBackgroundPausesTrialAndForegroundRequiresRelock() {
        let (coordinator, distance, speech) = makeCoordinator()
        coordinator.beginAfterSetup()
        lockDistance(distance)
        completeWarmup(coordinator, speech)
        XCTAssertEqual(coordinator.phase, .highContrastGate)
        let firstLetter = coordinator.currentStimulus?.letter

        coordinator.handleBackground()
        XCTAssertTrue(coordinator.isPausedForDistance)
        XCTAssertFalse(speech.hasPending)

        // Foreground alone never resumes scoring: the child must re-lock first.
        coordinator.handleForeground()
        XCTAssertTrue(coordinator.isPausedForDistance)

        lockDistance(distance, start: 20)
        XCTAssertFalse(coordinator.isPausedForDistance)
        XCTAssertEqual(coordinator.currentStimulus?.letter, firstLetter)
        XCTAssertTrue(speech.hasPending)
    }

    func testRecordedTrialDistanceIsAnswerTimeSampleNotLockValue() {
        let (coordinator, distance, speech) = makeCoordinator()
        coordinator.beginAfterSetup()
        lockDistance(distance)                      // locked at 200
        completeWarmup(coordinator, speech)
        XCTAssertEqual(coordinator.phase, .highContrastGate)

        // The child drifts (within band) after the stimulus was presented; the recorded trial
        // distance must be the answer-time measurement — and because the drift exceeds the
        // half-pixel damping threshold, live re-sizing has re-rendered the letter for 215 cm,
        // so the sizing distance tracks it. (The damped case, where sizing legitimately stays
        // behind, is covered separately.)
        distance.pushDistance(215, timestamp: 5.0)
        XCTAssertFalse(coordinator.isPausedForDistance)

        guard let letter = coordinator.currentStimulus?.letter else { return XCTFail("no stimulus") }
        speech.answer(.letter(letter))

        guard let trial = coordinator.currentSessionSnapshot.trials.last else {
            return XCTFail("no trial recorded")
        }
        XCTAssertEqual(trial.distanceCM, 215, accuracy: 0.0001)
        XCTAssertEqual(trial.sizingDistanceCM ?? -1, 215, accuracy: 0.0001)
    }

    // MARK: - Calibration & sizing

    func testBeginRefusedWhenUncalibrated() {
        let uncalibrated = StaticScreenCalibrationProvider(uncalibratedSignature: "unknown-device")
        let (coordinator, _, _) = makeCoordinator(calibration: uncalibrated)
        coordinator.beginAfterSetup()
        XCTAssertEqual(coordinator.phase, .setup)
    }

    func testBeginRefusedWhenDisplayTooSmallForWorstCase() {
        let (coordinator, _, _) = makeCoordinator(screenShortSidePoints: 100)
        XCTAssertNotNil(coordinator.displayFitProblem)
        coordinator.beginAfterSetup()
        XCTAssertEqual(coordinator.phase, .setup)
    }

    func testNoStimulusBeforeFirstDistanceSample() {
        let (coordinator, _, _) = makeCoordinator()
        coordinator.beginAfterSetup()
        // Skip the distance lock without a single measurement: there is no trusted distance to
        // size from, so nothing may be presented and the flow waits paused for a lock.
        XCTAssertTrue(coordinator.goNext())
        XCTAssertEqual(coordinator.phase, .warmup)
        XCTAssertNil(coordinator.currentStimulus)
        XCTAssertTrue(coordinator.isPausedForDistance)
    }

    func testLiveResizeAboveThresholdGrowsSpecAndKeepsLetter() {
        let (coordinator, distance, speech) = makeCoordinator()
        coordinator.beginAfterSetup()
        lockDistance(distance)
        completeWarmup(coordinator, speech)
        XCTAssertEqual(coordinator.phase, .highContrastGate)

        guard let before = coordinator.currentStimulus else { return XCTFail("no stimulus") }
        XCTAssertEqual(before.spec.provenance.targetHeightMillimeters,
                       before.spec.targetHeightMillimeters)

        // Drift within the band from 200 to 230 cm: the letter must grow ~15% to preserve the
        // visual angle, without changing identity or restarting recognition.
        distance.pushDistance(230, timestamp: 5.0)
        guard let after = coordinator.currentStimulus else { return XCTFail("stimulus vanished") }
        XCTAssertEqual(after.letter, before.letter)
        XCTAssertEqual(Double(after.spec.renderedHeightPoints),
                       Double(before.spec.renderedHeightPoints) * 230.0 / 200.0,
                       accuracy: 0.01)
        XCTAssertTrue(speech.hasPending)
    }

    func testSubThresholdResizeIsDamped() {
        let (coordinator, distance, speech) = makeCoordinator()
        coordinator.beginAfterSetup()
        lockDistance(distance)
        completeWarmup(coordinator, speech)

        guard let before = coordinator.currentStimulus else { return XCTFail("no stimulus") }
        // A sub-half-physical-pixel change must not republish the spec: the visible spec (and
        // therefore recorded provenance) stays exactly what is on screen.
        distance.pushDistance(200.0001, timestamp: 5.0)
        XCTAssertEqual(coordinator.currentStimulus?.spec, before.spec)

        // The recorded trial then shows the honest split: the answer-time distance moved, while
        // the sizing distance still describes the (damped) letter actually on screen.
        speech.answer(.letter(before.letter))
        guard let trial = coordinator.currentSessionSnapshot.trials.last else {
            return XCTFail("no trial recorded")
        }
        XCTAssertEqual(trial.distanceCM, 200.0001, accuracy: 1e-9)
        XCTAssertEqual(trial.sizingDistanceCM ?? -1, 200, accuracy: 0.0001)
    }

    func testScoringBlockedWhenCalibrationChangesMidTrial() {
        let provider = StaticScreenCalibrationProvider(calibration: Self.testCalibration())
        let (coordinator, distance, speech) = makeCoordinator(calibration: provider)
        coordinator.beginAfterSetup()
        lockDistance(distance)
        completeWarmup(coordinator, speech)
        XCTAssertEqual(coordinator.phase, .highContrastGate)
        let trialsBefore = coordinator.currentSessionSnapshot.trials.count

        // The live calibration changes mid-trial (different source and conversion): the on-screen
        // letter's provenance no longer matches, so the answer must pause, never score.
        provider.saveManualCalibration(pointsPerMillimeter: 5.5)
        guard let letter = coordinator.currentStimulus?.letter else { return XCTFail("no stimulus") }
        speech.answer(.letter(letter))

        XCTAssertTrue(coordinator.isPausedForDistance)
        XCTAssertNil(coordinator.currentStimulus)
        XCTAssertEqual(coordinator.currentSessionSnapshot.trials.count, trialsBefore)
    }

    func testTrialCarriesProvenanceAndSessionCarriesCalibration() {
        let (coordinator, distance, speech) = makeCoordinator()
        coordinator.beginAfterSetup()
        XCTAssertEqual(coordinator.currentSessionSnapshot.calibration, Self.testCalibration())
        XCTAssertEqual(coordinator.currentSessionSnapshot.ppiUsed, 326, accuracy: 0.01)

        lockDistance(distance)
        completeWarmup(coordinator, speech)
        guard let stim = coordinator.currentStimulus else { return XCTFail("no stimulus") }
        speech.answer(.letter(stim.letter))

        guard let trial = coordinator.currentSessionSnapshot.trials.last else {
            return XCTFail("no trial recorded")
        }
        XCTAssertEqual(trial.provenance, stim.spec.provenance)
        XCTAssertGreaterThan(trial.provenance?.targetHeightMillimeters ?? 0, 0)
    }

    // MARK: - Back navigation

    func testBackFromWarmupReturnsToDistanceLock() {
        let (coordinator, distance, speech) = makeCoordinator()
        coordinator.beginAfterSetup()
        lockDistance(distance)
        XCTAssertEqual(coordinator.phase, .warmup)

        XCTAssertTrue(coordinator.goBack())
        XCTAssertEqual(coordinator.phase, .distanceLock)

        // Re-locking distance drives the flow back to warm-up cleanly.
        lockDistance(distance)
        XCTAssertEqual(coordinator.phase, .warmup)
    }

    func testBackFromGateReturnsToWarmup() {
        let (coordinator, distance, speech) = makeCoordinator()
        coordinator.beginAfterSetup()
        lockDistance(distance)
        completeWarmup(coordinator, speech)
        XCTAssertEqual(coordinator.phase, .highContrastGate)

        XCTAssertTrue(coordinator.goBack())
        XCTAssertEqual(coordinator.phase, .warmup)
        XCTAssertEqual(coordinator.warmupCompleted, 0)
        XCTAssertTrue(coordinator.currentSessionSnapshot.trials.isEmpty)
    }

    func testBackFromLowContrastReturnsToGateAndClearsResults() {
        let (coordinator, distance, speech) = makeCoordinator(order: [.lowContrastRed, .lowContrastGreen])
        coordinator.beginAfterSetup()
        lockDistance(distance)
        completeWarmup(coordinator, speech)
        runCondition(coordinator, speech, answerCorrect: { _ in true })
        XCTAssertEqual(coordinator.phase, .lowContrast(.lowContrastRed))
        XCTAssertNotNil(coordinator.currentSessionSnapshot.highContrast)
        XCTAssertFalse(coordinator.currentSessionSnapshot.trials.isEmpty)

        XCTAssertTrue(coordinator.goBack())
        XCTAssertEqual(coordinator.phase, .highContrastGate)
        // Re-running starts clean: the gate result, low-contrast results, and trials are cleared.
        XCTAssertNil(coordinator.currentSessionSnapshot.highContrast)
        XCTAssertNil(coordinator.currentSessionSnapshot.lowContrastRed)
        XCTAssertTrue(coordinator.currentSessionSnapshot.trials.isEmpty)
    }

    func testBackFromSetupIsNotHandled() {
        let (coordinator, _, _) = makeCoordinator()
        XCTAssertEqual(coordinator.phase, .setup)
        // No in-flow predecessor: the view dismisses the flow instead.
        XCTAssertFalse(coordinator.goBack())
        XCTAssertEqual(coordinator.phase, .setup)
    }

    func testStaleRecognitionCallbackAfterBackIsIgnored() {
        let (coordinator, distance, speech) = makeCoordinator()
        coordinator.beginAfterSetup()
        lockDistance(distance)
        completeWarmup(coordinator, speech)
        XCTAssertEqual(coordinator.phase, .highContrastGate)

        // Capture the in-flight recognition closure, then go back before it fires.
        let staleCallback = speech.capturePending()
        XCTAssertNotNil(staleCallback)
        let letterBeforeBack = coordinator.currentStimulus?.letter ?? ""

        XCTAssertTrue(coordinator.goBack())
        XCTAssertEqual(coordinator.phase, .warmup)
        let trialsAfterBack = coordinator.currentSessionSnapshot.trials.count
        let warmupAfterBack = coordinator.warmupCompleted

        // Firing the stale callback must be a no-op: phase, warm-up progress, and trial count
        // are all unchanged (the generation token rejects it).
        staleCallback?(.letter(letterBeforeBack))
        XCTAssertEqual(coordinator.phase, .warmup)
        XCTAssertEqual(coordinator.warmupCompleted, warmupAfterBack)
        XCTAssertEqual(coordinator.currentSessionSnapshot.trials.count, trialsAfterBack)
    }

    // MARK: - Forward (Next) navigation

    func testNextFromSetupBeginsDistanceLock() {
        let (coordinator, _, _) = makeCoordinator()
        XCTAssertEqual(coordinator.phase, .setup)
        XCTAssertTrue(coordinator.goNext())
        XCTAssertEqual(coordinator.phase, .distanceLock)
    }

    func testNextFromDistanceLockSkipsToWarmup() {
        let (coordinator, _, _) = makeCoordinator()
        coordinator.beginAfterSetup()
        XCTAssertEqual(coordinator.phase, .distanceLock)
        // Skip positioning entirely.
        XCTAssertTrue(coordinator.goNext())
        XCTAssertEqual(coordinator.phase, .warmup)
    }

    func testNextFromWarmupSkipsToGate() {
        let (coordinator, distance, _) = makeCoordinator()
        coordinator.beginAfterSetup()
        lockDistance(distance)
        XCTAssertEqual(coordinator.phase, .warmup)
        XCTAssertTrue(coordinator.goNext())
        XCTAssertEqual(coordinator.phase, .highContrastGate)
    }

    func testNextFromGateSkipsToLowContrastWithoutRecording() {
        let (coordinator, distance, speech) = makeCoordinator(order: [.lowContrastRed, .lowContrastGreen])
        coordinator.beginAfterSetup()
        lockDistance(distance)
        completeWarmup(coordinator, speech)
        XCTAssertEqual(coordinator.phase, .highContrastGate)

        // Skip the gate before it finishes: it advances to the first low-contrast condition and
        // records NO high-contrast result.
        XCTAssertTrue(coordinator.goNext())
        XCTAssertEqual(coordinator.phase, .lowContrast(.lowContrastRed))
        XCTAssertNil(coordinator.currentSessionSnapshot.highContrast)
    }

    func testNextThroughLowContrastConditionsReachesResults() {
        let (coordinator, distance, speech) = makeCoordinator(order: [.lowContrastRed, .lowContrastGreen])
        coordinator.beginAfterSetup()
        lockDistance(distance)
        completeWarmup(coordinator, speech)
        XCTAssertTrue(coordinator.goNext())                 // skip gate to red
        XCTAssertEqual(coordinator.phase, .lowContrast(.lowContrastRed))
        XCTAssertTrue(coordinator.goNext())                 // skip red to green
        XCTAssertEqual(coordinator.phase, .lowContrast(.lowContrastGreen))
        XCTAssertTrue(coordinator.goNext())                 // skip green to results
        XCTAssertEqual(coordinator.phase, .results)

        // Everything was skipped, so no condition results were recorded.
        XCTAssertNil(coordinator.session?.highContrast)
        XCTAssertNil(coordinator.session?.lowContrastRed)
        XCTAssertNil(coordinator.session?.lowContrastGreen)
    }

    func testNextFromResultsIsNotHandled() {
        let (coordinator, distance, speech) = makeCoordinator(order: [.lowContrastRed, .lowContrastGreen])
        coordinator.beginAfterSetup()
        lockDistance(distance)
        completeWarmup(coordinator, speech)
        coordinator.goNext(); coordinator.goNext(); coordinator.goNext()
        XCTAssertEqual(coordinator.phase, .results)
        // Terminal phase: no successor.
        XCTAssertFalse(coordinator.goNext())
        XCTAssertEqual(coordinator.phase, .results)
    }
}
