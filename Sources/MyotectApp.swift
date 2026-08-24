import SwiftUI

@main
struct MyotectApp: App {
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
    }
}
