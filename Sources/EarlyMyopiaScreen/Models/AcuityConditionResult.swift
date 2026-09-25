import Foundation

/// The summarized result of one ``ColorCondition`` run.
struct AcuityConditionResult: Codable, Equatable {
    let condition: ColorCondition
    /// Finest (smallest) Snellen denominator passed, i.e. the `x` in `20/x`.
    let finestAcuityDenominator: Int
    let logMAR: Double
    /// Whether the finest PASSED line reached the 20/25 reference level (only meaningful for the
    /// high-contrast condition). Recorded for analysis; it never gates the flow — the
    /// low-contrast conditions always run.
    let reachedGate: Bool

    /// Snellen equivalent denominator derived from logMAR: `20 * 10^logMAR`.
    var snellenEquivalent: Double {
        20.0 * pow(10.0, logMAR)
    }
}
