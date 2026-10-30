import SwiftUI

struct JobDetailView: View {
    let job: Job
    var onOpenViewer: () -> Void
    @EnvironmentObject private var store: JobStore
    @State private var showLog = false
    @State private var showGlossary = false
    @State private var confirmRemove = false

    private var progress: JobProgress { store.progress[job.id] ?? JobProgress() }
    private var busy: Bool { job.status == .running || job.status == .paused }
    private var glossaryPath: String? { progress.glossaryPath ?? job.glossaryPath }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if job.status == .done {
                        compactStages
                        notices
                        outputs
                        FirstLines(enPath: progress.outputs["en"], bothPath: progress.outputs["en-zh"])
                    } else {
                        overall
                        notices
                        pipeline
                        outputs
                    }
                    log
                }
                .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 40)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showGlossary) {
            if let path = glossaryPath {
                GlossaryEditor(path: path, auto: progress.glossaryAuto) { retranslate in
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

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(job.displayName)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                switch job.status {
                case .running:
                    Button { store.pause(job.id) } label: { Label("Pause", systemImage: "pause.fill") }
                    Button { store.stop(job.id) } label: { Label("Stop", systemImage: "stop.fill") }
                case .paused:
                    Button { store.resume(job.id) } label: { Label("Continue", systemImage: "play.fill") }
                    Button { store.stop(job.id) } label: { Label("Stop", systemImage: "stop.fill") }
                case .queued:
                    Button { store.stop(job.id) } label: { Label("Don't Run", systemImage: "stop.fill") }
                case .stopped, .failed:
                    Button { store.resume(job.id) } label: { Label("Resume", systemImage: "play.fill") }
                case .done:
                    Button { store.resume(job.id) } label: { Label("Run Again", systemImage: "arrow.clockwise") }
                }
                if glossaryPath != nil {
                    Button { showGlossary = true } label: { Label("Glossary…", systemImage: "book.closed") }
                        .disabled(busy)
                        .help(busy ? "Available when the job is paused or finished" : "Edit the name glossary")
                }
            }
            .buttonStyle(.subgen)
            Button { confirmRemove = true } label: { Image(systemName: "trash").font(.system(size: 14)) }
                .buttonStyle(.subgen(.ghost))
                .foregroundStyle(Theme.ink2)
                .help("Remove job")
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background(Theme.bg)
        .overlay(alignment: .bottom) { Theme.hairline.frame(height: 1) }
        .windowDraggable()
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            VideoThumbnail(path: progress.videoPath)
            VStack(alignment: .leading, spacing: 10) {
                Text(progress.title ?? job.displayName)
                    .font(.system(size: 19, weight: .medium))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                FlowLayout(spacing: 6) {
                    statusPill
                    Pill(text: job.mode.label)
                    if let s = job.start, let d = job.duration {
                        Pill(text: "\(formatDuration(s))–\(formatDuration(s + d))")
                    }
                    if job.bilingual { Pill(text: "Bilingual") }
                }
                Text(shortSource)
                    .font(Theme.mono(11.5)).foregroundStyle(Theme.ink3)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private var statusPill: some View {
        switch job.status {
        case .running: Pill(text: "Running", tone: .running)
        case .done:
            let total = job.mode.stages.compactMap { progress.stages[$0]?.seconds }.reduce(0, +)
            Pill(text: total > 0 ? "Done in \(formatDuration(total))" : "Done", tone: .done)
        case .failed: Pill(text: "Failed", tone: .failed)
        default: Pill(text: job.status.label)
        }
    }

    private var shortSource: String {
        guard job.source.hasPrefix("http") else { return job.source }
        return job.source.replacingOccurrences(of: #"^https?://(www\.)?"#, with: "", options: .regularExpression)
    }

    // MARK: Progress

    private var overall: some View {
        let stages = job.mode.stages
        let currentIndex = progress.current.flatMap { stages.firstIndex(of: $0) }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(Int(progress.overall(job.mode) * 100))%")
                    .font(.system(size: 30, weight: .bold)).monospacedDigit()
                if let i = currentIndex, busy {
                    Text("Step \(i + 1) of \(stages.count) · \(stageLabel(stages[i]))")
                        .font(.system(size: 13)).foregroundStyle(Theme.ink2)
                } else {
                    Text(job.status == .queued ? "Waiting for the job ahead" : job.status.label)
                        .font(.system(size: 13)).foregroundStyle(Theme.ink2)
                }
                Spacer()
                if busy, let eta = progress.current.flatMap({ progress.stages[$0]?.eta }) {
                    Text("About \(formatDuration(eta)) left in this step")
                        .font(.system(size: 13)).monospacedDigit().foregroundStyle(Theme.ink2)
                }
            }
            HStack(spacing: 4) {
                ForEach(stages, id: \.self) { name in
                    let s = progress.stages[name]
                    Bar(value: s?.done == true ? 1 : (s?.frac ?? 0), height: 8,
                        fill: s?.done == true ? Theme.ink : Theme.accent)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .card()
    }

    private var pipeline: some View {
        let stages = job.mode.stages
        return VStack(alignment: .leading, spacing: 12) {
            Text("Pipeline").font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(stages.enumerated()), id: \.element) { i, name in
                    StageRow(name: name, stage: progress.stages[name],
                             active: progress.current == name && job.status == .running,
                             paused: progress.current == name && job.status == .paused,
                             last: i == stages.count - 1)
                }
            }
        }
    }

    private var compactStages: some View {
        FlowLayout(spacing: 8) {
            ForEach(job.mode.stages, id: \.self) { name in
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Theme.paper, Theme.ink)
                        .font(.system(size: 15))
                    Text(stageLabel(name)).fontWeight(.medium)
                    if let t = progress.stages[name]?.seconds {
                        Text(t < 1 ? "cached" : formatDuration(t)).monospacedDigit().foregroundStyle(Theme.ink2)
                    }
                }
                .font(.system(size: 12.5))
                .padding(.leading, 8).padding(.trailing, 11).padding(.vertical, 6)
                .card(8)
            }
        }
    }

    @ViewBuilder private var notices: some View {
        if let err = progress.error, job.status == .failed {
            Notice(text: err, systemImage: "exclamationmark.triangle", error: true)
        }
        ForEach(Array(progress.warnings.suffix(3).enumerated()), id: \.offset) { _, w in
            Notice(text: w, systemImage: "exclamationmark.circle")
        }
    }

    // MARK: Outputs

    @ViewBuilder private var outputs: some View {
        let order = ["en", "en-zh", "fixed", "zh"]
        let files = order.compactMap { k in progress.outputs[k].map { (k, $0) } }
        if !files.isEmpty {
            VStack(spacing: 0) {
                HStack {
                    Text("Subtitles").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button(action: onOpenViewer) { Label("Open Viewer", systemImage: "play.fill") }
                        .buttonStyle(.subgen(.primary, height: 32))
                        .disabled(progress.videoPath == nil || progress.outputs["en"] == nil)
                }
                .padding(.leading, 20).padding(.trailing, 16).padding(.vertical, 14)
                ForEach(files, id: \.0) { kind, path in
                    Theme.rowLine.frame(height: 1)
                    HStack(spacing: 16) {
                        Text(["en": "English", "en-zh": "English + Chinese", "fixed": "Chinese (corrected)",
                              "zh": "Chinese"][kind] ?? kind)
                            .fontWeight(.medium)
                            .frame(width: 150, alignment: .leading)
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .font(Theme.mono(12)).foregroundStyle(Theme.ink2)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                        .buttonStyle(LinkButtonStyle())
                        .fontWeight(.medium)
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 20).padding(.vertical, 12)
                }
            }
            .card()
        }
    }

    // MARK: Log

    private var log: some View {
        let text = store.logs[job.id] ?? ""
        let last = text.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return VStack(alignment: .leading, spacing: 10) {
            Theme.hairline.frame(height: 1)
            HStack(spacing: 10) {
                Button { withAnimation(.easeOut(duration: 0.15)) { showLog.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .rotationEffect(.degrees(showLog ? 90 : 0))
                        Text("Log").font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if !showLog, let last {
                    Text(last.trimmingCharacters(in: .whitespaces))
                        .font(Theme.mono(12)).foregroundStyle(Theme.ink3)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            if showLog {
                ScrollView {
                    Text(text)
                        .font(Theme.mono(11.5)).foregroundStyle(Theme.ink2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .defaultScrollAnchor(.bottom)
                .frame(height: 240)
                .card(10)
            }
        }
    }
}

struct Notice: View {
    let text: String
    let systemImage: String
    var error = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 14, weight: .semibold)).padding(.top, 1)
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 13))
        .foregroundStyle(error ? Theme.red : Theme.accentText)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(error ? Theme.redSoft : Theme.notice, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct StageRow: View {
    let name: String
    let stage: JobProgress.Stage?
    let active: Bool
    let paused: Bool
    let last: Bool

    private var done: Bool { stage?.done == true }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                marker
                if !last {
                    (done ? Theme.ink : Theme.divider).frame(width: 2).frame(minHeight: 14)
                }
            }
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(stageLabel(name))
                        .font(.system(size: 14, weight: active || paused ? .semibold : .regular))
                        .foregroundStyle(done || active || paused ? Theme.ink : Theme.ink2)
                    Spacer()
                    Text(detail).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Theme.ink2)
                }
                if active || paused {
                    VStack(alignment: .leading, spacing: 6) {
                        Bar(value: stage?.frac ?? 0, height: 6)
                        if let text = stage?.text, !text.isEmpty {
                            Text(text).font(Theme.mono(12)).foregroundStyle(Theme.ink2).lineLimit(1)
                        }
                    }
                }
            }
            .padding(.top, 1).padding(.bottom, 18)
        }
    }

    @ViewBuilder private var marker: some View {
        if done {
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(Theme.paper, Theme.ink)
                .font(.system(size: 22))
                .frame(width: 22, height: 22)
        } else if active || paused {
            ZStack {
                Circle().fill(Theme.accent)
                if paused {
                    Image(systemName: "pause.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.onAccent)
                } else {
                    Circle().fill(Theme.onAccent).frame(width: 8, height: 8)
                }
            }
            .frame(width: 22, height: 22)
        } else {
            Circle().fill(Theme.bg).overlay(Circle().strokeBorder(Theme.strongBorder, lineWidth: 1.5))
                .frame(width: 22, height: 22)
        }
    }

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

/// The opening cues of a finished job, as a preview.
struct FirstLines: View {
    let enPath: String?
    let bothPath: String?
    @State private var cues: [Cue] = []

    var body: some View {
        Group {
            if !cues.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("First lines").font(.system(size: 13, weight: .semibold))
                    VStack(spacing: 0) {
                        ForEach(cues) { c in
                            HStack(alignment: .top, spacing: 14) {
                                Text(formatDuration(c.start))
                                    .font(Theme.mono(12)).foregroundStyle(Theme.ink3)
                                    .frame(width: 64, alignment: .leading)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.en).font(.system(size: 14))
                                    if !c.zh.isEmpty {
                                        Text(c.zh).font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                                    }
                                }
                                .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 20).padding(.vertical, 8)
                        }
                    }
                    .padding(.vertical, 6)
                    .card()
                }
            }
        }
        .task(id: [enPath, bothPath]) {
            guard let enPath else { cues = []; return }
            cues = Array(SRT.load(en: enPath, both: bothPath).prefix(4))
        }
    }
}

/// Lays out children left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty && rows[rows.count - 1].width + spacing + size.width > maxWidth {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(i)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

struct GlossaryEditor: View {
    let path: String
    var auto = false
    var onClose: (_ retranslate: Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    private var count: Int { text.split(separator: "\n").filter { $0.contains("=") }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("Name glossary").font(.system(size: 20, weight: .bold))
                Spacer()
                if auto {
                    Label("Built from title, description and transcript", systemImage: "sparkle")
                        .labelStyle(TightLabelStyle())
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.chipText)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Theme.chip, in: Capsule())
                }
            }
            (Text("One per line: ")
             + Text("Chinese = English (he/she)").font(Theme.mono(12)).foregroundColor(Theme.ink)
             + Text(". Used by the translator. Re-translating doesn’t redo speech recognition or OCR."))
                .font(.system(size: 13)).lineSpacing(3).foregroundStyle(Theme.ink2)
            TextEditor(text: $text)
                .font(Theme.mono(13))
                .lineSpacing(5)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(.horizontal, 10).padding(.vertical, 10)
                .frame(minHeight: 280, maxHeight: 400)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(focused ? Theme.emphasis : Theme.border))
                .focusGlow(focused, radius: 10)
            HStack(spacing: 8) {
                Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(Theme.mono(11.5)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("\(count) name\(count == 1 ? "" : "s")").font(.system(size: 11.5))
            }
            .foregroundStyle(Theme.ink3)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.subgen(.secondary, height: 32))
                Button("Save") { save(); onClose(false); dismiss() }
                    .buttonStyle(.subgen(.secondary, height: 32))
                Button("Save & Re-translate") { save(); onClose(true); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.subgen(.primary, height: 32))
            }
        }
        .padding(24)
        .frame(width: 640)
        .background(Theme.bg)
        .foregroundStyle(Theme.ink)
        .onAppear { text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
    }

    private func save() { try? text.write(toFile: path, atomically: true, encoding: .utf8) }
}
