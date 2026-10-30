import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: JobStore
    @State private var selection: UUID?
    @State private var showNew = false
    /// Job whose subtitles are open in the viewer, which then takes over the whole window.
    @State private var viewing: UUID?
    @State private var leaveRequested = false

    var body: some View {
        HStack(spacing: 0) {
            if viewing == nil {
                Sidebar(selection: $selection, onNew: { showNew = true })
                    .frame(width: 280)
                Theme.divider.frame(width: 1)
            }
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bg)
        .background(WindowAccessor { TrafficLights.shared.attach($0) })
        .foregroundStyle(Theme.ink)
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 880, minHeight: 560)
        .onChange(of: selection) { _, new in
            if let v = viewing, new != v { leaveRequested = true }
        }
        .onChange(of: store.jobs) { _, jobs in
            if let v = viewing, !jobs.contains(where: { $0.id == v }) { viewing = nil }
            if let s = selection, !jobs.contains(where: { $0.id == s }) { selection = jobs.first?.id }
        }
        .onAppear { if selection == nil { selection = store.jobs.first?.id } }
        .sheet(isPresented: $showNew) {
            NewJobSheet { job in
                store.add(job)
                selection = job.id
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let id = viewing {
            ViewerScreen(jobID: id, leaveRequested: $leaveRequested) { left in
                leaveRequested = false
                if left {
                    withAnimation(.easeOut(duration: 0.2)) { viewing = nil }
                } else {
                    selection = id  // stay: undo the click on another job
                }
            }
            .id(id)
        } else if let id = selection, let job = store.job(id) {
            JobDetailView(job: job) {
                withAnimation(.easeOut(duration: 0.2)) { viewing = id }
            }
            .id(id)
        } else {
            VStack(spacing: 14) {
                Image(systemName: "captions.bubble").font(.system(size: 36)).foregroundStyle(Theme.ink3)
                Text(store.jobs.isEmpty ? "No jobs yet" : "Select a job").font(.system(size: 17, weight: .semibold))
                if store.jobs.isEmpty {
                    Text("Add a YouTube link or a video file.").foregroundStyle(Theme.ink2)
                    Button { showNew = true } label: { Label("New Job", systemImage: "plus") }
                        .buttonStyle(.subgen(.primary, height: 32))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .windowDraggable()
        }
    }
}

/// Moves the close/minimise/zoom buttons down so they sit centred in the app's 52 pt header bars.
/// The title bar is hidden, so macOS would otherwise put them in its 28 pt strip at the top. AppKit
/// lays them out again on resize, full screen and appearance changes, so they are moved back
/// whenever the buttons or the title bar move.
@MainActor
final class TrafficLights {
    static let shared = TrafficLights()
    private static let header: CGFloat = 52
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

    func attach(_ window: NSWindow?) {
        guard let window, window !== self.window else { return }
        self.window = window
        observers.forEach(NotificationCenter.default.removeObserver)
        let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification,
                                          NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { self.place() }
            }
        }
        // Any other relayout, e.g. switching light/dark while another window is in front.
        if let close = window.standardWindowButton(.closeButton) {
            for view in [close, close.superview?.superview].compactMap({ $0 }) {
                view.postsFrameChangedNotifications = true
                observers.append(NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: view, queue: .main) { _ in
                    // After AppKit finishes its own layout pass.
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.place() } }
                })
            }
        }
        place()
    }

    private func place() {
        guard let window, !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let container = close.superview?.superview else { return }
        // The title bar's container clips the buttons, so it grows to the header's height first.
        // Frames are only set when they differ, so the frame-change observers don't loop.
        var frame = container.frame
        frame.size.height = Self.header
        frame.origin.y = window.frame.height - Self.header
        if container.frame != frame { container.frame = frame }
        if let bar = close.superview, bar.frame != container.bounds { bar.frame = container.bounds }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind) else { continue }
            let origin = NSPoint(x: button.frame.minX, y: (Self.header - button.frame.height) / 2)
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }
}

extension View {
    /// Lets the window be moved by dragging this view, for the title-bar-less header bars.
    func windowDraggable() -> some View { gesture(WindowDragGesture()) }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Binding var selection: UUID?
    var onNew: () -> Void
    @EnvironmentObject private var store: JobStore
    @AppStorage("model") private var model = "sonnet"
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Button(action: onNew) {
                    Image(systemName: "plus").font(.system(size: 15, weight: .semibold))
                }
                .buttonStyle(.subgen(.ghost, height: 30))
                .keyboardShortcut("n")
                .help("New job (⌘N)")
            }
            .padding(.horizontal, 12)
            .frame(height: 52)
            .contentShape(Rectangle())
            .windowDraggable()

            Text("JOBS")
                .font(.system(size: 11, weight: .semibold)).kerning(0.6)
                .foregroundStyle(Theme.ink3)
                .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(store.jobs) { job in
                        JobRow(job: job, progress: store.progress[job.id], selected: selection == job.id)
                            .onTapGesture { selection = job.id }
                            .contextMenu {
                                Button("Remove", role: .destructive) { store.remove(job.id) }
                            }
                    }
                }
                .padding(.horizontal, 10)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(.upArrow) { move(-1) }
            .onKeyPress(.downArrow) { move(1) }

            HStack(spacing: 10) {
                Image(systemName: "sparkle").font(.system(size: 14))
                (Text("Translating with ") + Text(model == "opus" ? "Opus" : "Sonnet")
                    .fontWeight(.semibold).foregroundColor(Theme.ink))
                Spacer()
                SettingsLink { Image(systemName: "gearshape").font(.system(size: 15)) }
                    .buttonStyle(.subgen(.ghost, height: 30))
                    .help("Settings")
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.ink2)
            .padding(.leading, 20).padding(.trailing, 14).padding(.vertical, 10)
            .overlay(alignment: .top) { Theme.divider.frame(height: 1) }
        }
        .background(Theme.sidebar)
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        let ids = store.jobs.map(\.id)
        guard !ids.isEmpty else { return .ignored }
        let i = selection.flatMap { ids.firstIndex(of: $0) } ?? (delta > 0 ? -1 : ids.count)
        selection = ids[min(max(i + delta, 0), ids.count - 1)]
        return .handled
    }
}

struct JobRow: View {
    let job: Job
    let progress: JobProgress?
    let selected: Bool
    @State private var hover = false

    private var active: Bool { job.status == .running || job.status == .paused }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusGlyph(status: job.status, onSelection: selected).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1).truncationMode(.tail)
                Text(meta)
                    .font(.system(size: 11.5))
                    .foregroundStyle(selected ? Theme.paperSub : Theme.ink2)
                    .lineLimit(1)
                if active, let p = progress {
                    Bar(value: p.overall(job.mode), height: 3,
                        track: selected ? Theme.paper.opacity(0.22) : Theme.divider)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? Theme.paper : Theme.ink)
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(selected ? Theme.ink : (hover ? Theme.ink.opacity(0.05) : .clear),
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    private var meta: String {
        var parts = [job.mode.short]
        if active, let p = progress {
            parts.append("\(Int(p.overall(job.mode) * 100))%")
            if job.status == .paused { parts.append("Paused") } else if let s = p.current { parts.append(stageLabel(s)) }
        } else {
            parts.append(job.status.label)
        }
        return parts.joined(separator: " · ")
    }
}
