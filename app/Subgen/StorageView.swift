import SwiftUI

/// Shows every file Subgen keeps on disk, largest first, and moves the chosen ones to the Trash.
struct StorageView: View {
    @EnvironmentObject private var store: JobStore
    @ObservedObject var model: StorageModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<URL> = []
    @State private var expanded: Set<String> = []
    @State private var confirming = false
    @State private var failures: [(URL, String)] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Theme.divider.frame(height: 1)
            if let report = model.report {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(StorageSection.allCases, id: \.self) { section in
                            let groups = report.groups(in: section)
                            if !groups.isEmpty { sectionView(section, groups) }
                        }
                    }
                    .padding(20)
                }
            } else {
                ProgressView("Measuring…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Theme.divider.frame(height: 1)
            footer
        }
        .frame(width: 780, height: 600)
        .background(Theme.bg)
        .foregroundStyle(Theme.ink)
        .onAppear { model.refresh(store) }
        .onChange(of: model.report?.groups.count) { _, _ in pruneSelection() }
        .alert("Move \(selectedItems.count) item\(selectedItems.count == 1 ? "" : "s") to the Trash?",
               isPresented: $confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) { trashSelected() }
        } message: {
            Text(confirmMessage)
        }
        .alert("Some items weren't moved",
               isPresented: Binding(get: { !failures.isEmpty }, set: { if !$0 { failures = [] } })) {
            Button("OK") { failures = [] }
        } message: {
            Text(failures.map { "\($0.0.lastPathComponent): \($0.1)" }.joined(separator: "\n"))
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Storage").font(.system(size: 17, weight: .semibold))
                if let r = model.report {
                    Text(formatBytes(r.total)).font(.system(size: 15).monospacedDigit()).foregroundStyle(Theme.ink2)
                }
                if model.scanning { ProgressView().controlSize(.small).padding(.leading, 4) }
                Spacer()
                Button { model.refresh(store) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(.subgen(.ghost))
                    .disabled(model.scanning)
                Button { NSWorkspace.shared.open(store.workRoot) } label: { Label("Show in Finder", systemImage: "folder") }
                    .buttonStyle(.subgen(.ghost))
            }
            if let r = model.report, r.total > 0 { usageBar(r) }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    private static let categoryColors: [String: Color] = [
        "Videos": Theme.accent, "Audio": Theme.green, "Caches": Theme.ink3,
        "Subtitles": Theme.link, "App data": Theme.strongBorder,
    ]

    private func usageBar(_ r: StorageReport) -> some View {
        let cats = r.byCategory.filter { $0.size > 0 }
        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    ForEach(cats, id: \.name) { c in
                        (Self.categoryColors[c.name] ?? Theme.ink3)
                            .frame(width: max(2, geo.size.width * CGFloat(c.size) / CGFloat(r.total)))
                    }
                }
            }
            .frame(height: 8)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            HStack(spacing: 16) {
                ForEach(cats, id: \.name) { c in
                    HStack(spacing: 6) {
                        Circle().fill(Self.categoryColors[c.name] ?? Theme.ink3).frame(width: 8, height: 8)
                        Text(c.name).foregroundStyle(Theme.ink2)
                        Text(formatBytes(c.size)).monospacedDigit()
                    }
                }
            }
            .font(.system(size: 12))
        }
    }

    // MARK: Sections

    private func sectionView(_ section: StorageSection, _ groups: [StorageGroup]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(section.title.uppercased())
                    .font(.system(size: 11, weight: .semibold)).kerning(0.6)
                Spacer()
                Text(formatBytes(groups.reduce(0) { $0 + $1.size })).font(.system(size: 11.5).monospacedDigit())
            }
            .foregroundStyle(Theme.ink3)
            .padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { i, g in
                    if i > 0 { Theme.rowLine.frame(height: 1) }
                    groupRow(g)
                    if expanded.contains(g.id) {
                        ForEach(g.items.sorted { $0.size > $1.size }) { item in
                            Theme.rowLine.frame(height: 1).padding(.leading, 64)
                            itemRow(item, in: g)
                        }
                    }
                }
            }
            .card(10)
        }
    }

    private func groupRow(_ g: StorageGroup) -> some View {
        let open = expanded.contains(g.id)
        let free = g.items.filter { !store.isLocked($0.url) }
        let chosen = free.filter { selected.contains($0.url) }.count
        let locked = free.isEmpty
        return HStack(spacing: 10) {
            CheckBox(state: chosen == 0 ? .off : (chosen == free.count ? .on : .mixed)) {
                let urls = free.map(\.url)
                if chosen == free.count { selected.subtract(urls) } else { selected.formUnion(urls) }
            }
            .disabled(locked)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.ink3)
                .rotationEffect(.degrees(open ? 90 : 0))
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(g.title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(g.subtitle).font(.system(size: 11.5))
                    .foregroundStyle(g.orphan ? Theme.accentText : Theme.ink3).lineLimit(1)
            }
            Spacer(minLength: 8)
            if locked { lockIcon }
            Text("\(g.items.count) item\(g.items.count == 1 ? "" : "s")")
                .font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
            Text(formatBytes(g.size)).font(.system(size: 13, weight: .medium).monospacedDigit())
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) {
                if open { expanded.remove(g.id) } else { expanded.insert(g.id) }
            }
        }
        .contextMenu {
            if let first = g.items.first {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(g.section == .work
                        ? [first.url.deletingLastPathComponent()] : g.items.map(\.url))
                }
            }
        }
    }

    private func itemRow(_ item: StorageItem, in g: StorageGroup) -> some View {
        let locked = store.isLocked(item.url)
        return HStack(spacing: 10) {
            CheckBox(state: selected.contains(item.url) ? .on : .off) {
                if selected.contains(item.url) { selected.remove(item.url) } else { selected.insert(item.url) }
            }
            .disabled(locked)
            Image(systemName: icon(item))
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink3)
                .frame(width: 16)
            Text(item.title).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
            Text(item.kind.label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.chipText)
                .padding(.horizontal, 6).padding(.vertical, 1.5)
                .background(Theme.chip, in: Capsule())
            if isSharedVideo(item, g) {
                Label("Shared by \(g.videoSharedBy.count) jobs", systemImage: "link")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.accentText)
                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                    .background(Theme.accentSoft, in: Capsule())
                    .help("Played by: " + g.videoSharedBy.joined(separator: ", "))
            }
            Spacer(minLength: 8)
            if locked { lockIcon }
            Text(formatBytes(item.size)).font(.system(size: 12.5).monospacedDigit()).foregroundStyle(Theme.ink2)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.leading, 36).padding(.trailing, 14).padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !locked else { return }
            if selected.contains(item.url) { selected.remove(item.url) } else { selected.insert(item.url) }
        }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        }
    }

    private func isSharedVideo(_ item: StorageItem, _ g: StorageGroup) -> Bool {
        !g.videoSharedBy.isEmpty && (item.kind == .video || item.kind == .hd)
    }

    private var lockIcon: some View {
        Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(Theme.ink3)
            .help("In use by the running job")
    }

    private func icon(_ item: StorageItem) -> String {
        switch item.kind {
        case .video, .hd: "film"
        case .audio: "waveform"
        case .subtitle: "captions.bubble"
        case .appData: "doc.text"
        case .cache: item.isDir ? "folder" : "doc"
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if selectedItems.isEmpty {
                Text("Select files to free up space. They go to the Trash.")
                    .foregroundStyle(Theme.ink3)
            } else {
                Text("\(selectedItems.count) selected · \(formatBytes(selectedSize))").fontWeight(.medium)
                Button("Clear") { selected = [] }.buttonStyle(LinkButtonStyle())
            }
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.subgen)
                .keyboardShortcut(.cancelAction)
            Button { confirming = true } label: { Label("Move to Trash…", systemImage: "trash") }
                .buttonStyle(.subgen(.primary))
                .disabled(selectedItems.isEmpty)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    // MARK: Selection

    private var allGroups: [StorageGroup] { model.report?.groups ?? [] }

    private var selectedItems: [(item: StorageItem, group: StorageGroup)] {
        allGroups.flatMap { g in g.items.filter { selected.contains($0.url) }.map { ($0, g) } }
    }

    private var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.item.size } }

    private var confirmMessage: String {
        var lines = ["This frees \(formatBytes(selectedSize)). You can restore the items from the Trash."]
        let owned = selectedItems.filter { !$0.group.jobIDs.isEmpty }
        let shared = Set(selectedItems.filter { isSharedVideo($0.item, $0.group) }.flatMap(\.group.videoSharedBy))
        if !shared.isEmpty {
            lines.append("A shared video is used by: \(shared.sorted().joined(separator: ", ")). None of them can be watched until one runs again.")
        } else if owned.contains(where: { [.video, .hd].contains($0.item.kind) }) {
            lines.append("Jobs whose video is removed can't be watched until you run them again, which downloads it again.")
        }
        if owned.contains(where: { $0.item.kind == .cache || $0.item.kind == .audio }) {
            lines.append("Running those jobs again redoes the removed steps.")
        }
        if owned.contains(where: { $0.item.kind == .appData && !$0.item.title.hasPrefix("Removed") }) {
            lines.append("Jobs whose progress is removed lose their subtitle links in the app until they run again.")
        }
        return lines.joined(separator: "\n\n")
    }

    private func trashSelected() {
        let urls = selectedItems.map(\.item.url)
        selected = []
        failures = model.trash(urls, store: store)
    }

    /// Drops selections of files that no longer exist.
    private func pruneSelection() {
        let present = Set(allGroups.flatMap { $0.items.map(\.url) })
        selected.formIntersection(present)
    }
}

/// A small three-state checkbox.
struct CheckBox: View {
    enum Mark { case off, on, mixed }
    let state: Mark
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: state == .on ? "checkmark.square.fill" : (state == .mixed ? "minus.square.fill" : "square"))
                .font(.system(size: 15))
                .foregroundStyle(state == .off ? Theme.ink3 : Theme.emphasis)
                .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
    }
}
