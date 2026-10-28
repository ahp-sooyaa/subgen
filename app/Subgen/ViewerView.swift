import AVKit
import SwiftUI

enum SubtitleLanguage: String, CaseIterable, Identifiable {
    case en = "English", zh = "Chinese", both = "Both"
    var id: String { rawValue }
}

@MainActor
final class ViewerModel: ObservableObject {
    @Published var cues: [Cue] = []
    @Published var current: Int?
    @Published var dirty = false
    @Published var saveError: String?
    let player: AVPlayer
    let enPath: String
    let bothPath: String?
    private var observer: Any?

    init(video: String, enPath: String, bothPath: String?) {
        self.enPath = enPath
        self.bothPath = bothPath
        player = AVPlayer(url: URL(fileURLWithPath: video))
        cues = SRT.load(en: enPath, both: bothPath)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
                                                  queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
    }

    func stopObserving() {
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        player.pause()
    }

    private func tick(_ t: Double) {
        let i = cues.firstIndex { $0.start <= t && t < $0.end }
        if i != current { current = i }
    }

    func seek(to cue: Cue) {
        player.seek(to: CMTime(seconds: cue.start + 0.01, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func save() {
        do {
            try SRT.write(cues, to: enPath) { $0.en }
            if let both = bothPath {
                try SRT.write(cues, to: both) { c in c.en.isEmpty ? "" : c.en + (c.zh.isEmpty ? "" : "\n" + c.zh) }
            }
            dirty = false
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }
}

/// AppKit's AVPlayerView. SwiftUI's VideoPlayer (_AVKit_SwiftUI) crashes on launch when the SDK the
/// app was built with is newer than the installed AVKit, so the AppKit view is used directly.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        // Both would move the video into AVKit's own window and leave our subtitles behind;
        // full screen is done on the whole window instead.
        view.showsFullScreenToggleButton = false
        view.allowsPictureInPicturePlayback = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// Hands back the NSWindow a view lives in.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// The viewer as it appears in the main window's detail column.
struct ViewerScreen: View {
    let jobID: UUID
    /// Set by the main window when the user picks another job; the viewer then leaves as if Back was pressed.
    @Binding var leaveRequested: Bool
    /// Called with true when the viewer may close, false when the user cancelled leaving.
    var onLeave: (Bool) -> Void
    @EnvironmentObject private var store: JobStore

    var body: some View {
        let p = store.progress[jobID]
        if let video = p?.videoPath, let en = p?.outputs["en"] {
            ViewerContent(video: video, enPath: en, bothPath: p?.outputs["en-zh"],
                          title: store.job(jobID)?.displayName ?? "Subtitles",
                          leaveRequested: $leaveRequested, onLeave: onLeave)
        } else {
            ContentUnavailableView("No subtitles yet", systemImage: "captions.bubble")
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button { onLeave(true) } label: { Label("Back", systemImage: "chevron.left") }
                    }
                }
                .onChange(of: leaveRequested) { _, r in if r { onLeave(true) } }
        }
    }
}

struct ViewerContent: View {
    @StateObject private var model: ViewerModel
    let title: String
    @Binding var leaveRequested: Bool
    var onLeave: (Bool) -> Void

    init(video: String, enPath: String, bothPath: String?, title: String,
         leaveRequested: Binding<Bool>, onLeave: @escaping (Bool) -> Void) {
        // Autoclosure: the player is created once, not on every refresh of the parent.
        _model = StateObject(wrappedValue: ViewerModel(video: video, enPath: enPath, bothPath: bothPath))
        self.title = title
        _leaveRequested = leaveRequested
        self.onLeave = onLeave
    }
    @State private var language: SubtitleLanguage = .both
    @State private var follow = true
    @AppStorage("viewerShowList") private var showList = true
    @State private var listBeforeFullScreen: Bool?
    @State private var window: NSWindow?
    @State private var confirmLeave = false

    var body: some View {
        HSplitView {
            GeometryReader { geo in
                PlayerView(player: model.player)
                    .overlay(alignment: .bottom) {
                        if let i = model.current {
                            // Scales with the video so it stays readable in full screen.
                            Text(overlay(model.cues[i]))
                                .font(.system(size: max(18, geo.size.height * 0.045), weight: .semibold))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.white)
                                .shadow(color: .black, radius: 2)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                                .padding(.horizontal, 24)
                                .padding(.bottom, max(56, geo.size.height * 0.08))
                                .allowsHitTesting(false)
                        }
                    }
            }
            .frame(minWidth: 520)

            if showList {
                cueList.frame(minWidth: 340, idealWidth: 420)
            }
        }
        .background(WindowAccessor { window = $0 })
        .navigationTitle(title + (model.dirty ? " — Edited" : ""))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { requestLeave() } label: { Label("Back", systemImage: "chevron.left") }
                    .keyboardShortcut("[", modifiers: .command)
                    .help("Back to the job (⌘[)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Subtitles", selection: $language) {
                    ForEach(SubtitleLanguage.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Follow video", isOn: $follow)
                Button { showList.toggle() } label: {
                    Label(showList ? "Hide Lines" : "Show Lines", systemImage: "sidebar.trailing")
                }
                .keyboardShortcut("l", modifiers: .command)
                .help("Show or hide the subtitle lines (⌘L)")
                Button { window?.toggleFullScreen(nil) } label: {
                    Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .help("Full screen with subtitles (⌃⌘F)")
                Button("Save") { model.save() }
                    .keyboardShortcut("s")
                    .disabled(!model.dirty)
            }
        }
        .onChange(of: leaveRequested) { _, r in if r { requestLeave() } }
        .confirmationDialog("Save your changes to the subtitles?", isPresented: $confirmLeave) {
            Button("Save") { model.save(); leave() }
            Button("Discard Changes", role: .destructive) { leave() }
            Button("Cancel", role: .cancel) { onLeave(false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { n in
            guard (n.object as? NSWindow) === window else { return }
            listBeforeFullScreen = showList
            showList = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { n in
            guard (n.object as? NSWindow) === window, let before = listBeforeFullScreen else { return }
            showList = before
            listBeforeFullScreen = nil
        }
        .onDisappear { model.stopObserving() }
    }

    private func requestLeave() {
        if model.dirty { confirmLeave = true } else { leave() }
    }

    private func leave() {
        model.stopObserving()
        if let w = window, w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
        onLeave(true)
    }

    private func overlay(_ c: Cue) -> String {
        switch language {
        case .en: c.en
        case .zh: c.zh
        case .both: [c.en, c.zh].filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    private var cueList: some View {
        VStack(spacing: 0) {
            if let err = model.saveError {
                Text("Couldn't save: \(err)").foregroundStyle(.red).font(.caption).padding(6)
            }
            ScrollViewReader { proxy in
                List {
                    ForEach($model.cues) { $cue in
                        CueRow(cue: $cue, isCurrent: model.current == cue.id) {
                            model.seek(to: cue)
                        } onEdit: {
                            model.dirty = true
                        }
                        .id(cue.id)
                    }
                }
                .onChange(of: model.current) { _, i in
                    if follow, let i { withAnimation { proxy.scrollTo(i, anchor: .center) } }
                }
            }
        }
    }
}

struct CueRow: View {
    @Binding var cue: Cue
    let isCurrent: Bool
    var onSeek: () -> Void
    var onEdit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onSeek) {
                Text(formatDuration(cue.start)).font(.caption.monospacedDigit())
            }
            .buttonStyle(.link)
            .help("Play from here")
            VStack(alignment: .leading, spacing: 2) {
                TextField("English", text: $cue.en, axis: .vertical)
                    .textFieldStyle(.plain)
                    .onChange(of: cue.en) { _, _ in onEdit() }
                if !cue.zh.isEmpty {
                    Text(cue.zh).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(isCurrent ? Color.accentColor.opacity(0.18) : Color.clear)
    }
}
