import SwiftUI

/// Color-coded distance-guidance pill in the gold `DistanceGuidanceView` format: soft-surface
/// rounded pills with a kerned uppercase badge line ("TOO FAR") over the directional message.
/// Stateless — the coordinator owns the state (including the OK auto-dismiss), this view just
/// renders whichever case is published, with cross-fades.
struct DistanceGuidancePill: View {
    let state: DistanceGuidanceState

    var body: some View {
        ZStack {
            switch state {
            case .hidden:
                EmptyView()
            case .warning(let message):
                MyoStatusPill(preset: .warning, title: message,
                              icon: "exclamationmark.triangle.fill")
            case .ok:
                MyoStatusPill(preset: .ok, title: "Distance locked in",
                              icon: "checkmark.circle.fill")
            case .moveCloser:
                MyoStatusPill(preset: .moveCloser, badge: "Too far",
                              title: "Move closer to continue")
            case .moveFarther:
                MyoStatusPill(preset: .moveFarther, badge: "Too close",
                              title: "Move farther to continue")
            case .holdSteady:
                MyoStatusPill(preset: .holdSteady, badge: "Hold still",
                              title: "Stay at this distance")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state)
        .transition(.opacity)
        .allowsHitTesting(false)
    }
}
