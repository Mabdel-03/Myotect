import SwiftUI

/// Color-coded distance-guidance pill, ported from the gold-standard app's `DistanceGuidanceView`
/// state machine: a red warning pill, a green auto-dismissing OK pill, and two-line directional
/// badges for too-far / too-close. Stateless — the coordinator owns the state (including the OK
/// auto-dismiss), this view just renders it with cross-fades.
struct DistanceGuidancePill: View {
    let state: DistanceGuidanceState

    var body: some View {
        ZStack {
            switch state {
            case .hidden:
                EmptyView()
            case .warning(let message):
                pill(icon: "exclamationmark.triangle.fill", title: message, subtitle: nil,
                     tint: .red)
            case .ok:
                pill(icon: "checkmark.circle.fill", title: "Distance locked in", subtitle: nil,
                     tint: .green)
            case .moveCloser:
                pill(icon: "arrow.down.forward.and.arrow.up.backward", title: "TOO FAR",
                     subtitle: "Move closer to continue", tint: .teal)
            case .moveFarther:
                pill(icon: "arrow.up.backward.and.arrow.down.forward", title: "TOO CLOSE",
                     subtitle: "Move farther to continue", tint: .pink)
            case .holdSteady:
                pill(icon: "hand.raised.fill", title: "Hold still…", subtitle: nil,
                     tint: .orange)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state)
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    private func pill(icon: String, title: String, subtitle: String?, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(tint.opacity(0.85), in: Capsule())
        .shadow(radius: 4)
    }
}
