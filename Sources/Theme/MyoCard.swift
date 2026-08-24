import SwiftUI

/// Gold result-card surface (`makeResultCard`): white, continuous corner radius 24, hairline
/// gray border, soft shadow, and an optional 6pt accent strip along the leading edge.
struct MyoCard<Content: View>: View {
    var accent: Color? = .myoMagenta
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 20)
            .padding(.trailing, 20)
            .padding(.leading, accent != nil ? 32 : 20)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.myoGrayBorder.opacity(0.55), lineWidth: 1)
            )
            .overlay(alignment: .leading) {
                if let accent {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(accent)
                        .frame(width: 6)
                        .padding(.vertical, 12)
                        .padding(.leading, 10)
                }
            }
            .shadow(color: .black.opacity(0.08), radius: 18, y: 10)
    }
}
