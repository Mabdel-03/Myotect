import XCTest
@testable import Myotect

final class AcuityStaircaseEngineTests: XCTestCase {

    private func makeEngine(start: Int = 40, gate: Int? = 25) -> AcuityStaircaseEngine {
        var config = AcuityStaircaseConfig()
        config.startAcuity = start
        config.gateAcuity = gate
        return AcuityStaircaseEngine(config: config)
    }

    /// Plays a single level: `correctCount` correct answers, then the rest incorrect, stopping as
    /// soon as the level resolves (an early skip can end it before 10 trials). Returns the event
    /// that ended the level.
    private func playLevel(_ engine: AcuityStaircaseEngine, correctCount: Int) -> AcuityEngineEvent {
        for i in 0..<engine.config.trialsPerLevel {
            let event = engine.record(correct: i < correctCount)
            if case .continueSameLevel = event { continue }
            return event
        }
        fatalError("level did not resolve within trialsPerLevel")
    }

    func testStartsAtConfiguredAcuity() {
        XCTAssertEqual(makeEngine(start: 40).currentAcuity, 40)
    }

    func testAcuityLevelsContain25() {
        let levels = AcuityStaircaseConfig().acuityLevels
        XCTAssertTrue(levels.contains(25))
        let idx = levels.firstIndex(of: 25)!
        XCTAssertEqual(levels[idx - 1], 32)
        XCTAssertEqual(levels[idx + 1], 20)
    }

    func testAdvanceOnSixOfTen() {
        // 6 correct, but not the first 5 in a row, to avoid early skip.
        let engine = makeEngine(start: 40)
        var resolved: AcuityEngineEvent = .continueSameLevel(acuity: 40)
        // pattern: F,C,C,C,C,C,C,F,F,F  -> 6 correct over 10 trials, no first-5 streak
        let pattern = [false, true, true, true, true, true, true, false, false, false]
        for (i, correct) in pattern.enumerated() {
            resolved = engine.record(correct: correct)
            if case .continueSameLevel = resolved { continue }
            XCTAssertEqual(i, 9, "should resolve only on the 10th trial")
            break
        }
        XCTAssertEqual(resolved, .advance(toAcuity: 32))
    }

    func testEarlySkipAdvancesAtFifthCorrect() {
        let engine = makeEngine(start: 40)
        var event: AcuityEngineEvent = .continueSameLevel(acuity: 40)
        for _ in 0..<5 { event = engine.record(correct: true) }
        XCTAssertEqual(event, .advance(toAcuity: 32))
    }

    func testStepBackBelowSix() {
        // 5 correct, no early-skip streak, larger level untested -> step back.
        let engine = makeEngine(start: 40)
        let pattern = [false, true, true, true, true, true, false, false, false, false] // 5 correct
        var resolved: AcuityEngineEvent = .continueSameLevel(acuity: 40)
        for correct in pattern {
            resolved = engine.record(correct: correct)
            if case .continueSameLevel = resolved { continue }
            break
        }
        XCTAssertEqual(resolved, .stepBack(toAcuity: 50))
    }

    func testContinuesWithinLevel() {
        XCTAssertEqual(makeEngine(start: 40).record(correct: true), .continueSameLevel(acuity: 40))
    }

    func testGateReachedAtTwentyFive() {
        // Pass 40,32,25 (early skip each), then fail 20 -> finish at 25 (25 already passed).
        let engine = makeEngine(start: 40, gate: 25)
        XCTAssertEqual(playLevel(engine, correctCount: 5), .advance(toAcuity: 32))
        XCTAssertEqual(playLevel(engine, correctCount: 5), .advance(toAcuity: 25))
        XCTAssertEqual(playLevel(engine, correctCount: 5), .advance(toAcuity: 20))
        let event = playLevel(engine, correctCount: 0) // fail 20
        guard case .finished(let result) = event else { return XCTFail("expected finished, got \(event)") }
        XCTAssertEqual(result.finestAcuityReached, 25)
        XCTAssertTrue(result.reachedGate)
    }

    func testGateNotReachedWhenStuckAtThirtyTwo() {
        // Pass 40,32, then fail 25 -> finish at 32 (32 already passed, below gate).
        let engine = makeEngine(start: 40, gate: 25)
        XCTAssertEqual(playLevel(engine, correctCount: 5), .advance(toAcuity: 32))
        XCTAssertEqual(playLevel(engine, correctCount: 5), .advance(toAcuity: 25))
        let event = playLevel(engine, correctCount: 0) // fail 25
        guard case .finished(let result) = event else { return XCTFail("expected finished, got \(event)") }
        XCTAssertEqual(result.finestAcuityReached, 32)
        XCTAssertFalse(result.reachedGate)
    }

    func testLogMARIncludesErrorAdjustment() {
        // Pass 40 with exactly 6/10 (4 wrong, no early streak), then fail 32 -> finest = 40.
        // logMAR = table[40]=0.3 + 4 wrong / 100 = 0.34.
        let engine = makeEngine(start: 40, gate: 25)
        let pass40 = [false, true, true, true, true, true, true, false, false, false] // 6 correct
        for correct in pass40 { _ = engine.record(correct: correct) }
        XCTAssertEqual(engine.currentAcuity, 32)
        let event = playLevel(engine, correctCount: 0) // fail 32 -> finish (40 passed)
        guard case .finished(let result) = event else { return XCTFail("expected finished, got \(event)") }
        XCTAssertEqual(result.finestAcuityReached, 40)
        XCTAssertEqual(result.logMAR, 0.34, accuracy: 0.0001)
    }

    func testLowContrastConfigHasNoGate() {
        var config = AcuityStaircaseConfig()
        config.gateAcuity = nil
        let engine = AcuityStaircaseEngine(config: config)
        XCTAssertEqual(playLevel(engine, correctCount: 5), .advance(toAcuity: 32)) // 40 -> 32
        let event = playLevel(engine, correctCount: 0) // fail 32 -> finish (40 passed)
        guard case .finished(let result) = event else { return XCTFail("expected finished, got \(event)") }
        XCTAssertTrue(result.reachedGate) // no gate -> always true
    }
}
