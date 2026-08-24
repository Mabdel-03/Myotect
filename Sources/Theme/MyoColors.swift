import SwiftUI

/// The Myotect palette, ported from the sibling Visinear app's `AppThemeColors`/`TextPalette`
/// (Shared/Styling/UIStyle+Text.swift) so both apps share one visual language. Values are the
/// gold app's exact RGB components; the design is light-mode-only (see `MyotectApp`).
extension Color {
    /// Primary brand teal (#396C6D) — buttons, accents.
    static let myoTeal = Color(red: 0.224, green: 0.424, blue: 0.427)
    /// Header magenta (#C92B5E) — 40pt screen headers, accent strips, "TOO CLOSE" badges.
    static let myoMagenta = Color(red: 0.788, green: 0.169, blue: 0.369)
    /// Destructive red (#CC3333) — clear/retest actions.
    static let myoDestructive = Color(red: 0.8, green: 0.2, blue: 0.2)
    /// Action blue — share/secondary actions (gold uses systemBlue).
    static let myoActionBlue = Color(uiColor: .systemBlue)
    /// Soft teal surface "mist" (#EDF5F2) — too-far pill, mic pill.
    static let myoMist = Color(red: 0.93, green: 0.96, blue: 0.95)
    /// Soft magenta surface "blush" (#FAEDF2) — too-close pill.
    static let myoBlush = Color(red: 0.98, green: 0.93, blue: 0.95)
    /// Secondary text gray (gold `drawSmallText`).
    static let myoGrayText = Color(uiColor: .systemGray)
    /// Card borders (used at .opacity(0.55)).
    static let myoGrayBorder = Color(uiColor: .systemGray5)
    /// Screen/row surface (#F2F2F7) — results background, settings rows.
    static let myoSurface = Color(uiColor: .systemGray6)
    /// Wordmark / daisy-center teal (#406D74).
    static let myoWordmarkTeal = Color(red: 0.251, green: 0.427, blue: 0.455)

    // Status-pill palette (gold DistanceGuidanceView presets).
    static let myoWarnBg = Color(red: 1.0, green: 0.95, blue: 0.93)          // #FFF2ED
    static let myoWarnAccent = Color(red: 0.93, green: 0.42, blue: 0.32)     // #ED6B52
    static let myoOkBg = Color(red: 0.93, green: 0.97, blue: 0.94)           // #EDF7F0
    static let myoOkGreen = Color(red: 0.20, green: 0.58, blue: 0.38)        // #339460

    /// Magenta daisy CENTER color (#CC3366). Gold's magenta daisies use the header magenta
    /// (`myoMagenta`) for the petals and this only for the center dot.
    static let myoDaisyMagenta = Color(red: 0.8, green: 0.2, blue: 0.4)
}
