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
            .environmentObject(store)
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
    @AppStorage("jobGrouping") private var grouping: JobGrouping = .status
    @AppStorage("collapsedGroups") private var collapsedRaw = ""
    @FocusState private var focused: Bool
    @State private var prompt: PlaylistPrompt?
    @State private var promptName = ""
    @State private var deleting: Playlist?

    /// What the playlist name alert is for.
    enum PlaylistPrompt {
        case create(addJob: UUID?)
        case rename(UUID)
    }

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

            HStack(spacing: 6) {
                Text("JOBS")
                    .font(.system(size: 11, weight: .semibold)).kerning(0.6)
                Spacer()
                Menu {
                    Picker("Group by", selection: $grouping) {
                        ForEach(JobGrouping.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Button("New Playlist…") { askNewPlaylist(addJob: nil) }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 12, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Group jobs by…")
            }
            .foregroundStyle(Theme.ink3)
            .padding(.leading, 20).padding(.trailing, 18).padding(.top, 6).padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(groups) { group in
                        if !group.title.isEmpty {
                            header(group)
                        }
                        if !isCollapsed(group.id) {
                            ForEach(group.jobs) { job in
                                JobRow(job: job, progress: store.progress[job.id], selected: selection == job.id)
                                    .onTapGesture { selection = job.id }
                                    .draggable(job.id.uuidString)
                                    .contextMenu { rowMenu(job) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(.upArrow) { move(-1) }
            .onKeyPress(.downArrow) { move(1) }
            .onChange(of: selection) { _, _ in revealSelection() }
            .onChange(of: grouping) { _, _ in revealSelection() }
            .onChange(of: store.jobs) { _, _ in revealSelection() }

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
        .alert(promptTitle, isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
            TextField("Name", text: $promptName)
            Button("Cancel", role: .cancel) {}
            Button(promptAction) { commitPrompt() }
                .disabled(trimmedName.isEmpty)
        }
        .alert("Delete “\(deleting?.name ?? "")”?",
               isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Playlist", role: .destructive) {
                if let id = deleting?.id { store.deletePlaylist(id) }
            }
        } message: {
            Text("Its videos stay in your jobs, outside any playlist.")
        }
    }

    private var groups: [JobGroup] { grouped(store.jobs, by: grouping, playlists: store.playlists) }

    // MARK: Playlists

    @ViewBuilder private func header(_ group: JobGroup) -> some View {
        let isPlaylists = grouping == .playlist
        let list = isPlaylists ? UUID(uuidString: group.id).flatMap { store.playlist($0) } : nil
        GroupHeader(title: group.title, count: group.jobs.count, collapsed: isCollapsed(group.id),
                    onToggle: { toggle(group.id) },
                    onDrop: isPlaylists ? { jobID in store.setPlaylist(jobID, list?.id) } : nil)
            .contextMenu {
                if let list {
                    Button("Rename…") {
                        promptName = list.name
                        prompt = .rename(list.id)
                    }
                    Button("Delete Playlist…", role: .destructive) { deleting = list }
                }
            }
    }

    @ViewBuilder private func rowMenu(_ job: Job) -> some View {
        Menu("Playlist") {
            ForEach(store.playlists.byName) { list in
                Toggle(list.name, isOn: Binding(
                    get: { job.playlist == list.id },
                    set: { store.setPlaylist(job.id, $0 ? list.id : nil) }))
            }
            if !store.playlists.isEmpty {
                Button("None") { store.setPlaylist(job.id, nil) }
                    .disabled(store.playlist(job.playlist) == nil)
                Divider()
            }
            Button("New Playlist…") { askNewPlaylist(addJob: job.id) }
        }
        Divider()
        Button("Remove", role: .destructive) { store.remove(job.id) }
    }

    private func askNewPlaylist(addJob: UUID?) {
        promptName = ""
        prompt = .create(addJob: addJob)
    }

    private var trimmedName: String { promptName.trimmingCharacters(in: .whitespaces) }

    private var promptTitle: String {
        if case .rename = prompt { return "Rename Playlist" }
        return "New Playlist"
    }

    private var promptAction: String {
        if case .rename = prompt { return "Rename" }
        return "Create"
    }

    private func commitPrompt() {
        let name = trimmedName
        guard !name.isEmpty, let p = prompt else { return }
        switch p {
        case .create(let jobID):
            let id = store.createPlaylist(name)
            if let jobID { store.setPlaylist(jobID, id) }
            grouping = .playlist  // so the new playlist is visible
        case .rename(let id):
            store.renamePlaylist(id, to: name)
        }
        prompt = nil
    }

    // MARK: Sections

    /// Collapsed sections, saved per grouping as "grouping:section".
    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: ",").map(String.init)) }
    private func key(_ groupID: String) -> String { "\(grouping.rawValue):\(groupID)" }
    private func isCollapsed(_ groupID: String) -> Bool { collapsed.contains(key(groupID)) }

    private func setCollapsed(_ groupID: String, _ value: Bool) {
        var set = collapsed
        if value { set.insert(key(groupID)) } else { set.remove(key(groupID)) }
        collapsedRaw = set.sorted().joined(separator: ",")
    }

    private func toggle(_ groupID: String) {
        withAnimation(.easeOut(duration: 0.15)) { setCollapsed(groupID, !isCollapsed(groupID)) }
    }

    /// Opens the section holding the selected job, e.g. a job just added to a collapsed section.
    private func revealSelection() {
        guard let id = selection,
              let group = groups.first(where: { $0.jobs.contains { $0.id == id } }),
              isCollapsed(group.id) else { return }
        setCollapsed(group.id, false)
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        let ids = groups.filter { !isCollapsed($0.id) }.flatMap { $0.jobs.map(\.id) }
        guard !ids.isEmpty else { return .ignored }
        let i = selection.flatMap { ids.firstIndex(of: $0) } ?? (delta > 0 ? -1 : ids.count)
        selection = ids[min(max(i + delta, 0), ids.count - 1)]
        return .handled
    }
}

/// A collapsible section title in the job list.
struct GroupHeader: View {
    let title: String
    let count: Int
    let collapsed: Bool
    var onToggle: () -> Void
    /// Set when jobs can be dropped here to move them into this section (playlists).
    var onDrop: ((UUID) -> Void)? = nil
    @State private var hover = false
    @State private var targeted = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 10)
                Text(title).font(.system(size: 11.5, weight: .semibold))
                Spacer(minLength: 0)
                Text("\(count)").font(.system(size: 11).monospacedDigit())
            }
            .foregroundStyle(hover ? Theme.ink2 : Theme.ink3)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(targeted ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                if targeted { RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent, lineWidth: 1) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 5)
        .onHover { hover = $0 }
        .dropDestination(for: String.self) { items, _ in
            guard let onDrop else { return false }
            let ids = items.compactMap(UUID.init(uuidString:))
            ids.forEach(onDrop)
            return !ids.isEmpty
        } isTargeted: { targeted = $0 && onDrop != nil }
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
                Text(job.displayName(progress))
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
