import Combine
import XCTest
@testable import Myotect

/// Manual-push distance provider (fileprivate mirror; see CoordinatorGateTests).
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

    func pushDistance(_ cm: Double, timestamp: TimeInterval) {
        let sample = DistanceSample(distanceCM: cm, timestamp: timestamp)
        latestSample = sample
        lastValidity = .valid(sample)
        onUpdate?(.valid(sample))
    }

    func push(_ validity: DistanceValidity) {
        if case .valid(let sample) = validity { latestSample = sample }
        lastValidity = validity
        onUpdate?(validity)
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

/// Controllable announcer: records prompts, lets tests toggle `isSpeaking` and emit events.
@MainActor
private final class MockAnnouncer: PatientAudioPrompting {
    private(set) var spoken: [SpokenPrompt] = []
    var isSpeaking = false
    private let subject = PassthroughSubject<SpeechEvent, Never>()
    var events: AnyPublisher<SpeechEvent, Never> { subject.eraseToAnyPublisher() }

    func speak(_ prompt: SpokenPrompt, completion: (() -> Void)?) {
        spoken.append(prompt)
        completion?()
    }
    func stop() {}
    func setMicrophoneCaptureActive(_ active: Bool) {}
    func finishSpeaking() {
        isSpeaking = false
        subject.send(.finished)
    }
}

@MainActor
final class CoordinatorTTSTests: XCTestCase {

    private func makeCoordinator(listenResumeDelay: TimeInterval = 0)
        -> (MyopiaScreenCoordinator, ManualDistanceProvider, ScriptedSpeechService, MockAnnouncer) {
        var config = ScreenConfig()
        config.listenResumeAfterSpeechSeconds = listenResumeDelay
        let distance = ManualDistanceProvider()
        let speech = ScriptedSpeechService()
        let announcer = MockAnnouncer()
        let coordinator = MyopiaScreenCoordinator(
            config: config,
            distance: distance,
            speech: speech,
            announcer: announcer,
            calibration: StaticScreenCalibrationProvider(
                calibration: CoordinatorGateTests.testCalibration()),
            screenShortSidePoints: 393)
        distance.captureHook = { [weak coordinator] in coordinator?.beginDistanceCapture() }
        return (coordinator, distance, speech, announcer)
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

    func testPhasePromptsAreSpoken() {
        let (coordinator, distance, speech, announcer) = makeCoordinator()
        coordinator.beginAfterSetup()
        lockDistance(distance)
        XCTAssertEqual(coordinator.phase, .warmup)
        XCTAssertTrue(announcer.spoken.contains(.warmupIntro))

        for _ in 0..<coordinator.config.warmupLetterCount {
            guard let letter = coordinator.currentStimulus?.letter else { break }
            speech.answer(.letter(letter))
        }
        XCTAssertEqual(coordinator.phase, .highContrastGate)
        XCTAssertTrue(announcer.spoken.contains(.testBegins))
    }

    func testFirstRetrySpeaksReprompt() {
        let (coordinator, distance, speech, announcer) = makeCoordinator()
        coordinator.beginAfterSetup()
        lockDistance(distance)
        for _ in 0..<coordinator.config.warmupLetterCount {
            guard let letter = coordinator.currentStimulus?.letter else { break }
            speech.answer(.letter(letter))
        }
        XCTAssertEqual(coordinator.phase, .highContrastGate)
        XCTAssertFalse(announcer.spoken.contains(.tryAgain))

        speech.answer(.unrecognized(.silence))
        XCTAssertEqual(announcer.spoken.filter { $0 == .tryAgain }.count, 1)
        // The second retry is silent.
        speech.answer(.unrecognized(.silence))
        XCTAssertEqual(announcer.spoken.filter { $0 == .tryAgain }.count, 1)
    }

    func testVoidHoldPromptIsNotSupersededByGuidanceSpeech() {
        // A voided hold speaks its "try again" prompt; the announcer SUPERSEDES rather than
        // queues, so guidance speech must stay quiet while the void notice is up or the prompt
        // would be cut off mid-word (the face-lost watchdog re-pushes .missing every 0.25 s).
        let (coordinator, distance, _, announcer) = makeCoordinator()
        coordinator.beginAfterSetup()
        distance.pushDistance(200, timestamp: 0)
        coordinator.beginDistanceCapture()
        XCTAssertTrue(announcer.spoken.contains(.holdStill))

        distance.push(.missing)                      // voids the hold
        XCTAssertTrue(announcer.spoken.contains(.lostFace))

        distance.push(.missing)                      // watchdog repeats while the notice is up
        distance.push(.missing)
        XCTAssertFalse(announcer.spoken.contains(.stepIntoView),
                       "guidance speech while the void notice is up would cut off the prompt")
    }

    func testDistanceGuidanceIsSpokenAndThrottled() {
        let (coordinator, distance, _, announcer) = makeCoordinator()
        coordinator.beginAfterSetup()

        // Too far (out of the valid band, within plausible range) on the lock screen.
        distance.pushDistance(260, timestamp: 1.0)
        XCTAssertEqual(announcer.spoken.filter { $0 == .moveCloser }.count, 1)
        // Immediately repeated same guidance is throttled.
        distance.pushDistance(261, timestamp: 1.1)
        XCTAssertEqual(announcer.spoken.filter { $0 == .moveCloser }.count, 1)
        // A different direction speaks immediately.
        distance.pushDistance(150, timestamp: 1.2)
        XCTAssertEqual(announcer.spoken.filter { $0 == .moveFarther }.count, 1)
        XCTAssertEqual(coordinator.guidance, .moveFarther)
    }

    func testListenDeferredWhileSpeakingAndResumesAfterFinish() {
        let (coordinator, distance, speech, announcer) = makeCoordinator()
        coordinator.beginAfterSetup()
        lockDistance(distance)
        XCTAssertEqual(coordinator.phase, .warmup)
        XCTAssertTrue(speech.hasPending)

        // Pause, then let the announcer be mid-utterance while the child re-locks: the repeat's
        // listen() must defer instead of capturing the prompt tail.
        distance.push(.outOfRange(rawCM: 50))
        XCTAssertTrue(coordinator.isPausedForDistance)
        announcer.isSpeaking = true
        lockDistance(distance, start: 10)
        XCTAssertFalse(coordinator.isPausedForDistance)
        XCTAssertFalse(speech.hasPending)
        XCTAssertEqual(coordinator.listeningStatus, .speaking)

        // Speech ends: listening re-arms (resume delay configured to zero for the test).
        let expectation = expectation(description: "listen re-armed")
        announcer.finishSpeaking()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        XCTAssertTrue(speech.hasPending)
        XCTAssertEqual(coordinator.listeningStatus, .listening)
    }

    func testCompletionSpeaksAllDone() {
        let (coordinator, distance, speech, announcer) = makeCoordinator()
        coordinator.beginAfterSetup()
        lockDistance(distance)
        for _ in 0..<coordinator.config.warmupLetterCount {
            guard let letter = coordinator.currentStimulus?.letter else { break }
            speech.answer(.letter(letter))
        }
        // Fail out of the gate quickly (always wrong): session completes below the gate.
        var guardCount = 0
        while speech.hasPending, coordinator.phase == .highContrastGate, guardCount < 400 {
            guardCount += 1
            guard let stim = coordinator.currentStimulus else { break }
            let wrong = SloanLetter.all.first { $0 != stim.letter } ?? stim.letter
            speech.answer(.letter(wrong))
        }
        XCTAssertEqual(coordinator.phase, .results)
        XCTAssertTrue(announcer.spoken.contains(.allDone))
    }
}
