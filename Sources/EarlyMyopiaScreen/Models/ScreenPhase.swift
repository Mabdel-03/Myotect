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
}
