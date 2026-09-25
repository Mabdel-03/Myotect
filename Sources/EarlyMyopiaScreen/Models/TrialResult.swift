import Foundation

/// One recorded trial. Ambiguous / filler / unintelligible attempts and distance-pause repeats are
/// never recorded. A spoken skip, a keypad "No response", and a voice no-input ARE, as incorrect
/// rows whose `response` is one of ``NonLetterResponse`` — and of those only the voice no-input
/// is recorded WITHOUT counting toward the staircase (``countsTowardStaircase`` false).
struct TrialResult: Codable, Equatable {
    let condition: ColorCondition
    /// The `x` in `20/x`.
    let acuityDenominator: Int
    let shownLetter: String
    /// Recognized letter (uppercased Sloan letter), or one of ``NonLetterResponse``.
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
    /// A no-input row shares its number with the letter that replaced it (the engine was not
    /// fed), so the number is unique within a level only among counted rows.
    let trialNumber: Int
    let timestamp: Date
    /// Exactly how the visible stimulus was sized (calibration identity, target mm, rendered
    /// points), re-validated against the live calibration before scoring. Optional so
    /// pre-upgrade session JSON still decodes.
    var provenance: SizingProvenance? = nil
    /// False for a voice trial that ended in the no-input window: the row is kept in the log but
    /// the staircase never saw it — the level did not move and a fresh letter replaced it at the
    /// same level (PROTOCOL §7, user decision 2026-09-03). Optional so pre-upgrade session JSON
    /// still decodes; absent means true (every row written before this field existed was a
    /// counted trial, including the "no input registered" misses of 2026-09-02).
    var countsTowardStaircase: Bool? = nil
}

extension TrialResult {
    /// Non-letter `response` values. Lowercase / punctuation, so none can ever equal an
    /// uppercase Sloan letter — the coordinator's `response == shownLetter` makes them incorrect.
    /// Written verbatim to JSON and CSV (no comma, quote, or newline, so the CSV stays unquoted).
    enum NonLetterResponse {
        /// Clinician keypad "No response".
        static let clinicianNoResponse = "-"
        /// The child said "skip" (``RecognitionOutcome/skipped``).
        static let skipped = "skip"
        /// The voice no-input window (`ScreenConfig.recognitionTimeoutSeconds`, a soft 10 s)
        /// elapsed with no speech-length sound and no usable text. Recorded as an incorrect row
        /// that does NOT count toward the staircase (`countsTowardStaircase == false`); a fresh
        /// letter replaced it at the same level.
        static let noInput = "no input registered"
    }
}
