import SwiftUI

@main
struct MyotectApp: App {
    init() {
        FontRegistrar.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
