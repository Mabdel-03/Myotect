import XCTest
@testable import Myotect

final class PromptThrottleTests: XCTestCase {

    func testSamePromptWithinIntervalIsSuppressed() {
        var throttle = PromptThrottle(minInterval: 5)
        let t0 = Date(timeIntervalSinceReferenceDate: 100)
        XCTAssertTrue(throttle.shouldSpeak(.moveCloser, now: t0))
        XCTAssertFalse(throttle.shouldSpeak(.moveCloser, now: t0.addingTimeInterval(2)))
        XCTAssertTrue(throttle.shouldSpeak(.moveCloser, now: t0.addingTimeInterval(5)))
    }

    func testDifferentPromptSpeaksImmediately() {
        var throttle = PromptThrottle(minInterval: 5)
        let t0 = Date(timeIntervalSinceReferenceDate: 100)
        XCTAssertTrue(throttle.shouldSpeak(.moveCloser, now: t0))
        XCTAssertTrue(throttle.shouldSpeak(.moveFarther, now: t0.addingTimeInterval(1)))
        // Flapping back also speaks immediately (the prompt changed again).
        XCTAssertTrue(throttle.shouldSpeak(.moveCloser, now: t0.addingTimeInterval(2)))
    }

    func testResetClearsHistory() {
        var throttle = PromptThrottle(minInterval: 5)
        let t0 = Date(timeIntervalSinceReferenceDate: 100)
        XCTAssertTrue(throttle.shouldSpeak(.moveCloser, now: t0))
        throttle.reset()
        XCTAssertTrue(throttle.shouldSpeak(.moveCloser, now: t0.addingTimeInterval(1)))
    }

    func testSuppressedAttemptDoesNotExtendWindow() {
        var throttle = PromptThrottle(minInterval: 5)
        let t0 = Date(timeIntervalSinceReferenceDate: 100)
        XCTAssertTrue(throttle.shouldSpeak(.stepIntoView, now: t0))
        XCTAssertFalse(throttle.shouldSpeak(.stepIntoView, now: t0.addingTimeInterval(4.9)))
        // The 5 s window is measured from the last SPOKEN prompt, not the last attempt.
        XCTAssertTrue(throttle.shouldSpeak(.stepIntoView, now: t0.addingTimeInterval(5.0)))
    }
}
