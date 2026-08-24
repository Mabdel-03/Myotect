import Foundation

/// Tunable parameters for the acuity staircase.
struct AcuityStaircaseConfig {
    /// Snellen denominators from largest (easiest) to smallest (hardest). Note 25 is present so the
    /// 20/25 gate is a real level.
    var acuityLevels: [Int] = [200, 160, 125, 100, 80, 63, 50, 40, 32, 25, 20, 16]
    /// The acuity level the staircase begins at.
    var startAcuity: Int = 40
    /// Trials presented per level before a pass/fail decision (ETDRS five-letter line).
    var trialsPerLevel: Int = 5
    /// Minimum correct in a level to advance to a smaller (harder) level.
    var advanceThreshold: Int = 3
    /// If the first `earlySkipCount` trials are all correct, the level passes immediately and is
    /// recorded as a perfect line (gold `earlyPerfectCount`).
    var earlySkipCount: Int = 3
    /// logMAR spanned by one full line; one letter is worth `lineLogMARIncrement / trialsPerLevel`.
    var lineLogMARIncrement: Double = 0.1
    /// Per-letter logMAR credit (0.02 for the five-letter protocol).
    var logMARPerLetter: Double { lineLogMARIncrement / Double(trialsPerLevel) }
    /// The gate denominator: `reachedGate` is true when the finest passed level is this or finer.
    /// `nil` disables gating (used for the low-contrast conditions).
    var gateAcuity: Int? = 25
    /// Snellen-denominator to logMAR table, covering the full range of the source app's
    /// `usFootToLogMAR` so a clinician-tuned coarser level (e.g. 20/250) always has a base
    /// value — the engine refuses at init to run a level this table does not cover.
    var logMAR: [Int: Double] = [
        10: -0.3, 12: -0.2, 16: -0.1, 20: 0.0, 25: 0.1, 32: 0.2,
        40: 0.3, 50: 0.4, 63: 0.5, 80: 0.6, 100: 0.7, 125: 0.8,
        160: 0.9, 200: 1.0, 250: 1.1, 320: 1.2, 400: 1.3, 500: 1.4,
        630: 1.5, 800: 1.6, 1000: 1.7, 1250: 1.8, 1600: 1.9, 2000: 2.0,
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
///
/// The acuity threshold sits between the two *terminal* lines: `primaryAcuity` is the finer of
/// them — even when it was failed — and `secondaryAcuity` the coarser, exactly as in the gold
/// `ETDRSFinalResult`. The logMAR is the primary line's base value plus per-letter credit for
/// every miss across BOTH terminal lines.
struct AcuityLevelResult: Equatable {
    /// The finest (smallest) Snellen denominator the subject actually PASSED. When no level was
    /// passed at all, falls back to `secondaryAcuity` — the COARSER terminal line, i.e. the
    /// coarsest level near threshold — so reporting always has a denominator without ever
    /// overstating a failed run as a finer acuity than the subject demonstrated.
    let finestAcuityReached: Int
    /// `base(primaryAcuity) + (primaryWrong + secondaryWrong) × logMARPerLetter` (gold formula).
    let logMAR: Double
    /// True when the finest PASSED level is at least as fine as the configured gate. A failed
    /// primary line never opens the gate.
    let reachedGate: Bool
    /// Progression correct-count recorded per completed level (early-perfect recorded as a full
    /// line, matching gold `progressionCorrect`).
    let perLevelCorrect: [Int: Int]
    /// The finer terminal level (even when failed) — the base line of the score.
    let primaryAcuity: Int
    let primaryCorrect: Int
    /// The coarser terminal level.
    let secondaryAcuity: Int
    let secondaryCorrect: Int
}

/// A deterministic, UI-agnostic acuity staircase.
///
/// Port of the gold-standard `ETDRSProgressionEngine` (the authoritative ETDRS five-letter
/// protocol: 5 trials/line, ≥3 to advance, early-perfect at 3, two-terminal-line letter scoring),
/// restructured onto Myotect's event-driven engine API so it can be unit tested without any view
/// layer. Feed it one trial outcome at a time via ``record(correct:)``.
final class AcuityStaircaseEngine {
    let config: AcuityStaircaseConfig

    /// Everything the engine keeps per completed level (gold `ETDRSAcuityResult`).
    private struct LevelRecord {
        let presentations: Int
        let actualCorrect: Int
        let progressionCorrect: Int
        let usedPerfectShortcut: Bool
    }

    private(set) var currentIndex: Int
    /// Trials presented in the level currently in progress.
    private var attemptsInLevel = 0
    /// Correct answers accumulated in the level currently in progress.
    private var correctInLevel = 0
    /// A level lands here exactly once, when its pass/fail decision is made.
    private var resultsByLevel: [Int: LevelRecord] = [:]
    private var didFinish = false

    var currentAcuity: Int { config.acuityLevels[currentIndex] }

    /// 1-based trial number WITHIN the current level (gold `nextTrialNumber`); resets on every
    /// level change. Recorded per trial so the protocol position of each response is explicit.
    var nextTrialNumber: Int { attemptsInLevel + 1 }

    init(config: AcuityStaircaseConfig = AcuityStaircaseConfig()) {
        // Gold's engine throws on an invalid configuration; a non-throwing init fails loudly
        // instead — a level list the scoring table cannot cover must never silently score a
        // missing level as logMAR 0.0 (near-20/20 for a possibly unresolvable child).
        precondition(config.acuityLevels.count >= 2,
                     "acuityLevels needs at least two levels (gold tooFewAcuityLevels)")
        for level in config.acuityLevels {
            precondition(config.logMAR[level] != nil,
                         "acuity level 20/\(level) has no logMAR table entry (gold missingBaseLogMAR)")
        }
        self.config = config
        // An absent startAcuity falls back to the coarsest level, matching the gold caller.
        let start = config.acuityLevels.firstIndex(of: config.startAcuity) ?? 0
        self.currentIndex = start
    }

    /// Records one trial. Returns the resulting transition.
    func record(correct: Bool) -> AcuityEngineEvent {
        precondition(!didFinish, "record(correct:) called after the staircase finished")

        attemptsInLevel += 1
        if correct { correctInLevel += 1 }

        let earlyPerfect = attemptsInLevel == config.earlySkipCount
            && correctInLevel == config.earlySkipCount
        let completedFullLevel = attemptsInLevel >= config.trialsPerLevel

        guard earlyPerfect || completedFullLevel else {
            return .continueSameLevel(acuity: currentAcuity)
        }

        // On an early-perfect pass, record a full line (gold behavior).
        let progressionCorrect = earlyPerfect ? config.trialsPerLevel : correctInLevel
        resultsByLevel[currentAcuity] = LevelRecord(
            presentations: attemptsInLevel,
            actualCorrect: correctInLevel,
            progressionCorrect: progressionCorrect,
            usedPerfectShortcut: earlyPerfect)

        return completeLevel(acuity: currentAcuity, progressionCorrect: progressionCorrect)
    }

    // MARK: - Transitions (gold `completeCurrentAcuity`)

    private func completeLevel(acuity: Int, progressionCorrect: Int) -> AcuityEngineEvent {
        // Completing the finest level ends the test with that level as primary, pass or fail.
        if currentIndex == config.acuityLevels.count - 1 {
            let secondary = config.acuityLevels[currentIndex - 1]
            return finish(
                primary: acuity, primaryCorrect: progressionCorrect,
                secondary: secondary,
                secondaryCorrect: resultsByLevel[secondary]?.progressionCorrect ?? 0)
        }

        if progressionCorrect >= config.advanceThreshold {
            let nextAcuity = config.acuityLevels[currentIndex + 1]
            // Advancing into a level that already has a result means the threshold sits between
            // the two: finish instead of re-testing (and overwriting) the finer line.
            if let nextRecord = resultsByLevel[nextAcuity] {
                return finish(
                    primary: nextAcuity, primaryCorrect: nextRecord.progressionCorrect,
                    secondary: acuity, secondaryCorrect: progressionCorrect)
            }
            currentIndex += 1
            resetLevelCounters()
            return .advance(toAcuity: currentAcuity)
        }

        // Failed the largest level: score against the second-largest (tested or 0), gold rule.
        if currentIndex == 0 {
            let nextAcuity = config.acuityLevels[1]
            return finish(
                primary: nextAcuity,
                primaryCorrect: resultsByLevel[nextAcuity]?.progressionCorrect ?? 0,
                secondary: acuity, secondaryCorrect: progressionCorrect)
        }

        let previousAcuity = config.acuityLevels[currentIndex - 1]
        // Failing right above an already-passed level: the threshold is bracketed, with the
        // just-failed FINER line as primary (gold rule).
        if let previousRecord = resultsByLevel[previousAcuity] {
            return finish(
                primary: acuity, primaryCorrect: progressionCorrect,
                secondary: previousAcuity, secondaryCorrect: previousRecord.progressionCorrect)
        }

        currentIndex -= 1
        resetLevelCounters()
        return .stepBack(toAcuity: currentAcuity)
    }

    private func resetLevelCounters() {
        attemptsInLevel = 0
        correctInLevel = 0
    }

    // MARK: - Scoring (gold `finish`)

    private func finish(primary: Int, primaryCorrect: Int,
                        secondary: Int, secondaryCorrect: Int) -> AcuityEngineEvent {
        didFinish = true

        let trials = config.trialsPerLevel
        let primaryWrong = max(0, trials - primaryCorrect)
        let secondaryWrong = max(0, trials - secondaryCorrect)
        let base = config.logMAR[primary] ?? 0.0
        let logMAR = base + Double(primaryWrong + secondaryWrong) * config.logMARPerLetter

        let finestPassed = resultsByLevel
            .filter { $0.value.progressionCorrect >= config.advanceThreshold }
            .keys.min()
        let reachedGate: Bool
        if let gate = config.gateAcuity {
            reachedGate = finestPassed.map { $0 <= gate } ?? false
        } else {
            reachedGate = true
        }

        return .finished(result: AcuityLevelResult(
            finestAcuityReached: finestPassed ?? secondary,
            logMAR: logMAR,
            reachedGate: reachedGate,
            perLevelCorrect: resultsByLevel.mapValues(\.progressionCorrect),
            primaryAcuity: primary,
            primaryCorrect: primaryCorrect,
            secondaryAcuity: secondary,
            secondaryCorrect: secondaryCorrect))
    }
}
