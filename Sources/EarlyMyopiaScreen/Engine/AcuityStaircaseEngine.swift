import Foundation

/// Tunable parameters for the acuity staircase.
struct AcuityStaircaseConfig {
    /// Snellen denominators from largest (easiest) to smallest (hardest). Note 25 is present so the
    /// 20/25 gate is a real level.
    var acuityLevels: [Int] = [200, 160, 125, 100, 80, 63, 50, 40, 32, 25, 20, 16]
    /// The acuity level the staircase begins at.
    var startAcuity: Int = 40
    /// Trials presented per level before a pass/fail decision.
    var trialsPerLevel: Int = 10
    /// Minimum correct in a level to advance to a smaller (harder) level.
    var advanceThreshold: Int = 6
    /// If the first `earlySkipCount` trials are all correct, the level passes immediately and is
    /// recorded as a perfect score (matching the source app's "skip" shortcut).
    var earlySkipCount: Int = 5
    /// The gate denominator: `reachedGate` is true when the finest passed level is this or finer.
    /// `nil` disables gating (used for the low-contrast conditions).
    var gateAcuity: Int? = 25
    /// Snellen-denominator to logMAR table. Adapted from the source app's `usFootToLogMAR`.
    var logMAR: [Int: Double] = [
        10: -0.3, 12: -0.2, 16: -0.1, 20: 0.0, 25: 0.1, 32: 0.2,
        40: 0.3, 50: 0.4, 63: 0.5, 80: 0.6, 100: 0.7, 125: 0.8,
        160: 0.9, 200: 1.0,
    ]

    init() {}
}

/// The outcome produced after recording a single trial.
enum AcuityEngineEvent: Equatable {
    /// Continue presenting trials at the current acuity level.
    case continueSameLevel(acuity: Int)
    /// Advanced to a smaller (harder) acuity level.
    case advance(toAcuity: Int)
    /// Stepped back to a larger (easier) acuity level.
    case stepBack(toAcuity: Int)
    /// The staircase has terminated.
    case finished(result: AcuityLevelResult)
}

/// The final result of a completed staircase run.
struct AcuityLevelResult: Equatable {
    /// The finest (smallest) Snellen denominator the subject passed.
    let finestAcuityReached: Int
    /// Computed logMAR, including the per-error adjustment from the source app.
    let logMAR: Double
    /// True when `finestAcuityReached` is at least as fine as the configured gate.
    let reachedGate: Bool
    /// Correct-count recorded per acuity level (denominator to correct count).
    let perLevelCorrect: [Int: Int]
}

/// A deterministic, UI-agnostic acuity staircase.
///
    /// Adapted from `TumblingEViewController.processNextTrial` (advance/step-back/skip rules) and
/// `calculateScore` (logMAR + per-error adjustment), restructured so it can be unit tested without
/// any view layer. Feed it one trial outcome at a time via ``record(correct:)``.
final class AcuityStaircaseEngine {
    let config: AcuityStaircaseConfig

    private(set) var currentIndex: Int
    /// Correct answers accumulated in the level currently in progress.
    private var correctInLevel: Int = 0
    /// Trials presented in the level currently in progress.
    private var trialsInLevel: Int = 0
    /// Finalized correct count per level (denominator to correct count). A level only lands here once a
    /// pass/fail decision is made for it.
    private var perLevelCorrect: [Int: Int] = [:]
    private var didFinish = false

    var currentAcuity: Int { config.acuityLevels[currentIndex] }

    init(config: AcuityStaircaseConfig = AcuityStaircaseConfig()) {
        self.config = config
        let start = config.acuityLevels.firstIndex(of: config.startAcuity) ?? 0
        self.currentIndex = start
    }

    /// Records one trial. Returns the resulting transition.
    func record(correct: Bool) -> AcuityEngineEvent {
        precondition(!didFinish, "record(correct:) called after the staircase finished")

        trialsInLevel += 1
        if correct { correctInLevel += 1 }

        let earlyPass = trialsInLevel == config.earlySkipCount
            && correctInLevel == config.earlySkipCount
        let levelComplete = trialsInLevel >= config.trialsPerLevel || earlyPass

        guard levelComplete else {
            return .continueSameLevel(acuity: currentAcuity)
        }

        // On an early pass, record a perfect score for the level (source app behavior).
        let recordedCorrect = earlyPass ? config.trialsPerLevel : correctInLevel
        perLevelCorrect[currentAcuity] = recordedCorrect

        let passed = recordedCorrect >= config.advanceThreshold
        return passed ? advance() : stepBack()
    }

    /// Forces termination at the current state (used when the protocol cuts a condition short).
    func finalize() -> AcuityLevelResult {
        didFinish = true
        return makeResult()
    }

    // MARK: - Transitions

    private func advance() -> AcuityEngineEvent {
        // Already at the finest level, so the subject passed all configured levels.
        guard currentIndex < config.acuityLevels.count - 1 else {
            return finish()
        }
        currentIndex += 1
        resetLevelCounters()
        return .advance(toAcuity: currentAcuity)
    }

    private func stepBack() -> AcuityEngineEvent {
        // Already at the largest level and still failing, so the staircase cannot assess further.
        guard currentIndex > 0 else {
            return finish()
        }
        let previousAcuity = config.acuityLevels[currentIndex - 1]
        // If the previous larger level was already passed, the threshold sits between the two
        // levels. Otherwise step back and retest the larger level.
        if perLevelCorrect[previousAcuity] != nil {
            return finish()
        }
        currentIndex -= 1
        resetLevelCounters()
        return .stepBack(toAcuity: currentAcuity)
    }

    private func finish() -> AcuityEngineEvent {
        didFinish = true
        return .finished(result: makeResult())
    }

    private func resetLevelCounters() {
        correctInLevel = 0
        trialsInLevel = 0
    }

    // MARK: - Scoring

    /// Builds the result. The finest passed level is the smallest denominator whose recorded count
    /// met the advance threshold; logMAR is the table value plus the per-error adjustment used by
    /// the source app (`wrong / 100` for the finest passed level).
    private func makeResult() -> AcuityLevelResult {
        let passedLevels = perLevelCorrect
            .filter { $0.value >= config.advanceThreshold }
            .keys
        // Smallest denominator (= finest acuity) among passed levels.
        let finest = passedLevels.min() ?? config.acuityLevels[currentIndex]

        let base = config.logMAR[finest] ?? 0.0
        let correctAtFinest = perLevelCorrect[finest] ?? 0
        let wrong = Double(config.trialsPerLevel - correctAtFinest)
        let logMAR = base + wrong / 100.0

        let reachedGate: Bool
        if let gate = config.gateAcuity {
            reachedGate = finest <= gate
        } else {
            reachedGate = true
        }

        return AcuityLevelResult(
            finestAcuityReached: finest,
            logMAR: logMAR,
            reachedGate: reachedGate,
            perLevelCorrect: perLevelCorrect
        )
    }
}
