import Combine
import XCTest
@testable import Myotect

/// Manual-push distance provider (mirror of the one in CoordinatorGateTests; fileprivate types
/// cannot be shared across test files).
private final class ManualDistanceProvider: DistanceProvider {
    var onUpdate: ((DistanceValidity) -> Void)?
    let isAvailable = true
    private(set) var state: DistanceTrackingState = .idle
    private(set) var latestSample: DistanceSample?
    /// Taps Capture Distance on the coordinator (wired by `makeCoordinator`); no-op in trials.
    var captureHook: (() -> Void)?
    private var lastValidity: DistanceValidity = .missing

    func start() { state = .tracking }
    func stop() { state = .idle }
    func validity(maximumAge: TimeInterval, now: TimeInterval) -> DistanceValidity { lastValidity }

    func push(_ validity: DistanceValidity) {
        if case .valid(let sample) = validity { latestSample = sample }
        lastValidity = validity
        onUpdate?(validity)
    }

    func pushDistance(_ cm: Double, timestamp: TimeInterval) {
        push(.valid(DistanceSample(distanceCM: cm, timestamp: timestamp)))
    }
}

private final class ScriptedSpeechService: LetterRecognitionService {
    let isAvailable = true
    private var pending: ((RecognitionOutcome) -> Void)?
    /// The no-input window the coordinator armed the last request with.
    private(set) var lastTimeout: TimeInterval?
    func recognizeOneLetter(timeout: TimeInterval, onOutcome: @escaping (RecognitionOutcome) -> Void) {
        lastTimeout = timeout
        pending = onOutcome
    }
    func cancel() { pending = nil }
    var hasPending: Bool { pending != nil }
    func answer(_ outcome: RecognitionOutcome) {
        let p = pending
        pending = nil
        p?(outcome)
    }
}

/// A scripted service that also models the continuous capture session, so a test can see when
/// the coordinator opens and closes the block's microphone engine (the real service does both).
@MainActor
private final class CaptureAwareSpeechService: @MainActor LetterRecognitionService, ContinuousCaptureControlling {
    nonisolated var isAvailable: Bool { true }
    private var pending: ((RecognitionOutcome) -> Void)?
    private(set) var isCaptureSessionActive = false
    private(set) var endedCaptureSessions = 0
    private let events = PassthroughSubject<CaptureEvent, Never>()
    var captureEvents: AnyPublisher<CaptureEvent, Never> { events.eraseToAnyPublisher() }
    func beginCaptureSession() { isCaptureSessionActive = true }
    func endCaptureSession() {
        isCaptureSessionActive = false
        endedCaptureSessions += 1
    }
    func recognizeOneLetter(timeout: TimeInterval, onOutcome: @escaping (RecognitionOutcome) -> Void) {
        pending = onOutcome
    }
    func cancel() { pending = nil }
    var hasPending: Bool { pending != nil }
    func answer(_ outcome: RecognitionOutcome) {
        let p = pending
        pending = nil
        p?(outcome)
    }
}

@MainActor
final class CoordinatorRetryTests: XCTestCase {

    private func makeCoordinator()
        -> (MyopiaScreenCoordinator, ManualDistanceProvider, ScriptedSpeechService, ManualClinicianService) {
        var config = ScreenConfig()
        // Synchronous presentation: these tests answer and immediately read the next stimulus.
        config.interstimulusBlankSeconds = 0
        let distance = ManualDistanceProvider()
        let speech = ScriptedSpeechService()
        let fallback = ManualClinicianService()
        let coordinator = MyopiaScreenCoordinator(
            config: config,
            distance: distance,
            speech: speech,
            fallback: fallback,
            calibration: StaticScreenCalibrationProvider(
                calibration: CoordinatorGateTests.testCalibration()),
            screenShortSidePoints: 393,
            lowContrastOrderOverride: [.lowContrastRed, .lowContrastGreen])
        distance.captureHook = { [weak coordinator] in coordinator?.beginDistanceCapture() }
        return (coordinator, distance, speech, fallback)
    }

    private func answerCorrect(_ coordinator: MyopiaScreenCoordinator, _ speech: ScriptedSpeechService) {
        speech.answer(.letter(coordinator.currentStimulus?.letter ?? "C"))
    }

    private func answerWrong(_ coordinator: MyopiaScreenCoordinator, _ speech: ScriptedSpeechService) {
        let shown = coordinator.currentStimulus?.letter ?? "C"
        speech.answer(.letter(SloanLetter.all.first { $0 != shown } ?? shown))
    }

    /// Full lock: capture tap + 2.1 s steady hold (in trials the tap no-ops and the samples
    /// satisfy the dwell re-lock instead).
    private func lockDistance(_ distance: ManualDistanceProvider, start: TimeInterval = 0) {
        distance.pushDistance(200, timestamp: start)
        distance.captureHook?()
        for i in 1...21 {
            distance.pushDistance(200, timestamp: start + Double(i) * 0.1)
        }
    }

    private func completeWarmup(_ coordinator: MyopiaScreenCoordinator, _ speech: ScriptedSpeechService) {
        for _ in 0..<coordinator.config.warmupLetterCount {
            guard let letter = coordinator.currentStimulus?.letter else { break }
            speech.answer(.letter(letter))
        }
    }

    private func reachGate() -> (MyopiaScreenCoordinator, ManualDistanceProvider, ScriptedSpeechService, ManualClinicianService) {
        let (coordinator, distance, speech, fallback) = makeCoordinator()
        coordinator.beginAfterSetup()
        lockDistance(distance)
        completeWarmup(coordinator, speech)
        XCTAssertEqual(coordinator.phase, .highContrastGate)
        return (coordinator, distance, speech, fallback)
    }

    /// Filler / unintelligible / ambiguous answers retry then escalate. (Voice SILENCE no longer
    /// retries on a scored trial — it is recorded as an uncounted "no input registered" row; see
    /// the tests below.)
    func testRepeatedNonAnswersEscalateToKeypadAfterCap() {
        let (coordinator, _, speech, fallback) = reachGate()
        let letter = coordinator.currentStimulus?.letter

        // Two free retries re-listen for the same letter by voice.
        speech.answer(.unrecognized(.filler))
        XCTAssertEqual(coordinator.inputMode, .voice)
        XCTAssertTrue(speech.hasPending)
        speech.answer(.unrecognized(.filler))
        XCTAssertEqual(coordinator.inputMode, .voice)
        XCTAssertTrue(speech.hasPending)

        // The third failure escalates: keypad armed, same letter still shown, nothing scored.
        speech.answer(.unrecognized(.filler))
        XCTAssertEqual(coordinator.inputMode, .manualFallback(sticky: false))
        XCTAssertTrue(fallback.isAwaitingInput)
        XCTAssertFalse(speech.hasPending)
        XCTAssertEqual(coordinator.currentStimulus?.letter, letter)
        XCTAssertTrue(coordinator.currentSessionSnapshot.trials.isEmpty)
    }

    func testKeypadSubmissionScoresTrialAndNextTrialReturnsToVoice() {
        let (coordinator, _, speech, _) = reachGate()
        speech.answer(.unrecognized(.filler))
        speech.answer(.unrecognized(.filler))
        speech.answer(.unrecognized(.filler))
        guard let letter = coordinator.currentStimulus?.letter else { return XCTFail("no stimulus") }

        coordinator.submitManual(letter: letter)

        XCTAssertEqual(coordinator.currentSessionSnapshot.trials.count, 1)
        XCTAssertEqual(coordinator.currentSessionSnapshot.trials.last?.isCorrect, true)
        // Escalation is per-trial: the next trial listens by voice again.
        XCTAssertEqual(coordinator.inputMode, .voice)
        XCTAssertTrue(speech.hasPending)
    }

    func testKeypadNoResponseScoresIncorrectTrial() {
        let (coordinator, _, speech, fallback) = reachGate()
        speech.answer(.unrecognized(.filler))
        speech.answer(.unrecognized(.filler))
        speech.answer(.unrecognized(.filler))
        XCTAssertTrue(fallback.isAwaitingInput)
        let shownLetter = coordinator.currentStimulus?.letter

        fallback.submitNoResponse()

        guard let trial = coordinator.currentSessionSnapshot.trials.last else {
            return XCTFail("no trial recorded")
        }
        XCTAssertEqual(trial.shownLetter, shownLetter)
        XCTAssertFalse(trial.isCorrect)
        XCTAssertEqual(trial.response, "-")
    }

    func testServiceFailureEscalatesImmediatelyWithAlert() {
        let (coordinator, _, speech, fallback) = reachGate()

        speech.answer(.serviceFailure(.microphonePermissionDenied))

        XCTAssertEqual(coordinator.serviceAlert, .microphonePermissionDenied)
        XCTAssertEqual(coordinator.inputMode, .manualFallback(sticky: false))
        XCTAssertEqual(coordinator.listeningStatus, .escalatedToClinician)
        XCTAssertTrue(fallback.isAwaitingInput)
        XCTAssertFalse(speech.hasPending)
        XCTAssertTrue(coordinator.currentSessionSnapshot.trials.isEmpty)
    }

    func testDistancePauseRepeatDoesNotGrantExtraRetries() {
        let (coordinator, distance, speech, fallback) = reachGate()

        // Burn both free retries.
        speech.answer(.unrecognized(.filler))
        speech.answer(.unrecognized(.filler))
        XCTAssertEqual(coordinator.inputMode, .voice)

        // A distance pause + re-lock re-presents the same letter WITHOUT resetting the budget.
        distance.pushDistance(170, timestamp: 5.0)
        XCTAssertTrue(coordinator.isPausedForDistance)
        lockDistance(distance, start: 6)
        XCTAssertFalse(coordinator.isPausedForDistance)
        XCTAssertTrue(speech.hasPending)

        // The next failure is the third attempt: escalate.
        speech.answer(.unrecognized(.filler))
        XCTAssertEqual(coordinator.inputMode, .manualFallback(sticky: false))
        XCTAssertTrue(fallback.isAwaitingInput)
    }

    func testConsecutiveKeypadTrialsBecomeStickyAndClinicianRestores() {
        let (coordinator, _, speech, fallback) = reachGate()

        // Trial 1 escalates and resolves by keypad.
        speech.answer(.unrecognized(.filler))
        speech.answer(.unrecognized(.filler))
        speech.answer(.unrecognized(.filler))
        coordinator.submitManual(letter: coordinator.currentStimulus?.letter ?? "C")
        XCTAssertEqual(coordinator.inputMode, .voice)

        // Trial 2 also escalates: two consecutive escalations with no voice resolve → sticky.
        speech.answer(.unrecognized(.filler))
        speech.answer(.unrecognized(.filler))
        speech.answer(.unrecognized(.filler))
        XCTAssertEqual(coordinator.inputMode, .manualFallback(sticky: true))
        coordinator.submitManual(letter: coordinator.currentStimulus?.letter ?? "C")
        // Sticky: the next trial stays on the keypad, no voice listening.
        XCTAssertEqual(coordinator.inputMode, .manualFallback(sticky: true))
        XCTAssertTrue(fallback.isAwaitingInput)
        XCTAssertFalse(speech.hasPending)

        // Clinician restores voice: the current letter re-arms by voice.
        coordinator.clinicianRestoreVoiceInput()
        XCTAssertEqual(coordinator.inputMode, .voice)
        XCTAssertTrue(speech.hasPending)
        XCTAssertFalse(fallback.isAwaitingInput)
    }

    func testKeypadOnlyStartStaysStickyAcrossResolvedLetters() {
        let (coordinator, distance, speech, fallback) = makeCoordinator()
        coordinator.beginAfterSetup(startInManualMode: true)
        XCTAssertEqual(coordinator.inputMode, .manualFallback(sticky: true))
        lockDistance(distance)
        XCTAssertEqual(coordinator.phase, .warmup)

        // Every presentation arms the keypad, never the microphone, and a resolved letter must
        // NOT silently revert to voice.
        XCTAssertTrue(fallback.isAwaitingInput)
        XCTAssertFalse(speech.hasPending)
        coordinator.submitManual(letter: coordinator.currentStimulus?.letter ?? "C")
        XCTAssertEqual(coordinator.warmupCompleted, 1)
        XCTAssertEqual(coordinator.inputMode, .manualFallback(sticky: true))
        XCTAssertTrue(fallback.isAwaitingInput)
        XCTAssertFalse(speech.hasPending)
    }

    func testGoBackClearsNonStickyEscalationForCleanRerun() {
        let (coordinator, _, speech, fallback) = reachGate()
        speech.answer(.unrecognized(.filler))
        speech.answer(.unrecognized(.filler))
        speech.answer(.unrecognized(.filler))
        XCTAssertEqual(coordinator.inputMode, .manualFallback(sticky: false))
        XCTAssertTrue(fallback.isAwaitingInput)

        // A clean re-run of the previous phase must not inherit a non-sticky escalation.
        XCTAssertTrue(coordinator.goBack())
        XCTAssertEqual(coordinator.phase, .warmup)
        XCTAssertEqual(coordinator.inputMode, .voice)
        XCTAssertNil(coordinator.serviceAlert)
        XCTAssertTrue(speech.hasPending)
        XCTAssertFalse(fallback.isAwaitingInput)
    }

    func testWarmupEscalationScoresNothingAndKeypadAdvancesWarmup() {
        let (coordinator, distance, speech, fallback) = makeCoordinator()
        coordinator.beginAfterSetup()
        lockDistance(distance)
        XCTAssertEqual(coordinator.phase, .warmup)

        // Warm-up keeps the retry → keypad path for SILENCE (the scored trials' no-input rule
        // and its backstop deliberately do not apply here): this is the dead-mic guard.
        speech.answer(.unrecognized(.silence))
        speech.answer(.unrecognized(.silence))
        speech.answer(.unrecognized(.silence))
        XCTAssertEqual(coordinator.inputMode, .manualFallback(sticky: false))
        XCTAssertTrue(fallback.isAwaitingInput)
        XCTAssertTrue(coordinator.currentSessionSnapshot.trials.isEmpty)
        XCTAssertEqual(coordinator.warmupCompleted, 0)

        coordinator.submitManual(letter: coordinator.currentStimulus?.letter ?? "C")
        XCTAssertEqual(coordinator.warmupCompleted, 1)
        XCTAssertTrue(coordinator.currentSessionSnapshot.trials.isEmpty)
        XCTAssertEqual(coordinator.inputMode, .voice)
    }
    // MARK: - Spoken skip and the no-input window

    func testSpokenSkipScoresIncorrectTrialAndPresentsNextLetter() {
        let (coordinator, _, speech, fallback) = reachGate()
        guard let shown = coordinator.currentStimulus?.letter else { return XCTFail("no stimulus") }

        speech.answer(.skipped)

        XCTAssertEqual(coordinator.currentSessionSnapshot.trials.count, 1)
        let trial = coordinator.currentSessionSnapshot.trials[0]
        XCTAssertEqual(trial.shownLetter, shown)
        XCTAssertEqual(trial.response, TrialResult.NonLetterResponse.skipped)
        XCTAssertFalse(trial.isCorrect)
        // Resolved like a letter: the next letter listens by voice, no keypad.
        XCTAssertEqual(coordinator.inputMode, .voice)
        XCTAssertTrue(speech.hasPending)
        XCTAssertFalse(fallback.isAwaitingInput)
        XCTAssertNotEqual(coordinator.currentStimulus?.letter, shown)
    }

    func testVoiceSilenceRecordsAnUncountedNoInputRowAndPresentsAFreshLetterAtTheSameLevel() {
        let (coordinator, _, speech, fallback) = reachGate()
        guard let shown = coordinator.currentStimulus?.letter else { return XCTFail("no stimulus") }
        let level = coordinator.currentStimulus?.acuityDenominator

        speech.answer(.unrecognized(.silence))

        XCTAssertEqual(coordinator.currentSessionSnapshot.trials.count, 1)
        let trial = coordinator.currentSessionSnapshot.trials[0]
        XCTAssertEqual(trial.shownLetter, shown)
        XCTAssertEqual(trial.response, TrialResult.NonLetterResponse.noInput)
        XCTAssertFalse(trial.isCorrect)
        XCTAssertEqual(trial.countsTowardStaircase, false)
        XCTAssertEqual(trial.trialNumber, 1)
        XCTAssertEqual(coordinator.inputMode, .voice)
        XCTAssertTrue(speech.hasPending)
        XCTAssertFalse(fallback.isAwaitingInput)
        XCTAssertEqual(coordinator.currentStimulus?.acuityDenominator, level)
        XCTAssertNotEqual(coordinator.currentStimulus?.letter, shown)
    }

    /// The replacement letter is a genuinely fresh trial: same level, different letter, flag
    /// false on the row, and a fresh retry budget (a filler spent on the silent letter must not
    /// carry over — two fillers on the replacement still retry rather than escalate).
    func testUncountedNoInputKeepsTheLevelPresentsAFreshLetterAndResetsTheRetryBudget() {
        let (coordinator, _, speech, fallback) = reachGate()
        guard let first = coordinator.currentStimulus else { return XCTFail("no stimulus") }
        speech.answer(.unrecognized(.filler))                  // attempt 1 on the first letter
        XCTAssertEqual(coordinator.currentStimulus?.letter, first.letter)

        speech.answer(.unrecognized(.silence))

        let trials = coordinator.currentSessionSnapshot.trials
        XCTAssertEqual(trials.count, 1)
        XCTAssertEqual(trials[0].shownLetter, first.letter)
        XCTAssertEqual(trials[0].countsTowardStaircase, false)
        XCTAssertEqual(coordinator.currentStimulus?.acuityDenominator, first.acuityDenominator)
        XCTAssertNotEqual(coordinator.currentStimulus?.letter, first.letter)
        XCTAssertEqual(coordinator.inputMode, .voice)
        XCTAssertTrue(speech.hasPending)

        // Fresh budget: two fillers still retry the replacement by voice; the third escalates.
        speech.answer(.unrecognized(.filler))
        speech.answer(.unrecognized(.filler))
        XCTAssertEqual(coordinator.inputMode, .voice)
        XCTAssertTrue(speech.hasPending)
        XCTAssertFalse(fallback.isAwaitingInput)
        speech.answer(.unrecognized(.filler))
        XCTAssertEqual(coordinator.inputMode, .manualFallback(sticky: false))
        XCTAssertEqual(coordinator.currentSessionSnapshot.trials.count, 1, "retries never record")
    }

    func testUnintelligibleAndAmbiguousStillRetryThenEscalateWithoutScoring() {
        let (coordinator, _, speech, fallback) = reachGate()
        speech.answer(.unrecognized(.unintelligible))
        XCTAssertTrue(speech.hasPending)
        speech.answer(.ambiguous)
        XCTAssertTrue(speech.hasPending)
        speech.answer(.unrecognized(.unintelligible))
        XCTAssertEqual(coordinator.inputMode, .manualFallback(sticky: false))
        XCTAssertTrue(fallback.isAwaitingInput)
        XCTAssertTrue(coordinator.currentSessionSnapshot.trials.isEmpty)
    }

    func testThreeConsecutiveNoInputTrialsHandTheNextLetterToKeypad() {
        let (coordinator, _, speech, fallback) = reachGate()
        XCTAssertEqual(coordinator.config.noInputTrialsBeforeEscalation, 3)

        speech.answer(.unrecognized(.silence))
        speech.answer(.unrecognized(.silence))
        XCTAssertEqual(coordinator.inputMode, .voice)
        XCTAssertTrue(speech.hasPending)

        let thirdSilentLetter = coordinator.currentStimulus?.letter
        speech.answer(.unrecognized(.silence))
        // All three silent letters are recorded, uncounted, at the unchanged level ...
        let trials = coordinator.currentSessionSnapshot.trials
        XCTAssertEqual(trials.count, 3)
        XCTAssertTrue(trials.allSatisfy {
            $0.response == TrialResult.NonLetterResponse.noInput && !$0.isCorrect
                && $0.countsTowardStaircase == false && $0.acuityDenominator == 40
        })
        // ... and the FOURTH presentation goes to the clinician keypad.
        XCTAssertEqual(coordinator.inputMode, .manualFallback(sticky: false))
        XCTAssertTrue(fallback.isAwaitingInput)
        XCTAssertFalse(speech.hasPending)
        XCTAssertNotNil(coordinator.currentStimulus)
        XCTAssertNotEqual(coordinator.currentStimulus?.letter, thirdSilentLetter,
                          "The keypad shows the FRESH replacement letter, not the silent one.")

        // Keypad "No response" still records "-", and the trial after returns to voice.
        fallback.submitNoResponse()
        XCTAssertEqual(coordinator.currentSessionSnapshot.trials.count, 4)
        XCTAssertEqual(coordinator.currentSessionSnapshot.trials.last?.response,
                       TrialResult.NonLetterResponse.clinicianNoResponse)
        XCTAssertEqual(coordinator.currentSessionSnapshot.trials.last?.countsTowardStaircase, true)
        // Three uncounted rows share slot 1 with the keypad miss that finally consumed it.
        XCTAssertEqual(coordinator.currentSessionSnapshot.trials.map(\.trialNumber), [1, 1, 1, 1])
        XCTAssertEqual(coordinator.inputMode, .voice)
        XCTAssertTrue(speech.hasPending)
    }

    func testLetterBetweenSilencesResetsTheNoInputCount() {
        let (coordinator, _, speech, _) = reachGate()
        speech.answer(.unrecognized(.silence))
        speech.answer(.unrecognized(.silence))
        speech.answer(.letter(coordinator.currentStimulus?.letter ?? "C"))
        speech.answer(.unrecognized(.silence))
        speech.answer(.unrecognized(.silence))
        XCTAssertEqual(coordinator.inputMode, .voice)
        XCTAssertTrue(speech.hasPending)
        let trials = coordinator.currentSessionSnapshot.trials
        XCTAssertEqual(trials.count, 5)
        XCTAssertEqual(trials.filter { $0.countsTowardStaircase == false }.count, 4)
    }

    func testConsecutiveNoInputEscalationsBecomeSticky() {
        let (coordinator, _, speech, fallback) = reachGate()
        for _ in 0..<3 { speech.answer(.unrecognized(.silence)) }
        XCTAssertEqual(coordinator.inputMode, .manualFallback(sticky: false))
        fallback.submitNoResponse()
        XCTAssertEqual(coordinator.inputMode, .voice)

        // A second no-input escalation with no voice LETTER in between: silence proves nothing
        // about the microphone, so the streak was not cleared and manual mode sticks.
        for _ in 0..<3 { speech.answer(.unrecognized(.silence)) }
        XCTAssertEqual(coordinator.inputMode, .manualFallback(sticky: true))
        XCTAssertTrue(fallback.isAwaitingInput)
        fallback.submitNoResponse()
        XCTAssertEqual(coordinator.inputMode, .manualFallback(sticky: true))
        XCTAssertTrue(fallback.isAwaitingInput)
        XCTAssertFalse(speech.hasPending)
    }

    func testWarmupSkipCountsAsCompletedPracticeLetter() {
        let (coordinator, distance, speech, fallback) = makeCoordinator()
        coordinator.beginAfterSetup()
        lockDistance(distance)
        XCTAssertEqual(coordinator.phase, .warmup)

        speech.answer(.skipped)

        XCTAssertEqual(coordinator.warmupCompleted, 1)
        XCTAssertTrue(coordinator.currentSessionSnapshot.trials.isEmpty)
        XCTAssertEqual(coordinator.inputMode, .voice)
        XCTAssertTrue(speech.hasPending)
        XCTAssertFalse(fallback.isAwaitingInput)
    }

    func testSpokenSkipResetsTheNoInputCount() {
        let (coordinator, _, speech, _) = reachGate()
        speech.answer(.unrecognized(.silence))
        speech.answer(.unrecognized(.silence))
        speech.answer(.skipped)
        speech.answer(.unrecognized(.silence))
        speech.answer(.unrecognized(.silence))
        // Four silences in total, but never three in a row: still by voice, five rows recorded,
        // only the skip counted.
        XCTAssertEqual(coordinator.inputMode, .voice)
        XCTAssertTrue(speech.hasPending)
        XCTAssertEqual(coordinator.currentSessionSnapshot.trials.count, 5)
        XCTAssertEqual(coordinator.currentSessionSnapshot.trials.filter { $0.countsTowardStaircase == true }.count, 1)
    }

    func testSpokenSkipClearsTheEscalationStreak() {
        let (coordinator, _, speech, fallback) = reachGate()
        for _ in 0..<3 { speech.answer(.unrecognized(.filler)) }              // escalation #1
        coordinator.submitManual(letter: coordinator.currentStimulus?.letter ?? "C")
        XCTAssertEqual(coordinator.inputMode, .voice)

        speech.answer(.skipped)                                                // a HEARD voice answer
        for _ in 0..<3 { speech.answer(.unrecognized(.filler)) }              // escalation again

        // The skip proved the voice path works, so the streak restarted: not sticky.
        XCTAssertEqual(coordinator.inputMode, .manualFallback(sticky: false))
        XCTAssertTrue(fallback.isAwaitingInput)
    }

    // MARK: - Backstop at phase boundaries

    func testSilencesNeverCompleteTheSessionButTheBackstopKeypadCan() {
        let (coordinator, _, speech, fallback) = reachGate()
        // High contrast early-perfect through 20/16 (15 trials; low contrast opens at 20/25).
        // Red early-perfect 25 → 20 → 16 (9). Teal passes 25, then fails 20/20 with W, W, W, W:
        // four counted attempts. Three silences then land in the fifth slot — since 2026-09-03
        // they are recorded but never fed to the engine, so the last staircase CANNOT terminate
        // on silence; the backstop hands the fresh letter to the keypad, and the keypad "No
        // response" is the fifth counted miss that completes the session (primary 20/20 line
        // failed after 20/25 passed) with no keypad armed on the results screen.
        for level in [40, 32, 25, 20, 16] {
            XCTAssertEqual(coordinator.currentStimulus?.acuityDenominator, level)
            for _ in 0..<3 { answerCorrect(coordinator, speech) }
        }
        XCTAssertEqual(coordinator.phase, .lowContrast(.lowContrastRed))
        for level in [25, 20, 16] {
            XCTAssertEqual(coordinator.currentStimulus?.acuityDenominator, level)
            for _ in 0..<3 { answerCorrect(coordinator, speech) }
        }
        XCTAssertEqual(coordinator.phase, .lowContrast(.lowContrastGreen))
        XCTAssertEqual(coordinator.currentStimulus?.acuityDenominator, 25)
        for _ in 0..<3 { answerCorrect(coordinator, speech) }
        XCTAssertEqual(coordinator.currentStimulus?.acuityDenominator, 20)
        for _ in 0..<4 { answerWrong(coordinator, speech) }
        XCTAssertEqual(coordinator.currentStimulus?.acuityDenominator, 20)

        for _ in 0..<3 { speech.answer(.unrecognized(.silence)) }
        XCTAssertEqual(coordinator.phase, .lowContrast(.lowContrastGreen), "silence never ends a condition")
        XCTAssertEqual(coordinator.currentStimulus?.acuityDenominator, 20)
        XCTAssertEqual(coordinator.inputMode, .manualFallback(sticky: false))
        XCTAssertTrue(fallback.isAwaitingInput)
        XCTAssertFalse(speech.hasPending)
        let silent = coordinator.currentSessionSnapshot.trials.suffix(3)
        XCTAssertTrue(silent.allSatisfy { $0.countsTowardStaircase == false && $0.trialNumber == 5 })

        fallback.submitNoResponse()
        XCTAssertEqual(coordinator.phase, .results)
        XCTAssertNil(coordinator.currentStimulus)
        XCTAssertFalse(fallback.isAwaitingInput, "no keypad on the results screen")
        XCTAssertFalse(speech.hasPending)
        let trials = coordinator.currentSessionSnapshot.trials
        XCTAssertEqual(trials.count, 35)                                         // 32 counted + 3 no-input
        XCTAssertEqual(trials.filter { $0.countsTowardStaircase == true }.count, 32)
        XCTAssertEqual(trials.last?.response, TrialResult.NonLetterResponse.clinicianNoResponse)
        XCTAssertEqual(trials.last?.countsTowardStaircase, true)
    }

    func testGateEndsOnLettersAndSilencesOnTheFirstLowContrastLettersTripTheBackstopInPlace() {
        let (coordinator, _, speech, fallback) = reachGate()
        // Early-perfect 40 / 32 / 25, then 20/20: W, W, W, W, S, S, W. The two silences are
        // recorded but uncounted (level stays 20, slot 5 is reused), and the final W is the
        // fifth counted miss that ends the gate — finest PASSED line 20/25, so red opens at 20/40
        // and the W also reset the consecutive no-input count.
        for level in [40, 32, 25] {
            XCTAssertEqual(coordinator.currentStimulus?.acuityDenominator, level)
            for _ in 0..<3 { answerCorrect(coordinator, speech) }
        }
        XCTAssertEqual(coordinator.currentStimulus?.acuityDenominator, 20)
        for _ in 0..<4 { answerWrong(coordinator, speech) }
        speech.answer(.unrecognized(.silence))
        speech.answer(.unrecognized(.silence))
        XCTAssertEqual(coordinator.phase, .highContrastGate)
        XCTAssertEqual(coordinator.currentStimulus?.acuityDenominator, 20)
        answerWrong(coordinator, speech)
        XCTAssertEqual(coordinator.phase, .lowContrast(.lowContrastRed))
        XCTAssertEqual(coordinator.currentStimulus?.acuityDenominator, 40)

        speech.answer(.unrecognized(.silence))                 // count restarted at 1 by the W
        XCTAssertEqual(coordinator.inputMode, .voice)
        XCTAssertTrue(speech.hasPending)
        speech.answer(.unrecognized(.silence))
        speech.answer(.unrecognized(.silence))                 // third in a row → backstop

        XCTAssertEqual(coordinator.phase, .lowContrast(.lowContrastRed))
        XCTAssertEqual(coordinator.currentStimulus?.acuityDenominator, 40, "silence never moves the level")
        XCTAssertEqual(coordinator.inputMode, .manualFallback(sticky: false))
        XCTAssertTrue(fallback.isAwaitingInput)
        XCTAssertFalse(speech.hasPending)
        XCTAssertNotNil(coordinator.currentStimulus)
        let trials = coordinator.currentSessionSnapshot.trials
        XCTAssertEqual(trials.count, 19)                                         // 14 counted + 5 no-input
        XCTAssertEqual(trials.filter { $0.countsTowardStaircase == true }.count, 14)
        XCTAssertTrue(trials.suffix(3).allSatisfy {
            $0.condition == .lowContrastRed && $0.acuityDenominator == 40
                && $0.trialNumber == 1 && $0.countsTowardStaircase == false
        })
    }

    /// A keypad escalation closes the block's capture session (the microphone path just proved
    /// unusable). When the keypad trial resolves and the next letter returns to voice, the
    /// session must be re-opened — otherwise every remaining letter of the block cold-starts
    /// the engine after its reveal (losing the onset of a fast answer) and runs without the
    /// interruption/route observers. The backstop is the common way in, so it is what is pinned.
    func testReturningToVoiceAfterTheBackstopKeypadReopensTheCaptureSession() {
        var config = ScreenConfig()
        config.interstimulusBlankSeconds = 0
        let distance = ManualDistanceProvider()
        let speech = CaptureAwareSpeechService()
        let fallback = ManualClinicianService()
        let coordinator = MyopiaScreenCoordinator(
            config: config,
            distance: distance,
            speech: speech,
            fallback: fallback,
            calibration: StaticScreenCalibrationProvider(
                calibration: CoordinatorGateTests.testCalibration()),
            screenShortSidePoints: 393,
            lowContrastOrderOverride: [.lowContrastRed, .lowContrastGreen])
        distance.captureHook = { [weak coordinator] in coordinator?.beginDistanceCapture() }
        coordinator.beginAfterSetup()
        lockDistance(distance)
        XCTAssertTrue(speech.isCaptureSessionActive, "Warm-up opens the capture session.")
        for _ in 0..<coordinator.config.warmupLetterCount {
            guard let letter = coordinator.currentStimulus?.letter else { break }
            speech.answer(.letter(letter))
        }
        XCTAssertEqual(coordinator.phase, .highContrastGate)
        XCTAssertTrue(speech.isCaptureSessionActive)

        for _ in 0..<3 { speech.answer(.unrecognized(.silence)) }
        XCTAssertEqual(coordinator.inputMode, .manualFallback(sticky: false))
        XCTAssertTrue(fallback.isAwaitingInput)
        XCTAssertFalse(speech.isCaptureSessionActive, "The keypad trial runs with the microphone released.")
        XCTAssertEqual(speech.endedCaptureSessions, 1)

        fallback.submitNoResponse()
        XCTAssertEqual(coordinator.inputMode, .voice)
        XCTAssertTrue(speech.hasPending)
        XCTAssertTrue(speech.isCaptureSessionActive,
                      "The first voice letter after the keypad re-opens the session.")
    }
}
