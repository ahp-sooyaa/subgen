import SwiftUI
import UniformTypeIdentifiers

struct NewJobSheet: View {
    var onAdd: (Job) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var source = ""
    @State private var mode: JobMode = .merge
    @State private var name = ""
    @State private var partOnly = false
    @State private var startText = "10:00"
    @State private var durationText = "5:00"
    @State private var bilingual = true
    @State private var whisperHints = false
    @State private var glossary = ""
    @State private var dropTargeted = false

    private var valid: Bool {
        let s = source.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return false }
        if partOnly && (parseTime(startText) == nil || parseTime(durationText) == nil) { return false }
        return s.hasPrefix("http") || FileManager.default.fileExists(atPath: s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Job").font(.title2.bold())

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("YouTube link or video file", text: $source)
                    Button("Choose File…") { chooseVideo() }
                }
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                    .foregroundStyle(dropTargeted ? Color.accentColor : .secondary.opacity(0.5))
                    .frame(height: 44)
                    .overlay(Text("or drop a video here").font(.callout).foregroundStyle(.secondary))
                    .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                        _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                            if let url { DispatchQueue.main.async { source = url.path } }
                        }
                        return true
                    }
            }

            Form {
                Picker("Read from", selection: $mode) {
                    ForEach(JobMode.allCases) { Text($0.label).tag($0) }
                }
                TextField("Output name", text: $name, prompt: Text("video title"))
                Toggle("Only part of the video", isOn: $partOnly)
                if partOnly {
                    HStack {
                        TextField("From", text: $startText).frame(width: 90)
                        TextField("Length", text: $durationText).frame(width: 90)
                        Text("mm:ss").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Also write English + Chinese file", isOn: $bilingual)
                if mode != .ocr {
                    Toggle("Give Whisper the glossary names (slower)", isOn: $whisperHints)
                }
                HStack {
                    TextField("Glossary file", text: $glossary,
                              prompt: Text(mode == .ocr ? "glossary.txt" : "built automatically"))
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.plainText]
                        if panel.runModal() == .OK, let p = panel.url?.path { glossary = p }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    var job = Job(source: source.trimmingCharacters(in: .whitespaces), mode: mode)
                    job.name = name.trimmingCharacters(in: .whitespaces)
                    if partOnly {
                        job.start = parseTime(startText)
                        job.duration = parseTime(durationText)
                    }
                    job.bilingual = bilingual
                    job.whisperHints = whisperHints && mode != .ocr
                    job.glossaryPath = glossary.isEmpty ? nil : glossary
                    onAdd(job)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie]
        if panel.runModal() == .OK, let p = panel.url?.path { source = p }
    }
}
