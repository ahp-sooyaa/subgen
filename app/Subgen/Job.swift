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

    var displayName: String {
        if !name.isEmpty { return name }
        if source.hasPrefix("http") { return source }
        return URL(fileURLWithPath: source).deletingPathExtension().lastPathComponent
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
