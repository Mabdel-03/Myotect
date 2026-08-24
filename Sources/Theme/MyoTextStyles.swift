import SwiftUI

/// Text styles ported 1:1 from the gold app's `UILabel` helpers (`drawHeader`, `drawHeader2`,
/// `drawInstruction`, `drawSmallText`, `applyTestTypeTitle`). Sizes are fixed rather than
/// Dynamic Type — a deliberate gold-parity choice: optotype-adjacent chrome must not reflow.
extension View {
    /// Gold `drawHeader()`: 40pt bold, magenta.
    func myoHeader() -> some View {
        font(.system(size: 40, weight: .bold)).foregroundStyle(Color.myoMagenta)
    }

    /// Gold `drawHeader2()`: 35pt semibold, teal.
    func myoHeader2() -> some View {
        font(.system(size: 35, weight: .semibold)).foregroundStyle(Color.myoTeal)
    }

    /// Gold `drawInstruction()`: 30pt regular, black.
    func myoInstruction() -> some View {
        font(.system(size: 30, weight: .regular)).foregroundStyle(Color.black)
    }

    /// Gold `drawSmallText()`: 18pt regular, system gray.
    func myoSmallText() -> some View {
        font(.system(size: 18, weight: .regular)).foregroundStyle(Color.myoGrayText)
    }

    /// Gold two-line screen title, line 1: 36pt bold black.
    func myoScreenTitle() -> some View {
        font(.system(size: 36, weight: .bold)).foregroundStyle(Color.black)
    }
}

extension Text {
    /// Gold `applyTestTypeTitle`: 19pt black-weight, kern 1.8, uppercase — the second line of a
    /// screen title ("SCREENING SETUP", "DISTANCE SETUP").
    func myoTestTypeTitle(color: Color = .myoMagenta) -> some View {
        kerning(1.8)
            .font(.system(size: 19, weight: .black))
            .foregroundStyle(color)
            .textCase(.uppercase)
    }

    /// Gold pill badge line ("TOO FAR"): 13pt black-weight, kern 1.4, uppercase.
    func myoBadgeCaps(_ color: Color = .myoTeal) -> some View {
        kerning(1.4)
            .font(.system(size: 13, weight: .black))
            .foregroundStyle(color)
            .textCase(.uppercase)
    }
}
