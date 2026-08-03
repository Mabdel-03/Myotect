import XCTest
@testable import Myotect

/// Manual-push distance provider (mirror of the one in CoordinatorGateTests; fileprivate types
/// cannot be shared across test files).
private final class ManualDistanceProvider: DistanceProvider {
    var onUpdate: ((DistanceValidity) -> Void)?
    let isAvailable = true
    private(set) var state: DistanceTrackingState = .idle
    private(set) var latestSample: DistanceSample?
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
        let distance = ManualDistanceProvider()
        let speech = ScriptedSpeechService()
        let fallback = ManualClinicianService()
        let coordinator = MyopiaScreenCoordinator(
            config: ScreenConfig(),
            distance: distance,
            speech: speech,
            fallback: fallback,
            calibration: StaticScreenCalibrationProvider(
                calibration: CoordinatorGateTests.testCalibration()),
            screenShortSidePoints: 393)
        return (coordinator, distance, speech, fallback)
    }

    private func lockDistance(_ distance: ManualDistanceProvider, start: TimeInterval = 0) {
        for i in 0...10 {
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

    func testRepeatedNonAnswersEscalateToKeypadAfterCap() {
        let (coordinator, _, speech, fallback) = reachGate()
        let letter = coordinator.currentStimulus?.letter

        // Two free retries re-listen for the same letter by voice.
        speech.answer(.unrecognized(.silence))
        XCTAssertEqual(coordinator.inputMode, .voice)
        XCTAssertTrue(speech.hasPending)
        speech.answer(.unrecognized(.silence))
        XCTAssertEqual(coordinator.inputMode, .voice)
        XCTAssertTrue(speech.hasPending)

        // The third failure escalates: keypad armed, same letter still shown, nothing scored.
        speech.answer(.unrecognized(.silence))
        XCTAssertEqual(coordinator.inputMode, .manualFallback(sticky: false))
        XCTAssertTrue(fallback.isAwaitingInput)
        XCTAssertFalse(speech.hasPending)
        XCTAssertEqual(coordinator.currentStimulus?.letter, letter)
        XCTAssertTrue(coordinator.currentSessionSnapshot.trials.isEmpty)
    }

    func testKeypadSubmissionScoresTrialAndNextTrialReturnsToVoice() {
        let (coordinator, _, speech, _) = reachGate()
        speech.answer(.unrecognized(.silence))
        speech.answer(.unrecognized(.silence))
        speech.answer(.unrecognized(.silence))
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
        speech.answer(.unrecognized(.silence))
        speech.answer(.unrecognized(.silence))
        speech.answer(.unrecognized(.silence))
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
        speech.answer(.unrecognized(.silence))
        speech.answer(.unrecognized(.silence))
        XCTAssertEqual(coordinator.inputMode, .voice)

        // A distance pause + re-lock re-presents the same letter WITHOUT resetting the budget.
        distance.pushDistance(170, timestamp: 5.0)
        XCTAssertTrue(coordinator.isPausedForDistance)
        lockDistance(distance, start: 6)
        XCTAssertFalse(coordinator.isPausedForDistance)
        XCTAssertTrue(speech.hasPending)

        // The next failure is the third attempt: escalate.
        speech.answer(.unrecognized(.silence))
        XCTAssertEqual(coordinator.inputMode, .manualFallback(sticky: false))
        XCTAssertTrue(fallback.isAwaitingInput)
    }

    func testConsecutiveKeypadTrialsBecomeStickyAndClinicianRestores() {
        let (coordinator, _, speech, fallback) = reachGate()

        // Trial 1 escalates and resolves by keypad.
        speech.answer(.unrecognized(.silence))
        speech.answer(.unrecognized(.silence))
        speech.answer(.unrecognized(.silence))
        coordinator.submitManual(letter: coordinator.currentStimulus?.letter ?? "C")
        XCTAssertEqual(coordinator.inputMode, .voice)

        // Trial 2 also escalates: two consecutive escalations with no voice resolve → sticky.
        speech.answer(.unrecognized(.silence))
        speech.answer(.unrecognized(.silence))
        speech.answer(.unrecognized(.silence))
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

    func testWarmupEscalationScoresNothingAndKeypadAdvancesWarmup() {
        let (coordinator, distance, speech, fallback) = makeCoordinator()
        coordinator.beginAfterSetup()
        lockDistance(distance)
        XCTAssertEqual(coordinator.phase, .warmup)

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
}
