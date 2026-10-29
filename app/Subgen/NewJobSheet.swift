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
        VStack(alignment: .leading, spacing: 18) {
            Text("New Job").font(.system(size: 20, weight: .bold))

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    BoxedField(label: "YouTube link or video file", text: $source,
                               prompt: "YouTube link or video file", mono: true, height: 36)
                    Button("Choose File…") { chooseVideo() }
                        .buttonStyle(.subgen(.secondary, height: 36))
                }
                HStack(spacing: 8) {
                    Image(systemName: "film").font(.system(size: 15))
                    Text("or drop a video here")
                }
                .font(.system(size: 13))
                .foregroundStyle(dropTargeted ? Theme.ink : Theme.ink2)
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(dropTargeted ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(dropTargeted ? Theme.accent : Color(hex: 0xCFC6B5),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                    _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                        if let url { DispatchQueue.main.async { source = url.path } }
                    }
                    return true
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Read from").font(.system(size: 13, weight: .semibold))
                HStack(alignment: .top, spacing: 8) {
                    ForEach(JobMode.allCases) { m in ModeCard(mode: m, selected: mode == m) { mode = m } }
                }
            }

            VStack(spacing: 0) {
                OptionRow {
                    Text("Output name").frame(maxWidth: .infinity, alignment: .leading)
                    BoxedField(label: "Output name", text: $name, prompt: "video title", trailing: true)
                        .frame(width: 240)
                }
                OptionRow {
                    VStack(alignment: .leading, spacing: 10) {
                        SwitchRow(title: "Only part of the video", isOn: $partOnly)
                        if partOnly {
                            HStack(spacing: 8) {
                                Text("From").foregroundStyle(Theme.ink2)
                                BoxedField(label: "From", text: $startText, mono: true, size: 12.5).frame(width: 72)
                                Text("Length").foregroundStyle(Theme.ink2).padding(.leading, 8)
                                BoxedField(label: "Length", text: $durationText, mono: true, size: 12.5)
                                    .frame(width: 72)
                                Text("mm:ss").font(.system(size: 12)).foregroundStyle(Theme.ink3)
                            }
                            .font(.system(size: 12.5))
                            .padding(.leading, 14)
                        }
                    }
                }
                OptionRow { SwitchRow(title: "Also write English + Chinese file", isOn: $bilingual) }
                if mode != .ocr {
                    OptionRow {
                        SwitchRow(title: "Give Whisper the glossary names",
                                  caption: "A second Whisper pass. Slower, small gain.", isOn: $whisperHints)
                    }
                }
                OptionRow(last: true) {
                    Text("Glossary file").frame(maxWidth: .infinity, alignment: .leading)
                    BoxedField(label: "Glossary file", text: $glossary,
                               prompt: mode == .ocr ? "glossary.txt" : "built automatically", trailing: true)
                        .frame(width: 200)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.plainText]
                        if panel.runModal() == .OK, let p = panel.url?.path { glossary = p }
                    }
                    .buttonStyle(.subgen(.secondary, height: 28))
                }
            }
            .card(10)

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.subgen(.secondary, height: 32))
                Button("Add Job") {
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
                .buttonStyle(.subgen(.primary, height: 32))
                .disabled(!valid)
            }
        }
        .padding(24)
        .frame(width: 580)
        .background(Theme.bg)
        .foregroundStyle(Theme.ink)
    }

    private func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie]
        if panel.runModal() == .OK, let p = panel.url?.path { source = p }
    }
}

private struct ModeCard: View {
    let mode: JobMode
    let selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle().strokeBorder(selected ? Theme.ink : Theme.border, lineWidth: selected ? 4.5 : 1)
                            .background(Circle().fill(Theme.card))
                    }
                    .frame(width: 15, height: 15)
                    Text(title).font(.system(size: 13, weight: .semibold))
                }
                Text(desc)
                    .font(.system(size: 12)).lineSpacing(2).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
            .background(selected ? Theme.card : Theme.tile, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Theme.ink : Theme.divider, lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var title: String {
        switch mode {
        case .ocr: "Burned-in captions"
        case .merge: "Speech"
        case .whisper: "Whisper only"
        }
    }
    private var desc: String {
        switch mode {
        case .ocr: "Reads the Chinese text on screen with OCR. Fastest."
        case .merge: "Whisper + SenseVoice, reconciled by Claude. Most accurate."
        case .whisper: "Speech with one engine. Faster than Speech."
        }
    }
}

private struct OptionRow<Content: View>: View {
    var last = false
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 12) { content }
            .font(.system(size: 13))
            .padding(.horizontal, 14).padding(.vertical, 10)
            .overlay(alignment: .bottom) { if !last { Theme.rowLine.frame(height: 1) } }
    }
}

private struct SwitchRow: View {
    let title: String
    var caption: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let caption { Text(caption).font(.system(size: 12)).foregroundStyle(Theme.ink2) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Theme.ink)
        }
    }
}
