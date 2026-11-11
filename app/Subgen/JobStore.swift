import AppKit
import Foundation

/// Owns the job list, runs one `subgen` process at a time and follows its events file.
@MainActor
final class JobStore: ObservableObject {
    @Published private(set) var jobs: [Job] = []
    @Published private(set) var progress: [UUID: JobProgress] = [:]
    @Published private(set) var logs: [UUID: String] = [:]
    @Published private(set) var playlists: [Playlist] = []

    private var process: Process?
    private var runningID: UUID?
    private var stopRequested = false
    private var offsets: [UUID: UInt64] = [:]
    private var timer: Timer?

    let supportDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Subgen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() {
        load()
        for job in jobs { reloadProgress(job.id) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        startNextIfIdle()
    }

    // MARK: - Files

    func jobDir(_ id: UUID) -> URL {
        let d = supportDir.appendingPathComponent("jobs/\(id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    /// Where the pipeline keeps downloaded videos and caches, one folder per video.
    var workRoot: URL { URL(fileURLWithPath: AppSettings.repoPath).appendingPathComponent("work", isDirectory: true) }

    /// Work folders a job uses: its cache folder, and the folder its video was downloaded to
    /// (different for clips, which share the full video's download).
    func workFolders(_ id: UUID) -> [String] {
        guard let p = progress[id] else { return [] }
        let parents = [p.videoPath, p.hdVideoPath].compactMap { $0 }
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
        return Array(Set(([p.workDir].compactMap { $0 } + parents).map(StorageScanner.standard)))
    }

    func storageJobInfo() -> [StorageJobInfo] {
        jobs.map { j in
            let p = progress[j.id]
            return StorageJobInfo(id: j.id, name: j.displayName(p), cacheDir: p?.workDir,
                                  videoDir: p?.videoPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path },
                                  outputs: progress[j.id].map { Array($0.outputs.values) } ?? [])
        }
    }

    /// True when `url` is, holds, or sits inside a folder the running (or paused) job writes to.
    func isLocked(_ url: URL) -> Bool {
        let path = StorageScanner.standard(url.path)
        let busy = jobs.filter { $0.status == .running || $0.status == .paused }.map(\.id)
        let folders = busy.flatMap { workFolders($0) + [StorageScanner.standard(jobDir($0).path)] }
        return folders.contains { f in path == f || path.hasPrefix(f + "/") || f.hasPrefix(path + "/") }
    }

    private func eventsURL(_ id: UUID) -> URL { jobDir(id).appendingPathComponent("events.jsonl") }
    private func logURL(_ id: UUID) -> URL { jobDir(id).appendingPathComponent("log.txt") }
    private var jobsURL: URL { supportDir.appendingPathComponent("jobs.json") }
    private var playlistsURL: URL { supportDir.appendingPathComponent("playlists.json") }

    private func load() {
        guard let data = try? Data(contentsOf: jobsURL),
              var saved = try? JSONDecoder().decode([Job].self, from: data) else { return }
        // Nothing is running right after launch; interrupted jobs can be resumed.
        for i in saved.indices where saved[i].status == .running || saved[i].status == .paused {
            saved[i].status = .stopped
        }
        jobs = saved
        if let data = try? Data(contentsOf: playlistsURL),
           let lists = try? JSONDecoder().decode([Playlist].self, from: data) {
            playlists = lists
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(jobs) { try? data.write(to: jobsURL, options: .atomic) }
    }

    private func savePlaylists() {
        if let data = try? JSONEncoder().encode(playlists) { try? data.write(to: playlistsURL, options: .atomic) }
    }

    func job(_ id: UUID) -> Job? { jobs.first { $0.id == id } }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
        save()
    }

    // MARK: - Playlists

    func playlist(_ id: UUID?) -> Playlist? { id.flatMap { id in playlists.first { $0.id == id } } }

    @discardableResult
    func createPlaylist(_ name: String) -> UUID {
        let list = Playlist(name: name)
        playlists.append(list)
        savePlaylists()
        return list.id
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[i].name = name
        savePlaylists()
    }

    /// Removes the playlist; its jobs stay, outside any playlist.
    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        for i in jobs.indices where jobs[i].playlist == id { jobs[i].playlist = nil }
        savePlaylists()
        save()
    }

    func setPlaylist(_ jobID: UUID, _ playlistID: UUID?) {
        update(jobID) { $0.playlist = playlistID }
    }

    // MARK: - Actions

    func add(_ job: Job) {
        jobs.insert(job, at: 0)
        save()
        startNextIfIdle()
    }

    func remove(_ id: UUID) {
        if runningID == id { stop(id) }
        jobs.removeAll { $0.id == id }
        progress[id] = nil
        logs[id] = nil
        try? FileManager.default.removeItem(at: jobDir(id))
        save()
    }

    func pause(_ id: UUID) {
        guard runningID == id, let p = process else { return }
        kill(-p.processIdentifier, SIGSTOP)
        update(id) { $0.status = .paused }
    }

    func resume(_ id: UUID) {
        if runningID == id, let p = process {
            kill(-p.processIdentifier, SIGCONT)
            update(id) { $0.status = .running }
        } else {  // stopped, failed or done: run again; finished stages come from the cache
            update(id) { $0.status = .queued }
            startNextIfIdle()
        }
    }

    func stop(_ id: UUID) {
        guard runningID == id, let p = process else {
            if job(id)?.status == .queued { update(id) { $0.status = .stopped } }
            return
        }
        stopRequested = true
        kill(-p.processIdentifier, SIGCONT)  // a stopped process can't handle SIGTERM
        kill(-p.processIdentifier, SIGTERM)
    }

    /// Re-run only the translation (e.g. after editing the glossary).
    func retranslate(_ id: UUID) { redo(id, from: "translate") }

    /// Run again, ignoring cached results from `stage` on ("region", "ocr", "asr" or "translate").
    func redo(_ id: UUID, from stage: String) {
        update(id) { $0.nextRunExtra = ["--redo", stage] }
        if runningID != id { resume(id) }
    }

    func stopAllForQuit() {
        if let p = process {
            kill(-p.processIdentifier, SIGCONT)
            kill(-p.processIdentifier, SIGTERM)
        }
    }

    // MARK: - Running

    private func startNextIfIdle() {
        guard runningID == nil,
              let next = jobs.filter({ $0.status == .queued }).min(by: { $0.created < $1.created }) else { return }
        launch(next)
    }

    private func arguments(_ job: Job) -> [String] {
        var args = [job.source, "-o", AppSettings.outputDir, "--model", AppSettings.model,
                    "--events", eventsURL(job.id).path]
        if !job.name.isEmpty { args += ["--name", job.name] }
        if let s = job.start { args += ["--start", String(s)] }
        if let d = job.duration { args += ["--duration", String(d)] }
        if job.bilingual { args.append("--bilingual") }
        if job.mode != .ocr { args += ["--asr", job.mode.rawValue] }
        if job.whisperHints && job.mode != .ocr { args.append("--whisper-hints") }
        if let g = job.glossaryPath, !g.isEmpty { args += ["--glossary", g] }
        if !AppSettings.hdCopy { args.append("--no-hd") }
        return args + job.nextRunExtra
    }

    private func launch(_ job: Job) {
        let repo = URL(fileURLWithPath: AppSettings.repoPath)
        let exe = repo.appendingPathComponent(".venv/bin/subgen")
        let id = job.id
        appendEvent(id, ["type": "run"])
        FileManager.default.createFile(atPath: logURL(id).path, contents: nil)
        let log = try? FileHandle(forWritingTo: logURL(id))

        let p = Process()
        p.executableURL = exe
        p.arguments = arguments(job)
        p.currentDirectoryURL = repo
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        // Apps started from Finder get a bare PATH; ffmpeg and claude live elsewhere.
        env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", env["PATH"] ?? "/usr/bin:/bin"]
            .joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env
        p.standardOutput = log
        p.standardError = log
        p.terminationHandler = { proc in
            let code = proc.terminationStatus
            Task { @MainActor in self.finished(id, code: code, log: log) }
        }
        do {
            try p.run()
        } catch {
            appendEvent(id, ["type": "error", "message": "Could not start \(exe.path): \(error.localizedDescription)"])
            update(id) { $0.status = .failed }
            reloadProgress(id)
            return
        }
        process = p
        runningID = id
        stopRequested = false
        update(id) {
            $0.status = .running
            $0.nextRunExtra = []
        }
    }

    private func finished(_ id: UUID, code: Int32, log: FileHandle?) {
        try? log?.close()
        poll()
        let ok = code == 0 && (progress[id]?.finished ?? false)
        update(id) { $0.status = ok ? .done : (stopRequested ? .stopped : .failed) }
        process = nil
        runningID = nil
        stopRequested = false
        startNextIfIdle()
    }

    private func appendEvent(_ id: UUID, _ event: [String: Any]) {
        var e = event
        e["ts"] = Date().timeIntervalSince1970
        guard let data = try? JSONSerialization.data(withJSONObject: e),
              let line = String(data: data, encoding: .utf8) else { return }
        let url = eventsURL(id)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write((line + "\n").data(using: .utf8)!)
            try? h.close()
        }
    }

    // MARK: - Following events and logs

    private func reloadProgress(_ id: UUID) {
        progress[id] = JobProgress()
        offsets[id] = 0
        readEvents(id)
        readLog(id)
    }

    private func poll() {
        guard let id = runningID else { return }
        readEvents(id)
        readLog(id)
    }

    private func readEvents(_ id: UUID) {
        guard let h = try? FileHandle(forReadingFrom: eventsURL(id)) else { return }
        defer { try? h.close() }
        let start = offsets[id] ?? 0
        h.seek(toFileOffset: start)
        let data = h.readDataToEndOfFile()
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let complete = data[data.startIndex...lastNewline]  // a half-written last line waits for the next poll
        offsets[id] = start + UInt64(complete.count)
        var p = progress[id] ?? JobProgress()
        for line in complete.split(separator: UInt8(ascii: "\n")) {
            if let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] { p.apply(obj) }
        }
        progress[id] = p
    }

    private func readLog(_ id: UUID) {
        guard let data = try? Data(contentsOf: logURL(id)) else { return }
        let text = String(decoding: data.suffix(60_000), as: UTF8.self)
        // \r status lines: keep only the latest state of each.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: "\r").last.map(String.init) ?? "" }
        logs[id] = lines.suffix(400).joined(separator: "\n")
    }
}
