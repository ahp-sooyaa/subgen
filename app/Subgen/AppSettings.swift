import SwiftUI

/// Settings shared by the store (reads) and the Settings window (edits).
enum AppSettings {
    static let defaults = UserDefaults.standard
    static let defaultRepo = NSHomeDirectory() + "/Personal/subgen"

    static var repoPath: String { defaults.string(forKey: "repoPath") ?? defaultRepo }
    static var outputDir: String { defaults.string(forKey: "outputDir") ?? defaultRepo + "/out" }
    static var model: String { defaults.string(forKey: "model") ?? "sonnet" }
    static var appearance: AppAppearance {
        AppAppearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Applies to every window; nil follows the system setting.
    func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

struct SettingsView: View {
    @AppStorage("repoPath") private var repoPath = AppSettings.defaultRepo
    @AppStorage("outputDir") private var outputDir = AppSettings.defaultRepo + "/out"
    @AppStorage("model") private var model = "sonnet"
    @AppStorage("appearance") private var appearance = AppAppearance.system

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: appearance) { _, a in a.apply() }
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
