import Foundation

/// One scored trial. Ambiguous / repeated attempts are never recorded as a trial.
struct TrialResult: Codable, Equatable {
    let condition: ColorCondition
    /// The `x` in `20/x`.
    let acuityDenominator: Int
    let shownLetter: String
    /// Recognized letter (uppercased Sloan letter).
    let response: String
    let isCorrect: Bool
    /// Eye-to-screen distance at the moment the response was scored, from a freshly validated
    /// sample (answers are rejected when no fresh sample exists).
    let distanceCM: Double
    /// Distance the visible stimulus was last sized for. Optional so pre-upgrade session JSON
    /// still decodes.
    var sizingDistanceCM: Double? = nil
    let responseTimeMS: Int
    /// 1-based trial number WITHIN the acuity level in progress (gold `nextTrialNumber`
    /// semantics): resets on every level change, and a distance-pause repeat keeps its number.
    let trialNumber: Int
    let timestamp: Date
    /// Exactly how the visible stimulus was sized (calibration identity, target mm, rendered
    /// points), re-validated against the live calibration before scoring. Optional so
    /// pre-upgrade session JSON still decodes.
    var provenance: SizingProvenance? = nil
}
