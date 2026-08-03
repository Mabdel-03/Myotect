import XCTest
@testable import Myotect

@MainActor
final class SpeechAnnouncerTests: XCTestCase {

    private func makeAnnouncer(enabled: Bool) -> SpeechAnnouncer {
        var config = ScreenConfig()
        config.ttsEnabled = enabled
        config.categorySettleSeconds = 0.05
        return SpeechAnnouncer(config: config)
    }

    func testDisabledAnnouncerCompletesImmediatelyAndStaysSilent() {
        let announcer = makeAnnouncer(enabled: false)
        var completed = 0
        announcer.speak(.warmupIntro) { completed += 1 }
        XCTAssertEqual(completed, 1)
        XCTAssertFalse(announcer.isSpeaking)
    }

    func testIsSpeakingCoversPendingWindowBeforeUtteranceStarts() {
        let announcer = makeAnnouncer(enabled: true)
        announcer.speak(.warmupIntro)
        // The category switch defers the actual utterance, but the pending window must already
        // count as speaking so recognition never starts underneath it.
        XCTAssertTrue(announcer.isSpeaking)
    }

    func testStopFiresPendingCompletionExactlyOnceAndClearsSpeaking() {
        let announcer = makeAnnouncer(enabled: true)
        var completed = 0
        announcer.speak(.warmupIntro) { completed += 1 }
        XCTAssertTrue(announcer.isSpeaking)
        announcer.stop()
        XCTAssertEqual(completed, 1)
        XCTAssertFalse(announcer.isSpeaking)
        announcer.stop()
        XCTAssertEqual(completed, 1)
    }

    func testSupersedingSpeakFiresEarlierCompletionExactlyOnce() {
        let announcer = makeAnnouncer(enabled: true)
        var firstCompleted = 0
        announcer.speak(.warmupIntro) { firstCompleted += 1 }
        announcer.speak(.testBegins)
        XCTAssertEqual(firstCompleted, 1)
        XCTAssertTrue(announcer.isSpeaking)
        announcer.stop()
        XCTAssertEqual(firstCompleted, 1)
    }

    func testSilentAnnouncerRecordsPromptsSynchronously() {
        let silent = SilentAnnouncer()
        var completed = false
        silent.speak(.moveCloser) { completed = true }
        XCTAssertTrue(completed)
        XCTAssertEqual(silent.spoken, [.moveCloser])
        XCTAssertFalse(silent.isSpeaking)
    }
}
