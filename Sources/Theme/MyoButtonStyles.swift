import SwiftUI

/// Port of the gold `drawStandardButton()`: solid color, white title, corner radius 8, standard
/// 242×60 block. Gold titles are 35pt but clip at 242pt with Myotect's longer titles, so the
/// default is 28pt with scale-to-fit (documented deviation). Disabled state renders at 0.45
/// opacity (the gold capture-button dimming), pressed at 0.85.
struct MyoPrimaryButtonStyle: ButtonStyle {
    var background: Color = .myoTeal
    var width: CGFloat? = 242
    var height: CGFloat = 60
    var fontSize: CGFloat = 28

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(MyoButtonChrome(background: background, width: width,
                                      height: height, fontSize: fontSize))
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1.0) : 0.45)
    }
}

extension ButtonStyle where Self == MyoPrimaryButtonStyle {
    /// Standard teal 242×60 (gold's default button).
    static var myoPrimary: MyoPrimaryButtonStyle { .init() }
    /// Destructive red variant (gold Retest/Clear).
    static var myoDestructiveStyle: MyoPrimaryButtonStyle { .init(background: .myoDestructive) }
    /// Action-blue variant (gold Share).
    static var myoAction: MyoPrimaryButtonStyle { .init(background: .myoActionBlue) }
    /// Compact 242×52 (gold Settings calibration button).
    static var myoCompact: MyoPrimaryButtonStyle { .init(height: 52, fontSize: 22) }
}

/// The visual chrome shared by the button style and `MyoButtonLabel`, so a `NavigationLink`
/// label renders pixel-identically to a styled `Button`.
private struct MyoButtonChrome: ViewModifier {
    let background: Color
    let width: CGFloat?
    let height: CGFloat
    let fontSize: CGFloat

    func body(content: Content) -> some View {
        content
            .font(.system(size: fontSize))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 12)
            .frame(width: width, height: height)
            .background(RoundedRectangle(cornerRadius: 8).fill(background))
    }
}

/// A gold-format button face for contexts that are not `Button`s (e.g. `NavigationLink` labels).
struct MyoButtonLabel: View {
    let title: String
    var background: Color = .myoTeal
    var width: CGFloat? = 242
    var height: CGFloat = 60
    var fontSize: CGFloat = 28

    var body: some View {
        Text(title)
            .modifier(MyoButtonChrome(background: background, width: width,
                                      height: height, fontSize: fontSize))
    }
}
