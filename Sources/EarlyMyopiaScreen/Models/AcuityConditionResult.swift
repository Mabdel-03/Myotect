import Foundation

/// The summarized result of one ``ColorCondition`` run.
struct AcuityConditionResult: Codable, Equatable {
    let condition: ColorCondition
    /// Finest (smallest) Snellen denominator passed, i.e. the `x` in `20/x`.
    let finestAcuityDenominator: Int
    let logMAR: Double
    /// Whether the 20/25 gate was reached (only meaningful for the high-contrast condition).
    let reachedGate: Bool

    /// Snellen equivalent denominator derived from logMAR: `20 * 10^logMAR`.
    var snellenEquivalent: Double {
        20.0 * pow(10.0, logMAR)
    }
}
