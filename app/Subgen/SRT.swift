import Foundation

struct Cue: Identifiable, Equatable {
    let id: Int
    var start: Double
    var end: Double
    var en: String
    var zh: String
}

enum SRT {
    /// Parse an .srt into (start, end, text) blocks.
    static func parse(_ text: String) -> [(Double, Double, String)] {
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        return blocks.compactMap { block in
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let ti = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let parts = lines[ti].components(separatedBy: "-->")
            guard parts.count == 2, let a = time(parts[0]), let b = time(parts[1]) else { return nil }
            let body = lines[(ti + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return (a, b, body)
        }
    }

    static func time(_ s: String) -> Double? {
        let p = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard p.count == 3, let h = Double(p[0]), let m = Double(p[1]), let sec = Double(p[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }

    static func stamp(_ t: Double) -> String {
        let ms = Int((t * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    /// Cues from the bilingual file (first line English, the rest Chinese) when present,
    /// otherwise English only.
    static func load(en enPath: String, both bothPath: String?) -> [Cue] {
        if let both = bothPath, let text = try? String(contentsOfFile: both, encoding: .utf8) {
            return parse(text).enumerated().map { i, b in
                let lines = b.2.components(separatedBy: "\n")
                return Cue(id: i, start: b.0, end: b.1, en: lines.first ?? "",
                           zh: lines.dropFirst().joined(separator: "\n"))
            }
        }
        let text = (try? String(contentsOfFile: enPath, encoding: .utf8)) ?? ""
        return parse(text).enumerated().map { i, b in Cue(id: i, start: b.0, end: b.1, en: b.2, zh: "") }
    }

    static func write(_ cues: [Cue], to path: String, body: (Cue) -> String) throws {
        var out = ""
        var n = 0
        for c in cues {
            let text = body(c).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            n += 1
            out += "\(n)\n\(stamp(c.start)) --> \(stamp(c.end))\n\(text)\n\n"
        }
        try out.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
