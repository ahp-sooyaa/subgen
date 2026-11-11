import SwiftUI

/// Settings shared by the store (reads) and the Settings window (edits).
enum AppSettings {
    static let defaults = UserDefaults.standard
    static let defaultRepo = NSHomeDirectory() + "/Personal/subgen"

    static var repoPath: String { defaults.string(forKey: "repoPath") ?? defaultRepo }
    static var outputDir: String { defaults.string(forKey: "outputDir") ?? defaultRepo + "/out" }
    static var model: String { defaults.string(forKey: "model") ?? "sonnet" }
    /// Also fetch a 1080p copy of YouTube videos for the viewer.
    static var hdCopy: Bool { defaults.object(forKey: "hdCopy") as? Bool ?? true }
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
    @AppStorage("hdCopy") private var hdCopy = true

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { _, a in a.apply() }
            }
            Section {
                folderRow("subgen folder", path: $repoPath, note: "Must contain .venv/bin/subgen.")
                folderRow("Subtitle output folder", path: $outputDir, note: nil)
            }
            Section {
                Picker("Translation model", selection: $model) {
                    Text("Sonnet").tag("sonnet")
                    Text("Opus").tag("opus")
                }
                Toggle(isOn: $hdCopy) {
                    Text("Download HD copy for watching")
                    Text("YouTube jobs also fetch 1080p for the viewer. Those files are roughly 2–3× larger.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func folderRow(_ title: String, path: Binding<String>, note: String?) -> some View {
        LabeledContent {
            HStack {
                TextField(title, text: path)
                    .labelsHidden()
                    .truncationMode(.head)
                Button("Choose…") { if let p = chooseFolder() { path.wrappedValue = p } }
            }
            .frame(width: 300)
        } label: {
            Text(title)
            if let note { Text(note) }
        }
    }
}

func chooseFolder() -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    return panel.runModal() == .OK ? panel.url?.path : nil
}
