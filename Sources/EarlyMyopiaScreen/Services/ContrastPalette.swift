import SwiftUI

/// Contrast configuration for the optotype conditions.
///
/// Uses the Weber contrast definition for letter tests:
/// `contrast = (background - stimulus) / background`, i.e. `stimulus = background * (1 - weber)`.
struct ContrastConfig {
    /// Weber contrast. 0.10 (10%) is the default; the operator may select 0.05 / 0.10 / 0.15
    /// in Settings (see `ScreeningSettingsProvider`).
    var weber: Double = 0.10
    /// Background channel brightness in 0...1. The stimulus is darker by the Weber fraction.
    var backgroundBrightness: Double = 1.0

    init(weber: Double = 0.10, backgroundBrightness: Double = 1.0) {
        self.weber = weber
        self.backgroundBrightness = backgroundBrightness
    }
}

/// A background/stimulus color pair for one optotype presentation.
struct OptotypeColors: Equatable {
    let background: Color
    let stimulus: Color
}

/// Generates the color pairs for each ``ColorCondition`` using Weber contrast.
///
/// This uses sRGB channel values, not photometric luminance. For clinical-grade validation
/// the team may later need device-specific luminance calibration.
enum ContrastPalette {
    /// Stimulus brightness for a given background and Weber contrast.
    /// Pure function used as the unit-tested calculation boundary.
    static func stimulusBrightness(background: Double, weber: Double) -> Double {
        background * (1.0 - weber)
    }

    static func colors(for condition: ColorCondition, config: ContrastConfig) -> OptotypeColors {
        switch condition {
        case .highContrast:
            return OptotypeColors(background: .white, stimulus: .black)

        case .lowContrastRed:
            let bg = config.backgroundBrightness
            let stim = stimulusBrightness(background: bg, weber: config.weber)
            return OptotypeColors(
                background: Color(.sRGB, red: bg, green: 0, blue: 0, opacity: 1),
                stimulus: Color(.sRGB, red: stim, green: 0, blue: 0, opacity: 1)
            )

        case .lowContrastGreen:
            // Teal (blue-green) short-wavelength condition: the green channel plus a matching fraction
            // of the same brightness in the blue channel, keeping red at 0 so no long-wavelength light
            // contaminates the short-wavelength stimulus. Weber contrast is preserved per channel, so
            // the duochrome comparison against the red condition is unchanged. `tealBlueFraction` tunes
            // Green to teal to cyan; the clinical team can lower it toward the muted teal in the reference.
            let bg = config.backgroundBrightness
            let stim = stimulusBrightness(background: bg, weber: config.weber)
            return OptotypeColors(
                background: Color(.sRGB, red: 0, green: bg, blue: bg * tealBlueFraction, opacity: 1),
                stimulus: Color(.sRGB, red: 0, green: stim, blue: stim * tealBlueFraction, opacity: 1)
            )
        }
    }

    /// Fraction of the green-channel brightness mixed into the blue channel for the short-wavelength
    /// (teal) condition. 1.0 is a full blue-green teal (cyan at full brightness); lower values lean
    /// back toward pure green. Exposed for clinical tuning.
    static let tealBlueFraction: Double = 1.0

    /// The accommodation-relaxing frame color drawn as the square border around every optotype.
    static let blueFrame = Color(.sRGB, red: 0, green: 0, blue: 1, opacity: 1)
}
