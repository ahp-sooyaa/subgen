import SwiftUI

/// The pipeline's region.json: the caption bands OCR reads, and which stretches of the video use each.
struct RegionInfo: Decodable {
    struct Review: Decodable {
        var ok = true
        var fixed = false
        var note = ""
    }
    struct Band: Decodable {
        let crop: [Int]
        var images: [String]? = nil
        var review: Review? = nil
        /// The band as first detected, when Claude moved it.
        var detected: [Int]? = nil
    }
    struct Segment: Decodable {
        let start: Double
        let end: Double
        let band: Int
    }

    var bands: [Band] = []
    var segments: [Segment] = []

    private enum Keys: String, CodingKey { case bands, segments, crop }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        segments = try c.decodeIfPresent([Segment].self, forKey: .segments) ?? []
        if let b = try c.decodeIfPresent([Band].self, forKey: .bands) {
            bands = b
        } else if let crop = try c.decodeIfPresent([Int].self, forKey: .crop) {
            bands = [Band(crop: crop)]  // jobs from before bands: one band for the whole video
        }
    }

    static func load(_ path: String) -> RegionInfo? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(RegionInfo.self, from: data)
    }

    func stretches(_ band: Int) -> [Segment] { segments.filter { $0.band == band } }
}

/// What "Find caption area" decided: each band with its preview frames and Claude's check.
struct RegionPreviewSheet: View {
    let workDir: String
    var onRedo: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var info: RegionInfo? = nil

    private var previewDir: URL { URL(fileURLWithPath: workDir).appendingPathComponent("region_preview") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Caption area").font(.system(size: 20, weight: .bold))
                Text("OCR reads only inside the green band. Red boxes are watermarks it ignores. "
                     + "When captions move for part of the video, that part uses its own band.")
                    .font(.system(size: 13)).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            Theme.hairline.frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let info, !info.bands.isEmpty {
                        ForEach(Array(info.bands.enumerated()), id: \.offset) { k, band in
                            bandSection(k, band, info)
                        }
                    } else {
                        Text("No caption area yet. It's found when the job reaches “Find caption area”.")
                            .foregroundStyle(Theme.ink2)
                    }
                }
                .padding(24)
            }
            Theme.hairline.frame(height: 1)
            HStack(spacing: 8) {
                Text("Wrong band? Redo from Finding Caption Area, or stop the job before OCR gets far.")
                    .font(.system(size: 12)).foregroundStyle(Theme.ink3)
                Spacer()
                if let onRedo {
                    Button("Redo Caption Area") { onRedo(); dismiss() }
                        .buttonStyle(.subgen(.secondary, height: 32))
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.subgen(.primary, height: 32))
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 860, height: 720)
        .background(Theme.bg)
        .foregroundStyle(Theme.ink)
        .task { info = RegionInfo.load(URL(fileURLWithPath: workDir).appendingPathComponent("region.json").path) }
    }

    @ViewBuilder
    private func bandSection(_ k: Int, _ band: RegionInfo.Band, _ info: RegionInfo) -> some View {
        let images = (band.images ?? []).map { previewDir.appendingPathComponent($0) }
        let height = images.first.flatMap { NSImage(contentsOf: $0)?.representations.first?.pixelsHigh } ?? 0
        let stretches = info.stretches(k)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(info.bands.count > 1 ? "Band \(k + 1)" : "Caption band")
                    .font(.system(size: 15, weight: .semibold))
                if height > 0, band.crop.count == 4 {
                    Text("\(percent(band.crop[1], height))–\(percent(band.crop[1] + band.crop[3], height)) of the height")
                        .font(.system(size: 13)).foregroundStyle(Theme.ink2)
                }
                Spacer()
                if let r = band.review {
                    Label(r.fixed ? "Moved by Claude" : r.ok ? "Checked by Claude" : "Claude has doubts",
                          systemImage: r.fixed ? "arrow.up.and.down" : r.ok ? "checkmark.seal" : "exclamationmark.triangle")
                        .labelStyle(TightLabelStyle())
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(r.ok || r.fixed ? Theme.greenText : Theme.accentText)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(r.ok || r.fixed ? Theme.greenSoft : Theme.notice, in: Capsule())
                }
            }
            if let note = band.review?.note, !note.isEmpty {
                Text(note).font(.system(size: 13)).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if info.bands.count > 1 {
                let total = stretches.reduce(0) { $0 + $1.end - $1.start }
                Text("Used for \(formatDuration(total)) in \(stretches.count) stretch\(stretches.count == 1 ? "" : "es"): "
                     + stretches.prefix(8).map { "\(formatDuration($0.start))–\(formatDuration($0.end))" }
                         .joined(separator: ", ") + (stretches.count > 8 ? ", …" : ""))
                    .font(Theme.mono(11.5)).foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if images.isEmpty {
                Text("No preview frames for this job yet. They're made the next time it runs.")
                    .font(.system(size: 13)).foregroundStyle(Theme.ink3)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(images, id: \.self) { url in
                        PreviewFrame(url: url)
                    }
                }
            }
        }
    }

    private func percent(_ y: Int, _ h: Int) -> String { "\(Int((Double(y) / Double(h) * 100).rounded()))%" }
}

private struct PreviewFrame: View {
    let url: URL
    @State private var image: NSImage? = nil

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            ZStack {
                Theme.video
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("Open full size")
        .task(id: url) { image = NSImage(contentsOf: url) }
    }
}
