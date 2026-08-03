import SwiftUI

/// Warm-up: a few large, high-contrast, unscored letters. Verifies the voice path and reduces
/// learning effects. Feedback (a progress count) is allowed here, unlike the scored trials.
struct WarmupView: View {
    @ObservedObject var coordinator: MyopiaScreenCoordinator
    var clinician: ManualClinicianService?

    var body: some View {
        ZStack {
            AcuityTrialView(coordinator: coordinator, clinician: clinician)

            VStack {
                Text("Warm-up")
                    .font(.headline)
                Text("Say each letter out loud")
                    .font(.subheadline)
                Text("\(coordinator.warmupCompleted) / \(coordinator.config.warmupLetterCount)")
                    .font(.title3.monospacedDigit())
                    .padding(.top, 4)
                Spacer()
            }
            .padding(.top, 24)
            .foregroundStyle(.secondary)
        }
    }
}
