import XCTest
@testable import Myotect

/// Pins the staircase to the gold `ETDRSProgressionEngine` semantics: 5 trials per line, ≥3 to
/// advance, early-perfect pass at 3 straight, and two-terminal-line letter scoring
/// (`base(primary) + wrongs × 0.02`, primary = the finer terminal line even when failed).
final class AcuityStaircaseEngineTests: XCTestCase {

    private func makeEngine(start: Int = 40, gate: Int? = 25) -> AcuityStaircaseEngine {
        var config = AcuityStaircaseConfig()
        config.startAcuity = start
        config.gateAcuity = gate
        return AcuityStaircaseEngine(config: config)
    }

    /// Feeds a response pattern, returning the last event.
    @discardableResult
    private func record(_ responses: [Bool], in engine: AcuityStaircaseEngine) -> AcuityEngineEvent {
        var event: AcuityEngineEvent = .continueSameLevel(acuity: engine.currentAcuity)
        for correct in responses {
            event = engine.record(correct: correct)
        }
        return event
    }

    /// Plays a single level: `correctCount` correct answers, then the rest incorrect, stopping as
    /// soon as the level resolves (an early-perfect pass can end it before 5 trials). Returns the
    /// event that ended the level.
    private func playLevel(_ engine: AcuityStaircaseEngine, correctCount: Int) -> AcuityEngineEvent {
        for i in 0..<engine.config.trialsPerLevel {
            let event = engine.record(correct: i < correctCount)
            if case .continueSameLevel = event { continue }
            return event
        }
        fatalError("level did not resolve within trialsPerLevel")
    }

    // MARK: - Configuration

    func testConfigurationIsFiveLetterProtocol() {
        let config = AcuityStaircaseConfig()
        XCTAssertEqual(config.trialsPerLevel, 5)
        XCTAssertEqual(config.advanceThreshold, 3)
        XCTAssertEqual(config.earlySkipCount, 3)
        XCTAssertEqual(config.logMARPerLetter, 0.02, accuracy: 0.000_001)
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

    // MARK: - Level resolution (gold recordResponse)

    func testThreeInitialCorrectUsePerfectShortcut() {
        // Early-perfect at 3 straight, recorded as a full 5/5 line.
        let engine = makeEngine(start: 40)
        XCTAssertEqual(engine.record(correct: true), .continueSameLevel(acuity: 40))
        XCTAssertEqual(engine.record(correct: true), .continueSameLevel(acuity: 40))
        let event = engine.record(correct: true)
        XCTAssertEqual(event, .advance(toAcuity: 32))
        XCTAssertEqual(engine.nextTrialNumber, 1)
    }

    func testAnyMissInFirstThreeRequiresAllFiveResponses() {
        let engine = makeEngine(start: 40)
        let event = record([true, true, false, true, true], in: engine)
        XCTAssertEqual(event, .advance(toAcuity: 32))
    }

    func testThreeOfFiveAdvances() {
        let engine = makeEngine(start: 40)
        XCTAssertEqual(record([true, false, true, false, true], in: engine),
                       .advance(toAcuity: 32))
    }

    func testTwoOfFiveStepsBackToUntestedLargerAcuity() {
        let engine = makeEngine(start: 40)
        XCTAssertEqual(record([true, false, true, false, false], in: engine),
                       .stepBack(toAcuity: 50))
    }

    func testContinuesWithinLevel() {
        XCTAssertEqual(makeEngine(start: 40).record(correct: true), .continueSameLevel(acuity: 40))
    }

    func testNextTrialNumberCountsWithinLevelAndResetsOnChange() {
        let engine = makeEngine(start: 40)
        XCTAssertEqual(engine.nextTrialNumber, 1)
        _ = engine.record(correct: true)
        _ = engine.record(correct: false)
        XCTAssertEqual(engine.nextTrialNumber, 3)
        _ = record([true, true, true], in: engine)   // 4/5, advance on the 5th
        XCTAssertEqual(engine.nextTrialNumber, 1)
    }

    // MARK: - Termination + two-terminal scoring (gold completeCurrentAcuity/finish)

    func testFailingAboveAPassedLevelFinishesWithFailedLineAsPrimary() {
        // Pass 40 (early-perfect), then 2/5 at 32: the threshold is bracketed, the FAILED finer
        // line (32) is primary, and both terminal lines contribute letter credit.
        let engine = makeEngine(start: 40)
        XCTAssertEqual(record([true, true, true], in: engine), .advance(toAcuity: 32))
        let event = record([true, true, false, false, false], in: engine)
        guard case .finished(let result) = event else { return XCTFail("expected finished, got \(event)") }
        XCTAssertEqual(result.primaryAcuity, 32)
        XCTAssertEqual(result.primaryCorrect, 2)
        XCTAssertEqual(result.secondaryAcuity, 40)
        XCTAssertEqual(result.secondaryCorrect, 5)
        // base(32)=0.2 + (3 wrong at 32 + 0 wrong at 40) × 0.02 = 0.26
        XCTAssertEqual(result.logMAR, 0.26, accuracy: 0.000_001)
        XCTAssertEqual(result.finestAcuityReached, 40)
        XCTAssertFalse(result.reachedGate)
    }

    func testAdvancingIntoAlreadyCompletedLevelFinishesInsteadOfRetesting() {
        // Fail 40 (1/5) → step back to 50 → pass 50: advancing would re-enter 40, which already
        // has a result — the staircase must finish (primary = 40's recorded line), never re-test
        // and overwrite it.
        let engine = makeEngine(start: 40)
        XCTAssertEqual(record([false, false, true, false, false], in: engine),
                       .stepBack(toAcuity: 50))
        let event = record([true, true, true], in: engine)
        guard case .finished(let result) = event else { return XCTFail("expected finished, got \(event)") }
        XCTAssertEqual(result.primaryAcuity, 40)
        XCTAssertEqual(result.primaryCorrect, 1)
        XCTAssertEqual(result.secondaryAcuity, 50)
        XCTAssertEqual(result.secondaryCorrect, 5)
        // base(40)=0.3 + (4 + 0) × 0.02 = 0.38
        XCTAssertEqual(result.logMAR, 0.38, accuracy: 0.000_001)
        XCTAssertEqual(result.finestAcuityReached, 50)
    }

    func testFailAtLargestLevelScoresAgainstSecondLargest() {
        // 2/5 at the largest level (200): finish with primary = the untested 160 (0 correct),
        // secondary = 200 — gold's boundary rule.
        let engine = makeEngine(start: 200)
        let event = record([true, true, false, false, false], in: engine)
        guard case .finished(let result) = event else { return XCTFail("expected finished, got \(event)") }
        XCTAssertEqual(result.primaryAcuity, 160)
        XCTAssertEqual(result.primaryCorrect, 0)
        XCTAssertEqual(result.secondaryAcuity, 200)
        XCTAssertEqual(result.secondaryCorrect, 2)
        // base(160)=0.9 + (5 + 3) × 0.02 = 1.06
        XCTAssertEqual(result.logMAR, 1.06, accuracy: 0.000_001)
        XCTAssertFalse(result.reachedGate)
        // Nothing was passed: the reported denominator falls back to the COARSER terminal line
        // (the level actually failed), never the finer/untested primary — a child who failed
        // 20/200 must not be reported as having reached 20/160.
        XCTAssertEqual(result.finestAcuityReached, 200)
    }

    func testPassingFinestAsStartScoresUntestedCoarserSecondaryAsZero() {
        // Gold's smallest-boundary rule: starting AT the finest level, the coarser neighbor was
        // never tested, so secondaryCorrect = 0 and its five misses add +0.1 logMAR.
        let engine = makeEngine(start: 16)
        let event = record([true, true, true], in: engine)
        guard case .finished(let result) = event else { return XCTFail("expected finished, got \(event)") }
        XCTAssertEqual(result.primaryAcuity, 16)
        XCTAssertEqual(result.primaryCorrect, 5)
        XCTAssertEqual(result.secondaryAcuity, 20)
        XCTAssertEqual(result.secondaryCorrect, 0)
        // base(16)=-0.1 + (0 + 5) × 0.02 = 0.0
        XCTAssertEqual(result.logMAR, 0.0, accuracy: 0.000_001)
    }

    func testPassingFinestLevelFinishes() {
        let engine = makeEngine(start: 20)
        XCTAssertEqual(record([true, true, true], in: engine), .advance(toAcuity: 16))
        let event = record([true, true, true], in: engine)
        guard case .finished(let result) = event else { return XCTFail("expected finished, got \(event)") }
        XCTAssertEqual(result.primaryAcuity, 16)
        XCTAssertEqual(result.primaryCorrect, 5)
        XCTAssertEqual(result.secondaryAcuity, 20)
        XCTAssertEqual(result.secondaryCorrect, 5)
        // base(16)=-0.1 + 0 wrong = -0.1
        XCTAssertEqual(result.logMAR, -0.1, accuracy: 0.000_001)
        XCTAssertEqual(result.finestAcuityReached, 16)
        XCTAssertTrue(result.reachedGate)
    }

    func testFailingFinestLevelStillScoresFromItAsPrimary() {
        // Completing the finest level finishes with it as primary REGARDLESS of pass/fail; the
        // reported passed level stays the coarser line.
        let engine = makeEngine(start: 20)
        XCTAssertEqual(record([true, true, true], in: engine), .advance(toAcuity: 16))
        let event = record([false, false, true, false, false], in: engine)
        guard case .finished(let result) = event else { return XCTFail("expected finished, got \(event)") }
        XCTAssertEqual(result.primaryAcuity, 16)
        XCTAssertEqual(result.primaryCorrect, 1)
        XCTAssertEqual(result.secondaryAcuity, 20)
        XCTAssertEqual(result.secondaryCorrect, 5)
        // base(16)=-0.1 + (4 + 0) × 0.02 = -0.02
        XCTAssertEqual(result.logMAR, -0.02, accuracy: 0.000_001)
        XCTAssertEqual(result.finestAcuityReached, 20)
        XCTAssertTrue(result.reachedGate)
    }

    func testMissedLettersAcrossBothTerminalLinesAllCount() {
        // Gold "+0.06" scenario: 4/5 on the coarser terminal line, 3/5 on the finer — every miss
        // on BOTH lines credits 0.02.
        let engine = makeEngine(start: 20)
        XCTAssertEqual(record([true, true, false, true, true], in: engine),
                       .advance(toAcuity: 16))
        let event = record([false, false, true, true, true], in: engine)
        guard case .finished(let result) = event else { return XCTFail("expected finished, got \(event)") }
        XCTAssertEqual(result.primaryCorrect, 3)
        XCTAssertEqual(result.secondaryCorrect, 4)
        // base(16)=-0.1 + (2 + 1) × 0.02 = -0.04
        XCTAssertEqual(result.logMAR, -0.04, accuracy: 0.000_001)
    }

    // MARK: - Gate

    func testGateReachedAtTwentyFive() {
        // Pass 40, 32, 25 (early-perfect each), then fail 20 → finish; 25 was passed → gate open.
        let engine = makeEngine(start: 40, gate: 25)
        XCTAssertEqual(playLevel(engine, correctCount: 3), .advance(toAcuity: 32))
        XCTAssertEqual(playLevel(engine, correctCount: 3), .advance(toAcuity: 25))
        XCTAssertEqual(playLevel(engine, correctCount: 3), .advance(toAcuity: 20))
        let event = playLevel(engine, correctCount: 0) // fail 20
        guard case .finished(let result) = event else { return XCTFail("expected finished, got \(event)") }
        XCTAssertEqual(result.finestAcuityReached, 25)
        XCTAssertTrue(result.reachedGate)
        // base(20)=0.0 + (5 wrong at 20 + 0 at 25) × 0.02 = 0.1
        XCTAssertEqual(result.logMAR, 0.1, accuracy: 0.000_001)
    }

    func testGateNotReachedWhenStuckAtThirtyTwo() {
        let engine = makeEngine(start: 40, gate: 25)
        XCTAssertEqual(playLevel(engine, correctCount: 3), .advance(toAcuity: 32))
        XCTAssertEqual(playLevel(engine, correctCount: 3), .advance(toAcuity: 25))
        let event = playLevel(engine, correctCount: 0) // fail 25
        guard case .finished(let result) = event else { return XCTFail("expected finished, got \(event)") }
        XCTAssertEqual(result.finestAcuityReached, 32)
        XCTAssertFalse(result.reachedGate)
    }

    func testGateNeverOpensOnAFailedPrimaryLine() {
        // Pass 32, fail 25 with letters to spare: primary is 25 but it was FAILED — a failed
        // line must never open the gate.
        let engine = makeEngine(start: 32, gate: 25)
        XCTAssertEqual(record([true, true, true], in: engine), .advance(toAcuity: 25))
        let event = record([true, true, false, false, false], in: engine)
        guard case .finished(let result) = event else { return XCTFail("expected finished, got \(event)") }
        XCTAssertEqual(result.primaryAcuity, 25)
        XCTAssertEqual(result.finestAcuityReached, 32)
        XCTAssertFalse(result.reachedGate)
    }

    func testLowContrastConfigHasNoGate() {
        var config = AcuityStaircaseConfig()
        config.gateAcuity = nil
        let engine = AcuityStaircaseEngine(config: config)
        XCTAssertEqual(playLevel(engine, correctCount: 3), .advance(toAcuity: 32)) // 40 -> 32
        let event = playLevel(engine, correctCount: 0) // fail 32 -> finish (40 passed)
        guard case .finished(let result) = event else { return XCTFail("expected finished, got \(event)") }
        XCTAssertTrue(result.reachedGate) // no gate -> always true
    }

    // MARK: - Recorded per-level counts

    func testEarlyPerfectRecordsFullLineInPerLevelCorrect() {
        let engine = makeEngine(start: 40)
        XCTAssertEqual(record([true, true, true], in: engine), .advance(toAcuity: 32))
        let event = record([true, true, false, false, false], in: engine)
        guard case .finished(let result) = event else { return XCTFail("expected finished, got \(event)") }
        XCTAssertEqual(result.perLevelCorrect[40], 5)   // early-perfect recorded as 5/5
        XCTAssertEqual(result.perLevelCorrect[32], 2)
    }
}
