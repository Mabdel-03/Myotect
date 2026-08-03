import Foundation

/// The three optotype rendering conditions used in the screening protocol.
///
/// Every condition is drawn as the letter inside a fixed-size colored square, wrapped by a blue border
/// square, on a black background (see ``OptotypeView``).
///
/// - `highContrast`: black optotype on white background. Used for the acuity gate.
/// - `lowContrastRed`: dark-red optotype on a brighter red background (long wavelength).
/// - `lowContrastGreen`: dark-teal optotype on a brighter teal background (short wavelength, a
///   blue-green blend). The case name is kept for on-disk/session compatibility; it renders teal.
///
/// The clinical comparison is between `lowContrastRed` and `lowContrastGreen`: subtle myopic
/// defocus blurs shorter wavelengths more, so the red condition may be read better than teal.
enum ColorCondition: String, Codable, CaseIterable {
    case highContrast
    case lowContrastRed
    case lowContrastGreen

    /// The two low-contrast duochrome conditions, in canonical order.
    static let lowContrastConditions: [ColorCondition] = [.lowContrastRed, .lowContrastGreen]

    /// Human-readable label for clinician / research output.
    var displayName: String {
        switch self {
        case .highContrast: return "High contrast"
        case .lowContrastRed: return "Low-contrast red"
        case .lowContrastGreen: return "Low-contrast teal"
        }
    }
}
