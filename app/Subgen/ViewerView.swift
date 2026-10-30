import AVKit
import SwiftUI

enum SubtitleLanguage: String, CaseIterable, Identifiable {
    case en = "English", zh = "Chinese", both = "Both"
    var id: String { rawValue }
}

/// Playback position, kept apart from the cues so the clock ticking only redraws the transport bar.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var time: Double = 0
    @Published var duration: Double = 0
    @Published var playing = false
}

@MainActor
final class ViewerModel: ObservableObject {
    @Published var cues: [Cue] = []
    @Published var current: Int?
    @Published var dirty = false
    @Published var saveError: String?
    let clock = PlaybackClock()
    let player: AVPlayer
    let enPath: String
    let bothPath: String?
    /// English text as loaded, to mark the lines the user changed.
    private(set) var original: [Int: String] = [:]
    private var observer: Any?

    init(video: String, enPath: String, bothPath: String?) {
        self.enPath = enPath
        self.bothPath = bothPath
        player = AVPlayer(url: URL(fileURLWithPath: video))
        cues = SRT.load(en: enPath, both: bothPath)
        original = Dictionary(uniqueKeysWithValues: cues.map { ($0.id, $0.en) })
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
                                                  queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        Task { [weak self] in
            guard let asset = self?.player.currentItem?.asset,
                  let d = try? await asset.load(.duration).seconds, d.isFinite else { return }
            self?.clock.duration = d
        }
    }

    func stopObserving() {
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        player.pause()
    }

    private func tick(_ t: Double) {
        clock.time = t
        let playing = player.rate != 0
        if clock.playing != playing { clock.playing = playing }
        let i = cues.firstIndex { $0.start <= t && t < $0.end }
        if i != current { current = i }
    }

    func togglePlay() {
        if player.rate != 0 { player.pause() } else { player.play() }
        clock.playing = player.rate != 0
    }

    func seek(to t: Double) {
        player.seek(to: CMTime(seconds: max(0, t), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        clock.time = t
    }

    func seek(to cue: Cue) { seek(to: cue.start + 0.01) }

    func originalText(_ id: Int) -> String? { original[id] }

    func save() {
        do {
            try SRT.write(cues, to: enPath) { $0.en }
            if let both = bothPath {
                try SRT.write(cues, to: both) { c in c.en.isEmpty ? "" : c.en + (c.zh.isEmpty ? "" : "\n" + c.zh) }
            }
            original = Dictionary(uniqueKeysWithValues: cues.map { ($0.id, $0.en) })
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
        view.controlsStyle = .none  // the viewer draws its own transport bar
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
            VStack(spacing: 0) {
                ViewerHeader(onBack: { onLeave(true) }) { Text("No subtitles yet").font(.system(size: 15, weight: .semibold)) }
                ContentUnavailableView("No subtitles yet", systemImage: "captions.bubble")
            }
            .onChange(of: leaveRequested) { _, r in if r { onLeave(true) } }
        }
    }
}

/// The viewer's bar across the top of the window, with room for the window buttons.
struct ViewerHeader<Title: View, Trailing: View>: View {
    var onBack: () -> Void
    @ViewBuilder var title: Title
    @ViewBuilder var trailing: Trailing
    /// In full screen macOS hides the window buttons, so their gap goes too.
    @State private var fullScreen = false
    @State private var window: NSWindow?

    init(onBack: @escaping () -> Void, @ViewBuilder title: () -> Title,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.onBack = onBack
        self.title = title()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) { Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold)) }
                .buttonStyle(.subgen(.ghost))
                .keyboardShortcut("[", modifiers: .command)
                .help("Back to the job (⌘[)")
            title.frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.leading, fullScreen ? 16 : 84).padding(.trailing, 16)
        .frame(height: 52)
        .background(Theme.sidebar)
        .overlay(alignment: .bottom) { Theme.hairline.frame(height: 1) }
        .windowDraggable()
        .background(WindowAccessor { w in
            window = w
            fullScreen = w?.styleMask.contains(.fullScreen) ?? false
        })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { n in
            if (n.object as? NSWindow) === window { fullScreen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { n in
            if (n.object as? NSWindow) === window { fullScreen = false }
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
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                video
                if showList {
                    Theme.divider.frame(width: 1)
                    lines.frame(width: 400)
                }
            }
        }
        .background(WindowAccessor { window = $0 })
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

    private var header: some View {
        ViewerHeader(onBack: requestLeave) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                if model.dirty {
                    Text("Edited")
                        .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.accentText)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Theme.accentSoft, in: Capsule())
                }
            }
        } trailing: {
            SegmentedPicker(selection: $language)
            Toggle("Follow video", isOn: $follow)
                .toggleStyle(.checkbox)
                .tint(Theme.emphasis)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.chipText)
                .padding(.horizontal, 8)
            Button { showList.toggle() } label: {
                Image(systemName: "sidebar.trailing").font(.system(size: 15))
            }
            .buttonStyle(.subgen(.ghost))
            .background(showList ? Theme.segment : .clear, in: RoundedRectangle(cornerRadius: 7))
            .keyboardShortcut("l", modifiers: .command)
            .help(showList ? "Hide the subtitle lines (⌘L)" : "Show the subtitle lines (⌘L)")
            Button("Save") { model.save() }
                .buttonStyle(.subgen(.primary))
                .keyboardShortcut("s")
                .disabled(!model.dirty)
        }
    }

    private var video: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                PlayerView(player: model.player)
                    .overlay(alignment: .bottom) {
                        if let i = model.current, !overlay(model.cues[i]).isEmpty {
                            // Scales with the video so it stays readable in full screen.
                            let size = max(20, geo.size.height * 0.05)
                            VStack(spacing: 4) {
                                if language != .zh, !model.cues[i].en.isEmpty {
                                    Text(model.cues[i].en).font(.system(size: size, weight: .semibold))
                                }
                                if language != .en, !model.cues[i].zh.isEmpty {
                                    Text(model.cues[i].zh).font(.system(size: size * 0.75, weight: .medium))
                                }
                            }
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .shadow(color: .black, radius: 1, y: 1)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                            .padding(.horizontal, 24)
                            .padding(.bottom, max(24, geo.size.height * 0.06))
                            .allowsHitTesting(false)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.togglePlay() }
            }
            Transport(model: model, clock: model.clock)
        }
        .frame(minWidth: 520)
        .background(Theme.video)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) { model.togglePlay(); return .handled }
    }

    private var lines: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Lines").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Click a time to play from there").font(.system(size: 12)).foregroundStyle(Theme.ink2)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .overlay(alignment: .bottom) { Theme.hairline.frame(height: 1) }
            if let err = model.saveError {
                Notice(text: "Couldn't save: \(err)", systemImage: "exclamationmark.triangle", error: true)
                    .padding(8)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach($model.cues) { $cue in
                            CueRow(cue: $cue, isCurrent: model.current == cue.id,
                                   original: model.originalText(cue.id)) {
                                model.seek(to: cue)
                            } onEdit: {
                                model.dirty = true
                            }
                            .id(cue.id)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                }
                .onChange(of: model.current) { _, i in
                    if follow, let i { withAnimation { proxy.scrollTo(i, anchor: .center) } }
                }
            }
        }
        .background(Theme.bg)
    }

    private func requestLeave() {
        if model.dirty { confirmLeave = true } else { leave() }
    }

    private func leave() {
        model.stopObserving()
        // Full screen stays on; only the lines panel it hid comes back for next time.
        if let before = listBeforeFullScreen { showList = before }
        onLeave(true)
    }

    private func overlay(_ c: Cue) -> String {
        switch language {
        case .en: c.en
        case .zh: c.zh
        case .both: [c.en, c.zh].filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }
}

struct SegmentedPicker: View {
    @Binding var selection: SubtitleLanguage

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SubtitleLanguage.allCases) { lang in
                let on = selection == lang
                Button { selection = lang } label: {
                    Text(lang.rawValue)
                        .font(.system(size: 12.5, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? Theme.ink : Theme.chipText)
                        .padding(.horizontal, 12).frame(height: 26)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 6).fill(Theme.segmentOn)
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Theme.segment, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Play button, times and a scrubber.
struct Transport: View {
    let model: ViewerModel
    @ObservedObject var clock: PlaybackClock
    @State private var scrub: Double?

    var body: some View {
        HStack(spacing: 14) {
            Button { model.togglePlay() } label: {
                Image(systemName: clock.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.video)
                    .frame(width: 34, height: 34)
                    .background(Theme.videoText, in: Circle())
            }
            .buttonStyle(.plain)
            .help(clock.playing ? "Pause" : "Play")
            Text(formatDuration(scrub ?? clock.time)).font(Theme.mono(12)).foregroundStyle(Theme.videoMuted)
            GeometryReader { geo in
                let w = geo.size.width
                let frac = clock.duration > 0 ? min(max((scrub ?? clock.time) / clock.duration, 0), 1) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.videoTrack).frame(height: 4)
                    Capsule().fill(Theme.accent).frame(width: w * frac, height: 4)
                    Circle().fill(Theme.videoText).frame(width: 12, height: 12).offset(x: w * frac - 6)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in scrub = clock.duration * min(max(v.location.x / w, 0), 1) }
                    .onEnded { _ in
                        if let s = scrub { model.seek(to: s) }
                        scrub = nil
                    })
            }
            .frame(height: 18)
            Text(formatDuration(clock.duration)).font(Theme.mono(12)).foregroundStyle(Theme.videoMuted)
        }
        .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 14)
    }
}

struct CueRow: View {
    @Binding var cue: Cue
    let isCurrent: Bool
    let original: String?
    var onSeek: () -> Void
    var onEdit: () -> Void

    private var edited: Bool { original != nil && original != cue.en }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onSeek) {
                Text(formatDuration(cue.start)).font(Theme.mono(12))
            }
            .buttonStyle(LinkButtonStyle())
            .frame(width: 52, alignment: .leading)
            .padding(.top, 2)
            .help("Play from here")
            VStack(alignment: .leading, spacing: 3) {
                TextField("English", text: $cue.en, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .lineSpacing(2)
                    .foregroundStyle(Theme.ink)
                    .onChange(of: cue.en) { _, _ in onEdit() }
                if !cue.zh.isEmpty {
                    Text(cue.zh).font(.system(size: 12)).foregroundStyle(Theme.ink2).textSelection(.enabled)
                }
                if edited, let original {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Circle().fill(Theme.accent).frame(width: 6, height: 6)
                        Text("Edited · was “\(original)”").lineLimit(2)
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.link)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(isCurrent ? Theme.accentSoft : (edited ? Theme.card : .clear), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            if edited { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.emphasis, lineWidth: 2) }
        }
    }
}
