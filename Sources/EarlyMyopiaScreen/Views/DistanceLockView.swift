import SwiftUI

/// Guides the child to the target distance, then lets the OPERATOR capture it: the Capture
/// Distance button is live once a fresh in-band reading exists, tapping it anchors a 2-second
/// steady hold (with a whole-second countdown), and only hold completion advances to warm-up.
/// Drifting or losing the face voids the hold with a transient "try again" notice — port of the
/// gold-standard user-initiated capture flow, in the gold DistanceOptimization screen format.
/// The AR session is headless and coordinator-owned — it runs for the whole screening flow,
/// independent of this view's lifecycle.
struct DistanceLockView: View {
    @ObservedObject var coordinator: MyopiaScreenCoordinator

    var body: some View {
        ZStack {
            VStack(spacing: 24) {
                VStack(spacing: 4) {
                    Text("Get Into Position")
                        .myoScreenTitle()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("Distance Setup")
                        .myoTestTypeTitle()
                }

                statusBadge

                VStack(spacing: 4) {
                    Text(String(format: "Current distance: %.0f cm", coordinator.liveDistanceCM))
                        .font(.system(size: 30, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.black)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(String(format: "Target: %.0f cm", coordinator.config.targetDistanceCM))
                        .myoSmallText()
                }

                statusRow
                    .frame(minHeight: 64)

                captureButton
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .decorativeDaisies(.myoContentDaisies, over: .white)
    }

    /// The status row mirrors the gold layout: a retry notice takes priority, the hold shows its
    /// countdown, otherwise the guidance pill (which the coordinator hides once the subject is in
    /// band — an enabled Capture button speaks for itself).
    @ViewBuilder
    private var statusRow: some View {
        if let notice = coordinator.captureRetryNotice {
            MyoStatusPill(preset: .warning, title: notice,
                          icon: "exclamationmark.triangle.fill")
        } else if case .holding(let remaining) = coordinator.captureState {
            MyoPillChrome(preset: .holdSteady) {
                VStack(spacing: 2) {
                    Text("Hold still").myoBadgeCaps()
                    HStack(spacing: 6) {
                        Text("Capturing in")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.black)
                        Text("\(max(remaining, 1)) s")
                            .font(.system(size: 22, weight: .bold).monospacedDigit())
                            .foregroundStyle(Color.black)
                            .contentTransition(.numericText(countsDown: true))
                            .animation(.easeOut(duration: 0.18), value: remaining)
                    }
                }
            }
        } else {
            DistanceGuidancePill(state: coordinator.guidance)
        }
    }

    private var captureButton: some View {
        Button("Capture Distance") {
            coordinator.beginDistanceCapture()
        }
        .buttonStyle(.myoPrimary)
        .disabled(coordinator.captureState != .ready)
        .animation(.easeInOut(duration: 0.2), value: coordinator.captureState == .ready)
        .accessibilityLabel("Capture Distance")
    }

    private var statusBadge: some View {
        Image(systemName: badgeSymbol)
            .font(.system(size: 72))
            .foregroundStyle(badgeColor)
    }

    private var badgeSymbol: String {
        switch coordinator.captureState {
        case .captured: return "checkmark.circle.fill"
        case .holding: return "hand.raised.circle.fill"
        case .ready: return "checkmark.circle"
        case .waitingForSubject: return "arrow.up.and.down.circle"
        }
    }

    private var badgeColor: Color {
        switch coordinator.captureState {
        case .captured, .ready: return .myoOkGreen
        case .holding: return .orange
        case .waitingForSubject: return .myoDestructive
        }
    }
}
