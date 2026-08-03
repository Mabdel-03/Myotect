import SwiftUI

/// Main menu. Launches the Early Myopia Screen flow.
struct ContentView: View {
    @State private var showScreening = false
    @State private var showCalibration = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "eye")
                    .imageScale(.large)
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                Text("Myotect")
                    .font(.largeTitle.bold())
                Text("App for early Myopia detection")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("Early Myopia Screen") {
                    showScreening = true
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)

                NavigationLink("Previous results") {
                    PreviousResultsView()
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)

                Button("Screen calibration") {
                    showCalibration = true
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .fullScreenCover(isPresented: $showScreening) {
                ScreeningRootView()
            }
            .sheet(isPresented: $showCalibration) {
                // Stateless over UserDefaults, so per-presentation construction is safe.
                ScreenCalibrationView(provider: ScreenCalibrationProvider())
            }
        }
    }
}

#Preview {
    ContentView()
}
