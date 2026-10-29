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
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)

        Settings { SettingsView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: JobStore?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)  // the design is light only
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop the running pipeline; it resumes from its caches next time.
        MainActor.assumeIsolated { store?.stopAllForQuit() }
    }
}
