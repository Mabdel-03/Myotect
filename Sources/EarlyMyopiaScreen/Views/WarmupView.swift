import SwiftUI

/// Warm-up: a few large, high-contrast, unscored letters. Verifies the voice path and reduces
/// learning effects. Feedback (a progress count) is allowed here, unlike the scored trials.
/// The overlay uses the gold pill treatment; the black stimulus field underneath is untouched.
struct WarmupView: View {
    @ObservedObject var coordinator: MyopiaScreenCoordinator
    var clinician: ManualClinicianService?

    var body: some View {
        ZStack {
            AcuityTrialView(coordinator: coordinator, clinician: clinician, showsHeardLine: false)

            VStack {
                MyoPillChrome(preset: .holdSteady) {
                    VStack(spacing: 2) {
                        Text("Warm-up").myoBadgeCaps()
                        Text("Say each letter out loud")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.black)
                        Text("\(coordinator.warmupCompleted) / \(coordinator.config.warmupLetterCount)")
                            .font(.system(size: 18, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Color.myoTeal)
                    }
                }
                // The operator "Heard" line lives here rather than in the trial view's default
                // top slot, which the warm-up pill already occupies.
                HeardDiagnosticLine(coordinator: coordinator)
                    .padding(.top, 8)
                Spacer()
            }
            .padding(.top, 24)
            .allowsHitTesting(false)
        }
    }
}
