import XCTest
@testable import Myotect

/// Pins the operator-initiated capture hold to the gold semantics: tap-instant anchor, hard
/// ±tolerance envelope, whole-second countdown, timestamp-deduped mean of the steady window.
final class DistanceHoldTrackerTests: XCTestCase {

    private func makeTracker() -> DistanceHoldTracker {
        DistanceHoldTracker(durationSeconds: 2.0, toleranceCM: 4.0)
    }

    private func sample(_ cm: Double, at t: TimeInterval) -> DistanceSample {
        DistanceSample(distanceCM: cm, timestamp: t)
    }

    func testInactiveTrackerIgnoresUpdates() {
        var tracker = makeTracker()
        XCTAssertNil(tracker.update(with: .valid(sample(200, at: 0.1))))
        XCTAssertFalse(tracker.isActive)
    }

    func testCountdownShowsWholeSecondsRemaining() {
        var tracker = makeTracker()
        tracker.begin(with: sample(200, at: 0))
        XCTAssertEqual(tracker.update(with: .valid(sample(200, at: 0.5))),
                       .progress(remainingSeconds: 2))
        XCTAssertEqual(tracker.update(with: .valid(sample(200, at: 1.1))),
                       .progress(remainingSeconds: 1))
    }

    func testCompletesAtDurationWithMeanOfAllReadings() {
        var tracker = makeTracker()
        tracker.begin(with: sample(200, at: 0))
        XCTAssertEqual(tracker.update(with: .valid(sample(202, at: 0.7))),
                       .progress(remainingSeconds: 2))
        XCTAssertEqual(tracker.update(with: .valid(sample(198, at: 1.4))),
                       .progress(remainingSeconds: 1))
        let event = tracker.update(with: .valid(sample(200, at: 2.0)))
        XCTAssertEqual(event, .completed(meanDistanceCM: 200, readingCount: 4))
        XCTAssertFalse(tracker.isActive)
    }

    func testRepeatedTimestampIsNotDoubleCounted() {
        var tracker = makeTracker()
        tracker.begin(with: sample(200, at: 0))
        // The same 204 reading delivered twice must enter the mean once.
        _ = tracker.update(with: .valid(sample(204, at: 1.0)))
        _ = tracker.update(with: .valid(sample(204, at: 1.0)))
        let event = tracker.update(with: .valid(sample(202, at: 2.0)))
        XCTAssertEqual(event, .completed(meanDistanceCM: 202, readingCount: 3))
    }

    func testDriftBeyondToleranceVoids() {
        var tracker = makeTracker()
        tracker.begin(with: sample(200, at: 0))
        _ = tracker.update(with: .valid(sample(203, at: 0.5)))
        // 205 is >4 cm from the ANCHOR (200) even though it is only 2 cm from the last reading.
        XCTAssertEqual(tracker.update(with: .valid(sample(205, at: 1.0))),
                       .voided(.movedTooMuch))
        XCTAssertFalse(tracker.isActive)
        XCTAssertNil(tracker.update(with: .valid(sample(200, at: 1.5))))
    }

    func testExactToleranceBoundaryIsKept() {
        var tracker = makeTracker()
        tracker.begin(with: sample(200, at: 0))
        XCTAssertEqual(tracker.update(with: .valid(sample(204, at: 0.5))),
                       .progress(remainingSeconds: 2))
        XCTAssertEqual(tracker.update(with: .valid(sample(196, at: 1.0))),
                       .progress(remainingSeconds: 1))
    }

    func testInvalidSampleVoidsAsFaceLost() {
        for validity in [DistanceValidity.missing, .stale(sample(200, at: 0)),
                         .outOfRange(rawCM: 90), .interrupted, .failed] {
            var tracker = makeTracker()
            tracker.begin(with: sample(200, at: 0))
            XCTAssertEqual(tracker.update(with: validity), .voided(.faceLost),
                           "expected face-lost void for \(validity)")
            XCTAssertFalse(tracker.isActive)
        }
    }

    func testCancelDiscardsHoldSilently() {
        var tracker = makeTracker()
        tracker.begin(with: sample(200, at: 0))
        tracker.cancel()
        XCTAssertFalse(tracker.isActive)
        XCTAssertNil(tracker.update(with: .valid(sample(200, at: 2.5))))
    }

    func testRestartAfterVoidAnchorsFresh() {
        var tracker = makeTracker()
        tracker.begin(with: sample(200, at: 0))
        _ = tracker.update(with: .valid(sample(210, at: 0.5)))   // voided
        tracker.begin(with: sample(190, at: 1.0))
        // The new anchor is 190: 193 is fine, and completion measures from the NEW window only.
        XCTAssertEqual(tracker.update(with: .valid(sample(193, at: 2.0))),
                       .progress(remainingSeconds: 1))
        XCTAssertEqual(tracker.update(with: .valid(sample(190, at: 3.0))),
                       .completed(meanDistanceCM: 191, readingCount: 3))
    }
}
