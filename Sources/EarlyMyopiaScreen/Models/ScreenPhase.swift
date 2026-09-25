import Foundation

/// The phases of the screening flow. Drives the SwiftUI root view.
enum ScreenPhase: Equatable {
    case setup
    case distanceLock
    case warmup
    case highContrastGate
    case lowContrast(ColorCondition)
    case results
    case aborted(reason: String)

    /// The scored condition this phase presents, or nil for the unscored phases. The root view
    /// asks for confirmation before an operator skip (Next) on exactly these phases, because a
    /// skip here drops a condition result for good.
    var scoredCondition: ColorCondition? {
        switch self {
        case .highContrastGate: return .highContrast
        case .lowContrast(let condition): return condition
        case .setup, .distanceLock, .warmup, .results, .aborted: return nil
        }
    }
}
