import SwiftUI
import TokenBarLib

@main
struct TokenBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        Analytics.setup()
    }

    var body: some Scene {
        // Settings window is managed directly by AppDelegate via NSWindow.
        // This empty Settings scene satisfies SwiftUI's Scene requirement.
        Settings {
            EmptyView()
        }
    }
}
