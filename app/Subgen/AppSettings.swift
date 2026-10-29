import SwiftUI

/// Settings shared by the store (reads) and the Settings window (edits).
enum AppSettings {
    static let defaults = UserDefaults.standard
    static let defaultRepo = NSHomeDirectory() + "/Personal/subgen"

    static var repoPath: String { defaults.string(forKey: "repoPath") ?? defaultRepo }
    static var outputDir: String { defaults.string(forKey: "outputDir") ?? defaultRepo + "/out" }
    static var model: String { defaults.string(forKey: "model") ?? "sonnet" }
}

struct SettingsView: View {
    @AppStorage("repoPath") private var repoPath = AppSettings.defaultRepo
    @AppStorage("outputDir") private var outputDir = AppSettings.defaultRepo + "/out"
    @AppStorage("model") private var model = "sonnet"

    var body: some View {
        Form {
            HStack {
                TextField("subgen folder", text: $repoPath)
                Button("Choose…") { if let p = chooseFolder() { repoPath = p } }
            }
            Text("Must contain .venv/bin/subgen.").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Subtitle output folder", text: $outputDir)
                Button("Choose…") { if let p = chooseFolder() { outputDir = p } }
            }
            Picker("Claude model for translation", selection: $model) {
                Text("Sonnet").tag("sonnet")
                Text("Opus").tag("opus")
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

func chooseFolder() -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    return panel.runModal() == .OK ? panel.url?.path : nil
}
