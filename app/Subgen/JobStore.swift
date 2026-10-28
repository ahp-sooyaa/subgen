import AppKit
import Foundation

/// Owns the job list, runs one `subgen` process at a time and follows its events file.
@MainActor
final class JobStore: ObservableObject {
    @Published private(set) var jobs: [Job] = []
    @Published private(set) var progress: [UUID: JobProgress] = [:]
    @Published private(set) var logs: [UUID: String] = [:]

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
    private func eventsURL(_ id: UUID) -> URL { jobDir(id).appendingPathComponent("events.jsonl") }
    private func logURL(_ id: UUID) -> URL { jobDir(id).appendingPathComponent("log.txt") }
    private var jobsURL: URL { supportDir.appendingPathComponent("jobs.json") }

    private func load() {
        guard let data = try? Data(contentsOf: jobsURL),
              var saved = try? JSONDecoder().decode([Job].self, from: data) else { return }
        // Nothing is running right after launch; interrupted jobs can be resumed.
        for i in saved.indices where saved[i].status == .running || saved[i].status == .paused {
            saved[i].status = .stopped
        }
        jobs = saved
    }

    private func save() {
        if let data = try? JSONEncoder().encode(jobs) { try? data.write(to: jobsURL, options: .atomic) }
    }

    func job(_ id: UUID) -> Job? { jobs.first { $0.id == id } }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
        save()
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
    func retranslate(_ id: UUID) {
        update(id) { $0.nextRunExtra = ["--redo", "translate"] }
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
