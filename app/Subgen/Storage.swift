import AppKit
import Foundation

/// What a file on disk is, for labels and the usage bar.
enum StorageKind: String, CaseIterable, Sendable {
    case video, hd, audio, cache, subtitle, appData

    var label: String {
        switch self {
        case .video: "Video"
        case .hd: "HD video"
        case .audio: "Audio"
        case .cache: "Cache"
        case .subtitle: "Subtitles"
        case .appData: "App data"
        }
    }

    /// Kinds that share a colour in the usage bar.
    var category: String {
        switch self {
        case .video, .hd: "Videos"
        case .audio: "Audio"
        case .cache: "Caches"
        case .subtitle: "Subtitles"
        case .appData: "App data"
        }
    }

    static func of(_ url: URL, isDir: Bool) -> StorageKind {
        let name = url.lastPathComponent.lowercased()
        if isDir { return .cache }
        if name.hasPrefix("video.1080") { return .hd }
        if ["mp4", "mkv", "webm", "mov", "m4v"].contains(url.pathExtension.lowercased()) { return .video }
        if ["wav", "m4a", "mp3", "flac", "opus"].contains(url.pathExtension.lowercased()) { return .audio }
        if name.hasSuffix(".srt") { return .subtitle }
        return .cache
    }
}

/// One deletable thing: a file, or a folder counted as one item.
struct StorageItem: Identifiable, Hashable, Sendable {
    var id: URL { url }
    let url: URL
    let title: String
    let size: Int64
    let kind: StorageKind
    let isDir: Bool
}

enum StorageSection: String, CaseIterable, Sendable {
    case work, subtitles, appData

    var title: String {
        switch self {
        case .work: "Videos & caches"
        case .subtitles: "Subtitles"
        case .appData: "App data"
        }
    }
}

/// A row that expands into its items: one work folder, the subtitles of one job, etc.
struct StorageGroup: Identifiable, Sendable {
    let id: String
    let section: StorageSection
    let title: String
    /// Where it lives, or "Not used by any job".
    let subtitle: String
    /// True when no job in the app refers to it.
    let orphan: Bool
    /// Jobs whose files these are, for warnings.
    let jobIDs: [UUID]
    let items: [StorageItem]
    /// Names of the jobs that play the video in this folder, when more than one does.
    var videoSharedBy: [String] = []
    var size: Int64 { items.reduce(0) { $0 + $1.size } }
}

struct StorageReport: Sendable {
    var groups: [StorageGroup] = []
    var total: Int64 { groups.reduce(0) { $0 + $1.size } }

    func groups(in section: StorageSection) -> [StorageGroup] {
        groups.filter { $0.section == section }.sorted { $0.size > $1.size }
    }

    /// Bytes per `StorageKind.category`, in a fixed order.
    var byCategory: [(name: String, size: Int64)] {
        var sums: [String: Int64] = [:]
        for g in groups { for i in g.items { sums[i.kind.category, default: 0] += i.size } }
        return ["Videos", "Audio", "Caches", "Subtitles", "App data"].map { ($0, sums[$0] ?? 0) }
    }
}

/// What the scanner needs to know about a job; copied off the main actor.
struct StorageJobInfo: Sendable {
    let id: UUID
    let name: String
    /// The job's cache folder, `work/<video id>` or `work/<video id>_<start>_<duration>` for a clip.
    let cacheDir: String?
    /// The folder its video was downloaded to, `work/<video id>`, shared by every job of that video.
    let videoDir: String?
    var folders: [String] { Array(Set([cacheDir, videoDir].compactMap { $0 })) }
    let outputs: [String]
}

enum StorageScanner {
    static func scan(workRoot: URL, outputDir: URL, jobsDir: URL, jobs: [StorageJobInfo]) -> StorageReport {
        var groups: [StorageGroup] = []

        // work/: one group per folder, plus loose files.
        var loose: [StorageItem] = []
        for url in children(workRoot) {
            if isDirectory(url) {
                let path = standard(url.path)
                let cacheOwners = jobs.filter { $0.cacheDir.map(standard) == path }
                let videoUsers = jobs.filter { $0.videoDir.map(standard) == path }
                let owners = cacheOwners + videoUsers.filter { v in !cacheOwners.contains { $0.id == v.id } }
                let items = children(url).map { item($0, kind: nil) }
                guard !items.isEmpty else { continue }
                var notes = ["work/\(url.lastPathComponent)"]
                if owners.isEmpty { notes.insert("Not used by any job", at: 0) }
                let hasVideo = items.contains { $0.kind == .video || $0.kind == .hd }
                if hasVideo && videoUsers.count > 1 { notes.append("video shared by \(videoUsers.count) jobs") }
                // A clip keeps its own caches here but plays the full video from another folder.
                let videoDirs = Set(cacheOwners.compactMap { $0.videoDir.map(standard) }).subtracting([path])
                for d in videoDirs.sorted() {
                    notes.append("video in work/\(URL(fileURLWithPath: d).lastPathComponent) (shared)")
                }
                groups.append(StorageGroup(
                    id: "work:" + url.path, section: .work,
                    title: owners.isEmpty ? url.lastPathComponent : names(cacheOwners.isEmpty ? videoUsers : cacheOwners),
                    subtitle: notes.joined(separator: " · "),
                    orphan: owners.isEmpty, jobIDs: owners.map(\.id), items: items,
                    videoSharedBy: videoUsers.count > 1 ? unique(videoUsers.map(\.name)) : []))
            } else {
                loose.append(item(url, kind: nil))
            }
        }
        if !loose.isEmpty {
            groups.append(StorageGroup(id: "work:loose", section: .work, title: "Other files in work/",
                                       subtitle: "Not used by any job", orphan: true, jobIDs: [], items: loose))
        }

        // out/: subtitles grouped by the job that wrote them.
        var owner: [String: StorageJobInfo] = [:]
        for j in jobs { for o in j.outputs { owner[standard(o)] = j } }
        var subsByJob: [UUID: [StorageItem]] = [:]
        var otherSubs: [StorageItem] = []
        for url in children(outputDir) where !isDirectory(url) {
            let it = item(url, kind: .subtitle)
            if let j = owner[standard(url.path)] { subsByJob[j.id, default: []].append(it) } else { otherSubs.append(it) }
        }
        for j in jobs {
            guard let items = subsByJob[j.id] else { continue }
            groups.append(StorageGroup(id: "subs:" + j.id.uuidString, section: .subtitles, title: j.name,
                                       subtitle: outputDir.lastPathComponent + "/", orphan: false,
                                       jobIDs: [j.id], items: items))
        }
        if !otherSubs.isEmpty {
            groups.append(StorageGroup(id: "subs:other", section: .subtitles, title: "Other subtitles",
                                       subtitle: "Not written by any job in the app", orphan: true,
                                       jobIDs: [], items: otherSubs))
        }

        // App data: each job's events and log.
        let jobByID = Dictionary(jobs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var appItems: [StorageItem] = []
        var appJobs: [UUID] = []
        for url in children(jobsDir) where isDirectory(url) {
            let id = UUID(uuidString: url.lastPathComponent)
            let j = id.flatMap { jobByID[$0] }
            if let id, j != nil { appJobs.append(id) }
            appItems.append(StorageItem(url: url, title: j.map { "\($0.name) — events & log" } ?? "Removed job",
                                        size: size(of: url), kind: .appData, isDir: true))
        }
        if !appItems.isEmpty {
            groups.append(StorageGroup(id: "app", section: .appData, title: "Job progress & logs",
                                       subtitle: "~/Library/Application Support/Subgen/jobs", orphan: false,
                                       jobIDs: appJobs, items: appItems))
        }
        return StorageReport(groups: groups)
    }

    private static func item(_ url: URL, kind: StorageKind?) -> StorageItem {
        let dir = isDirectory(url)
        return StorageItem(url: url, title: url.lastPathComponent + (dir ? "/" : ""), size: size(of: url),
                           kind: kind ?? StorageKind.of(url, isDir: dir), isDir: dir)
    }

    private static func names(_ jobs: [StorageJobInfo]) -> String {
        let names = unique(jobs.map(\.name))
        return names.count <= 2 ? names.joined(separator: ", ") : "\(names[0]) + \(names.count - 1) more"
    }

    private static func unique(_ names: [String]) -> [String] {
        Array(NSOrderedSet(array: names)) as? [String] ?? names
    }

    static func standard(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func children(_ dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsHiddenFiles])) ?? []
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        func fileSize(_ u: URL) -> Int64 {
            guard let v = try? u.resourceValues(forKeys: keys), v.isRegularFile == true else { return 0 }
            return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        guard isDirectory(url) else { return fileSize(url) }
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [])
        while let u = e?.nextObject() as? URL { total += fileSize(u) }
        return total
    }
}

/// The latest scan, shared by the sidebar total and the Storage sheet.
@MainActor
final class StorageModel: ObservableObject {
    @Published private(set) var report: StorageReport?
    @Published private(set) var scanning = false
    private var pending = false

    func refresh(_ store: JobStore) {
        guard !scanning else { pending = true; return }
        scanning = true
        let jobs = store.storageJobInfo()
        let work = store.workRoot
        let out = URL(fileURLWithPath: AppSettings.outputDir, isDirectory: true)
        let jobsDir = store.supportDir.appendingPathComponent("jobs", isDirectory: true)
        Task.detached(priority: .utility) {
            let r = StorageScanner.scan(workRoot: work, outputDir: out, jobsDir: jobsDir, jobs: jobs)
            await MainActor.run {
                self.report = r
                self.scanning = false
                if self.pending {
                    self.pending = false
                    self.refresh(store)
                }
            }
        }
    }

    /// Moves the files to the Trash, skipping any the running job uses. Returns the ones that failed.
    func trash(_ urls: [URL], store: JobStore) -> [(URL, String)] {
        var failed: [(URL, String)] = []
        for url in urls {
            if store.isLocked(url) {
                failed.append((url, "In use by the running job"))
                continue
            }
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch {
                failed.append((url, error.localizedDescription))
            }
        }
        store.objectWillChange.send()  // job views re-check which files are still there
        refresh(store)
        return failed
    }
}

func formatBytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}
