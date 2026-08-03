import SwiftUI

/// Guides the child to the target distance with move-closer/farther/hold/locked guidance. The
/// coordinator auto-advances to warm-up once the distance locks. The AR session is headless and
/// coordinator-owned — it runs for the whole screening flow, independent of this view's lifecycle.
struct DistanceLockView: View {
    @ObservedObject var coordinator: MyopiaScreenCoordinator

    var body: some View {
        ZStack {
            VStack(spacing: 24) {
                Text("Get into position")
                    .font(.largeTitle.bold())

                statusBadge

                VStack(spacing: 4) {
                    Text(String(format: "Current distance: %.0f cm", coordinator.liveDistanceCM))
                    Text(String(format: "Target: %.0f cm", coordinator.config.targetDistanceCM))
                        .foregroundStyle(.secondary)
                }
                .font(.title3.monospacedDigit())

                DistanceGuidancePill(state: coordinator.guidance)
                    .frame(minHeight: 64)
            }
            .padding()
        }
    }

    private var statusBadge: some View {
        Image(systemName: coordinator.distanceStatus == .locked ? "checkmark.circle.fill" : "arrow.up.and.down.circle")
            .font(.system(size: 72))
            .foregroundStyle(statusColor)
    }

    private var statusColor: Color {
        switch coordinator.distanceStatus {
        case .locked: return .green
        case .holdSteady: return .orange
        default: return .red
        }
    }
}
