import SwiftUI

@main
struct MyotectApp: App {
    @Environment(\.scenePhase) private var scenePhase
    /// App-lifetime, not session-scoped: the display must never sleep while Myotect is in the
    /// foreground, on the menu and results screens as much as mid-trial.
    private let idleTimer = IdleTimerController()

    init() {
        FontRegistrar.register()
    }

    var body: some Scene {
        WindowGroup {
            // The Visinear design system is light-only (gold parity); presentation roots that
            // create their own environments re-apply this.
            ContentView()
                .preferredColorScheme(.light)
        }
        // `initial: true` covers first launch, where the opening `.active` may not arrive as a
        // change event. Re-asserted on every `.active` because iOS can reset the flag across
        // scene transitions.
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            switch newPhase {
            case .active: idleTimer.disableSleep()
            case .background: idleTimer.restore()
            default: break
            }
        }
    }
}
