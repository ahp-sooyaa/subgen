import Foundation

enum JobMode: String, Codable, CaseIterable, Identifiable {
    case ocr, merge, whisper

    var id: String { rawValue }
    var label: String {
        switch self {
        case .ocr: "Burned-in captions (OCR)"
        case .merge: "Speech (Whisper + SenseVoice)"
        case .whisper: "Speech (Whisper only)"
        }
    }
    var short: String {
        switch self {
        case .ocr: "OCR"
        case .merge: "Speech"
        case .whisper: "Whisper"
        }
    }
    /// Stages the pipeline reports for this mode, in order (see subgen/cli.py).
    var stages: [String] {
        switch self {
        case .ocr: ["download", "region", "ocr", "translate"]
        case .merge: ["download", "audio", "whisper", "sensevoice", "glossary", "translate"]
        case .whisper: ["download", "audio", "whisper", "glossary", "translate"]
        }
    }
}

func stageLabel(_ stage: String) -> String {
    [
        "download": "Download video", "region": "Find caption area", "ocr": "Read captions (OCR)",
        "audio": "Extract audio", "whisper": "Whisper", "sensevoice": "SenseVoice",
        "glossary": "Build name glossary", "translate": "Correct & translate",
        "hd": "HD copy (1080p)",
    ][stage] ?? stage
}

enum JobStatus: String, Codable {
    case queued, running, paused, stopped, done, failed

    var label: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .queued: "clock"
        case .running: "play.circle"
        case .paused: "pause.circle"
        case .stopped: "stop.circle"
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

/// What the user asked for. Saved in jobs.json.
struct Job: Codable, Identifiable, Equatable {
    var id = UUID()
    var source: String
    var mode: JobMode
    var name: String = ""
    var start: Double? = nil
    var duration: Double? = nil
    var bilingual = true
    var whisperHints = false
    var glossaryPath: String? = nil
    var created = Date()
    var status: JobStatus = .queued
    /// Extra arguments for the next run only (e.g. --redo translate).
    var nextRunExtra: [String] = []
    /// The playlist this job is in, if any. Optional so older jobs.json files still load.
    var playlist: UUID? = nil

    var displayName: String {
        if !name.isEmpty { return name }
        if source.hasPrefix("http") { return source }
        return URL(fileURLWithPath: source).deletingPathExtension().lastPathComponent
    }

    /// The name to show: the user's name, else the video title the pipeline found, else the source.
    func displayName(_ progress: JobProgress?) -> String {
        if name.isEmpty, let t = progress?.title, !t.isEmpty { return t }
        return displayName
    }
}

/// A named collection of jobs, e.g. one season of a show. Saved in playlists.json.
struct Playlist: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var created = Date()
}

extension Array where Element == Playlist {
    /// By name, with numbers compared as numbers (Season 9 before Season 10).
    var byName: [Playlist] { sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
}

// MARK: - Sidebar grouping

enum JobGrouping: String, CaseIterable, Identifiable {
    case none, status, mode, date, playlist

    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: "None"
        case .status: "Status"
        case .mode: "Mode"
        case .date: "Date"
        case .playlist: "Playlist"
        }
    }
}

struct JobGroup: Identifiable {
    static let noPlaylist = "none"
    let id: String
    let title: String
    var jobs: [Job]
}

/// Splits jobs into sidebar sections in a fixed order, keeping the list's order inside each one.
/// Empty sections are left out, except playlists, so a new one shows up; `.none` gives one
/// untitled section.
func grouped(_ jobs: [Job], by grouping: JobGrouping, playlists: [Playlist] = [],
             now: Date = .now) -> [JobGroup] {
    let order: [(id: String, title: String)]
    let key: (Job) -> String
    switch grouping {
    case .none:
        return [JobGroup(id: "all", title: "", jobs: jobs)]
    case .playlist:
        let known = Set(playlists.map(\.id))
        let buckets = Dictionary(grouping: jobs) { $0.playlist.flatMap { known.contains($0) ? $0 : nil } }
        var groups = playlists.byName.map {
            JobGroup(id: $0.id.uuidString, title: $0.name, jobs: buckets[$0.id] ?? [])
        }
        if let loose = buckets[nil], !loose.isEmpty {
            groups.append(JobGroup(id: JobGroup.noPlaylist, title: "No playlist", jobs: loose))
        }
        return groups
    case .status:
        order = [("active", "In progress"), ("queued", "Queued"), ("done", "Done"), ("ended", "Failed & stopped")]
        key = {
            switch $0.status {
            case .running, .paused: "active"
            case .queued: "queued"
            case .done: "done"
            case .failed, .stopped: "ended"
            }
        }
    case .mode:
        order = JobMode.allCases.map { ($0.rawValue, $0.short) }
        key = { $0.mode.rawValue }
    case .date:
        order = [("today", "Today"), ("yesterday", "Yesterday"), ("week", "This week"),
                 ("month", "This month"), ("earlier", "Earlier")]
        let cal = Calendar.current
        key = { job in
            let d = job.created
            if cal.isDateInToday(d) { return "today" }
            if cal.isDateInYesterday(d) { return "yesterday" }
            if cal.isDate(d, equalTo: now, toGranularity: .weekOfYear) { return "week" }
            if cal.isDate(d, equalTo: now, toGranularity: .month) { return "month" }
            return "earlier"
        }
    }
    let buckets = Dictionary(grouping: jobs, by: key)
    return order.compactMap { g in
        guard let js = buckets[g.id], !js.isEmpty else { return nil }
        return JobGroup(id: g.id, title: g.title, jobs: js)
    }
}

/// What the pipeline has reported, rebuilt from the job's events.jsonl.
struct JobProgress {
    struct Stage {
        var done = false
        var running = false
        var frac: Double? = nil
        var eta: Double? = nil
        var text = ""
        var seconds: Double? = nil
        /// An optional stage that produced nothing (e.g. no 1080p on YouTube); `reason` says why.
        var skipped = false
        var reason: String? = nil
    }

    var stages: [String: Stage] = [:]
    var current: String? = nil
    var outputs: [String: String] = [:]  // kind (zh, fixed, en, en-zh) -> path
    var glossaryPath: String? = nil
    var glossaryAuto = false
    var videoPath: String? = nil
    /// The 1080p copy for watching, when the pipeline made one.
    var hdVideoPath: String? = nil
    var workDir: String? = nil
    var title: String? = nil
    var error: String? = nil
    var warnings: [String] = []
    var finished = false

    mutating func apply(_ e: [String: Any]) {
        switch e["type"] as? String {
        case "run":  // the app starts a new run of the same job
            stages = [:]; current = nil; error = nil; warnings = []; finished = false
        case "job":
            videoPath = e["video"] as? String
            workDir = e["work"] as? String
            title = e["title"] as? String
        case "stage":
            guard let s = e["stage"] as? String else { return }
            switch e["status"] as? String {
            case "start":
                stages[s] = Stage(running: true)
                if s != "hd" { current = s }  // the HD copy downloads alongside the other stages
            case "skipped":
                stages[s] = Stage(done: true, skipped: true, reason: e["reason"] as? String)
            default:
                stages[s, default: Stage()].running = false
                stages[s, default: Stage()].done = true
                stages[s, default: Stage()].frac = 1
                stages[s, default: Stage()].eta = nil
                stages[s, default: Stage()].seconds = e["seconds"] as? Double
            }
        case "hd":
            hdVideoPath = e["path"] as? String
        case "progress":
            guard let s = e["stage"] as? String else { return }
            stages[s, default: Stage()].frac = e["frac"] as? Double
            stages[s, default: Stage()].eta = e["eta"] as? Double
            stages[s, default: Stage()].text = e["text"] as? String ?? ""
            if s == "download" { stages[s, default: Stage()].running = true; current = s }
        case "glossary":
            glossaryPath = e["path"] as? String
            glossaryAuto = e["auto"] as? Bool ?? false
        case "output":
            if let k = e["kind"] as? String, let p = e["path"] as? String { outputs[k] = p }
        case "warning":
            if let m = e["message"] as? String { warnings.append(m) }
        case "error":
            error = e["message"] as? String
        case "finished":
            finished = true
        default:
            break
        }
    }

    /// Overall fraction, counting each expected stage equally.
    func overall(_ mode: JobMode) -> Double {
        let names = mode.stages
        let sum = names.reduce(0.0) { acc, n in
            let s = stages[n]
            return acc + (s?.done == true ? 1 : (s?.frac ?? 0))
        }
        return sum / Double(names.count)
    }
}

func formatDuration(_ s: Double) -> String {
    let t = Int(s.rounded())
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                     : String(format: "%d:%02d", t / 60, t % 60)
}

/// "1:30" / "90" / "1:02:03" -> seconds.
func parseTime(_ s: String) -> Double? {
    let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Double($0) }
    guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
    return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
}
