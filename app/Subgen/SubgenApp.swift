import SwiftUI

@main
struct SubgenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = JobStore()

    var body: some Scene {
        WindowGroup("Subgen") {
            ContentView()
                .environmentObject(store)
                .onAppear { delegate.store = store }
        }
        .defaultSize(width: 1180, height: 720)

        Settings { SettingsView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: JobStore?

    func applicationWillTerminate(_ notification: Notification) {
        // Stop the running pipeline; it resumes from its caches next time.
        MainActor.assumeIsolated { store?.stopAllForQuit() }
    }
}
