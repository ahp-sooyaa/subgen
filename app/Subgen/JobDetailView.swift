import SwiftUI

struct JobDetailView: View {
    let job: Job
    @EnvironmentObject private var store: JobStore
    @Environment(\.openWindow) private var openWindow
    @State private var showLog = false
    @State private var showGlossary = false
    @State private var confirmRemove = false

    private var progress: JobProgress { store.progress[job.id] ?? JobProgress() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                controls
                stages
                if let err = progress.error, job.status == .failed {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                ForEach(Array(progress.warnings.suffix(3).enumerated()), id: \.offset) { _, w in
                    Label(w, systemImage: "exclamationmark.circle").foregroundStyle(.orange).font(.callout)
                }
                outputs
                DisclosureGroup("Log", isExpanded: $showLog) {
                    ScrollView {
                        Text(store.logs[job.id] ?? "")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .defaultScrollAnchor(.bottom)
                    .frame(height: 240)
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .navigationTitle(job.displayName)
        .sheet(isPresented: $showGlossary) {
            if let path = progress.glossaryPath ?? job.glossaryPath {
                GlossaryEditor(path: path) { retranslate in
                    if retranslate { store.retranslate(job.id) }
                }
            }
        }
        .confirmationDialog("Remove this job?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { store.remove(job.id) }
        } message: {
            Text("Subtitle files and the pipeline's cache are kept.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(progress.title ?? job.displayName).font(.title2.bold()).textSelection(.enabled)
            HStack(spacing: 6) {
                Text(job.mode.label)
                if let s = job.start, let d = job.duration {
                    Text("· \(formatDuration(s))–\(formatDuration(s + d))")
                }
                Text("· \(job.status.label)")
            }
            .foregroundStyle(.secondary)
            Text(job.source).font(.caption).foregroundStyle(.tertiary).lineLimit(1).textSelection(.enabled)
        }
    }

    private var controls: some View {
        HStack {
            switch job.status {
            case .running:
                Button { store.pause(job.id) } label: { Label("Pause", systemImage: "pause.fill") }
                Button { store.stop(job.id) } label: { Label("Stop", systemImage: "stop.fill") }
            case .paused:
                Button { store.resume(job.id) } label: { Label("Continue", systemImage: "play.fill") }
                Button { store.stop(job.id) } label: { Label("Stop", systemImage: "stop.fill") }
            case .queued:
                Button { store.stop(job.id) } label: { Label("Don't run", systemImage: "stop.fill") }
            case .stopped, .failed:
                Button { store.resume(job.id) } label: { Label("Resume", systemImage: "play.fill") }
            case .done:
                Button { store.resume(job.id) } label: { Label("Run again", systemImage: "arrow.clockwise") }
            }
            if progress.glossaryPath != nil || job.glossaryPath != nil {
                Button { showGlossary = true } label: { Label("Glossary…", systemImage: "character.book.closed") }
                    .disabled(job.status == .running || job.status == .paused)
            }
            Spacer()
            Button(role: .destructive) { confirmRemove = true } label: { Label("Remove", systemImage: "trash") }
        }
        .controlSize(.large)
    }

    private var stages: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(job.mode.stages, id: \.self) { name in
                StageRow(name: name, stage: progress.stages[name],
                         active: progress.current == name && job.status == .running,
                         paused: progress.current == name && job.status == .paused)
            }
        }
    }

    @ViewBuilder private var outputs: some View {
        let order = ["en", "en-zh", "fixed", "zh"]
        let files = order.compactMap { k in progress.outputs[k].map { (k, $0) } }
        if !files.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Subtitles").font(.headline)
                    Spacer()
                    Button { openWindow(id: "viewer", value: job.id) } label: {
                        Label("Open Viewer", systemImage: "play.rectangle")
                    }
                    .disabled(progress.videoPath == nil || progress.outputs["en"] == nil)
                }
                ForEach(files, id: \.0) { kind, path in
                    HStack {
                        Text(["en": "English", "en-zh": "English + Chinese", "fixed": "Chinese (corrected)",
                              "zh": "Chinese"][kind] ?? kind)
                            .frame(width: 150, alignment: .leading)
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                        .buttonStyle(.link)
                    }
                    .font(.callout)
                }
            }
        }
    }
}

struct StageRow: View {
    let name: String
    let stage: JobProgress.Stage?
    let active: Bool
    let paused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon).foregroundStyle(color).frame(width: 18)
                Text(stageLabel(name)).fontWeight(active ? .semibold : .regular)
                Spacer()
                Text(detail).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            if (active || paused), let f = stage?.frac, f < 1 {
                ProgressView(value: f).padding(.leading, 26)
            } else if active {
                ProgressView().progressViewStyle(.linear).padding(.leading, 26)
            }
        }
    }

    private var icon: String {
        if stage?.done == true { return "checkmark.circle.fill" }
        if paused { return "pause.circle" }
        if active { return "circle.dotted" }
        return "circle"
    }
    private var color: Color { stage?.done == true ? .green : active ? .accentColor : .secondary }
    private var detail: String {
        guard let s = stage else { return "" }
        if s.done { return s.seconds.map { $0 < 1 ? "cached" : formatDuration($0) } ?? "done" }
        var parts: [String] = []
        if let f = s.frac { parts.append("\(Int(f * 100))%") }
        if active, let eta = s.eta { parts.append("\(formatDuration(eta)) left") }
        if paused { parts.append("paused") }
        return parts.joined(separator: " · ")
    }
}

struct GlossaryEditor: View {
    let path: String
    var onClose: (_ retranslate: Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Name glossary").font(.title3.bold())
            Text("One per line: `Chinese = English (he/she)`. Used by the translator; re-translating doesn't redo speech recognition or OCR.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 320)
            Text(path).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(); onClose(false); dismiss() }
                Button("Save & Re-translate") { save(); onClose(true); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600)
        .onAppear { text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
    }

    private func save() { try? text.write(toFile: path, atomically: true, encoding: .utf8) }
}
