import SwiftUI

/// Main menu in the gold Visinear format: brand block, magenta "Menu" header, and a frosted
/// panel of standard teal buttons. Launches the Early Myopia Screen flow, history, and Settings
/// (screen calibration lives inside Settings, matching the gold app).
struct ContentView: View {
    @State private var showScreening = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer(minLength: 24)

                brandBlock

                Spacer(minLength: 16)

                Text("Menu")
                    .myoHeader()

                buttonPanel
                    .padding(.top, 20)

                Spacer(minLength: 32)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .decorativeDaisies(.myoMenuDaisies, over: .white)
            .fullScreenCover(isPresented: $showScreening) {
                // The screening cover SNAPSHOTS the settings per presentation: the config is
                // read fresh each time the flow is launched, and the coordinator then freezes
                // it for the whole session. A settings change mid-screening deliberately does
                // not apply (and must not — the session record carries one contrast).
                ScreeningRootView(config: Self.screeningConfig())
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
        .tint(.myoTeal)
    }

    /// Myotect branding in the gold format: symbol, letter-spaced wordmark, gray tagline.
    private var brandBlock: some View {
        VStack(spacing: 12) {
            Image(systemName: "eye")
                .font(.system(size: 64))
                .foregroundStyle(Color.myoTeal)
            Text("MYOTECT")
                .kerning(3)
                .font(.system(size: 34, weight: .heavy))
                .foregroundStyle(Color.myoWordmarkTeal)
            Text("App for early Myopia detection")
                .myoSmallText()
                .multilineTextAlignment(.center)
        }
    }

    /// Gold MainMenu button column: frosted rounded panel behind standard 242×60 teal buttons.
    private var buttonPanel: some View {
        VStack(spacing: 16) {
            Button("Test") { showScreening = true }
                .buttonStyle(.myoPrimary)

            NavigationLink {
                PreviousResultsView()
            } label: {
                MyoButtonLabel(title: "History")
            }

            Button("Settings") { showSettings = true }
                .buttonStyle(.myoPrimary)
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(white: 0.95).opacity(0.5))
        )
    }

    /// Builds the flow's config from the persisted operator settings, sampled at launch time.
    private static func screeningConfig() -> ScreenConfig {
        ScreenConfig(settings: ScreeningSettingsProvider().settings)
    }
}

#Preview {
    ContentView()
}
