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
        .defaultSize(width: 980, height: 640)

        WindowGroup("Subtitles", id: "viewer", for: UUID.self) { $id in
            if let id {
                ViewerView(jobID: id).environmentObject(store)
            }
        }
        .defaultSize(width: 1200, height: 720)

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
