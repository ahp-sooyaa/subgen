import AVFoundation
import SwiftUI

/// The app's look: warm paper greys, near-black ink and one yellow accent. Light only.
enum Theme {
    static let bg = Color(hex: 0xFBF9F4)
    static let sidebar = Color(hex: 0xF1ECE2)
    static let card = Color.white
    static let border = Color(hex: 0xD9D1C1)
    static let divider = Color(hex: 0xE2DBCD)
    static let hairline = Color(hex: 0xE8E2D6)
    static let rowLine = Color(hex: 0xF1ECE2)

    static let ink = Color(hex: 0x1B1D22)
    static let ink2 = Color(hex: 0x5E5A52)
    static let ink3 = Color(hex: 0x6F695F)
    static let paper = Color(hex: 0xF6F2EA)  // text on ink

    static let accent = Color(hex: 0xF5B820)
    static let accentSoft = Color(hex: 0xFCEFC9)
    static let accentText = Color(hex: 0x6B4A00)
    static let link = Color(hex: 0x855B00)
    static let track = Color(hex: 0xECE5D6)
    static let chip = Color(hex: 0xEDE7DB)
    static let chipText = Color(hex: 0x3E3B35)
    static let segment = Color(hex: 0xE4DDCF)
    static let tile = Color(hex: 0xF3EFE6)

    static let green = Color(hex: 0x2F7D4F)
    static let greenSoft = Color(hex: 0xDCEFE2)
    static let greenText = Color(hex: 0x1F5A37)
    static let red = Color(hex: 0xB3361F)
    static let redSoft = Color(hex: 0xF7E0DA)
    static let notice = Color(hex: 0xFBF0DA)

    static let video = Color(hex: 0x0E0F12)

    static func mono(_ size: CGFloat) -> Font { .system(size: size, design: .monospaced) }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Buttons

struct SubgenButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost }
    var kind: Kind = .secondary
    var height: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind, height: height)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        let kind: Kind
        let height: CGFloat
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: kind == .primary ? .semibold : .medium))
                .labelStyle(TightLabelStyle())
                .foregroundStyle(enabled ? Theme.ink : Theme.ink3)
                .padding(.horizontal, kind == .ghost ? 8 : (kind == .primary ? 16 : 12))
                .frame(minWidth: kind == .ghost ? height + 2 : nil, minHeight: height)
                .background(background, in: RoundedRectangle(cornerRadius: height > 30 ? 8 : 7))
                .overlay {
                    if kind == .secondary {
                        RoundedRectangle(cornerRadius: height > 30 ? 8 : 7)
                            .strokeBorder(enabled ? Theme.border : Theme.divider)
                    }
                }
                .opacity(configuration.isPressed ? 0.75 : 1)
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }

        private var background: Color {
            switch kind {
            case .primary: enabled ? Theme.accent : Theme.accent.opacity(0.4)
            case .secondary: enabled ? (hover ? Theme.tile : Theme.card) : .clear
            case .ghost: hover && enabled ? Theme.ink.opacity(0.07) : .clear
            }
        }
    }
}

extension ButtonStyle where Self == SubgenButtonStyle {
    static var subgen: SubgenButtonStyle { SubgenButtonStyle() }
    static func subgen(_ kind: SubgenButtonStyle.Kind, height: CGFloat = 30) -> SubgenButtonStyle {
        SubgenButtonStyle(kind: kind, height: height)
    }
}

struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 12, weight: .semibold))
            configuration.title
        }
    }
}

/// A plain text button in the link color.
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.link)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

// MARK: - Small pieces

struct Pill: View {
    enum Tone { case neutral, running, done, failed }
    let text: String
    var tone: Tone = .neutral

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: tone == .neutral ? .medium : .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(bg, in: Capsule())
    }

    private var bg: Color {
        switch tone {
        case .neutral: Theme.chip
        case .running: Theme.accentSoft
        case .done: Theme.greenSoft
        case .failed: Theme.redSoft
        }
    }
    private var fg: Color {
        switch tone {
        case .neutral: Theme.chipText
        case .running: Theme.accentText
        case .done: Theme.greenText
        case .failed: Theme.red
        }
    }
}

/// A rounded bar filled to `value` (0...1).
struct Bar: View {
    var value: Double
    var height: CGFloat = 6
    var fill = Theme.accent
    var track = Theme.track

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                track
                fill.frame(width: geo.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: height / 2))
    }
}

/// The job's status as a 16 pt glyph.
struct StatusGlyph: View {
    let status: JobStatus
    var onDark = false
    @State private var spin = false

    var body: some View {
        Group {
            switch status {
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Theme.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Theme.red)
            case .running:
                ZStack {
                    Circle().stroke(onDark ? Theme.paper.opacity(0.3) : Theme.ink2.opacity(0.35), lineWidth: 2)
                    Circle().trim(from: 0, to: 0.3)
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                        .rotationEffect(.degrees(spin ? 360 : 0))
                }
                .padding(1.5)
                .onAppear {
                    withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { spin = true }
                }
            case .queued: Image(systemName: "clock")
            case .paused: Image(systemName: "pause.circle")
            case .stopped: Image(systemName: "stop.circle")
            }
        }
        .font(.system(size: 15))
        .foregroundStyle(onDark ? Theme.paper.opacity(0.8) : Theme.ink3)
        .frame(width: 16, height: 16)
    }
}

/// A white bordered text field that glows yellow while focused.
struct BoxedField: View {
    let label: String
    @Binding var text: String
    var prompt = ""
    var mono = false
    var size: CGFloat = 13
    var height: CGFloat = 28
    var trailing = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField(label, text: $text, prompt: Text(prompt).foregroundStyle(Theme.ink3))
            .labelsHidden()
            .textFieldStyle(.plain)
            .font(mono ? Theme.mono(size) : .system(size: size))
            .foregroundStyle(Theme.ink)
            .multilineTextAlignment(trailing ? .trailing : .leading)
            .focused($focused)
            .padding(.horizontal, height > 30 ? 12 : 9)
            .frame(height: height)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: height > 30 ? 8 : 6))
            .overlay(RoundedRectangle(cornerRadius: height > 30 ? 8 : 6)
                .strokeBorder(focused ? Theme.ink : Theme.border))
            .focusGlow(focused, radius: height > 30 ? 8 : 6)
    }
}

extension View {
    /// The yellow focus ring around inputs.
    func focusGlow(_ on: Bool, radius: CGFloat) -> some View {
        overlay(RoundedRectangle(cornerRadius: radius + 2)
            .stroke(Theme.accent.opacity(on ? 0.45 : 0), lineWidth: 3)
            .padding(-2.5))
    }

    /// A white card with a hairline border.
    func card(_ radius: CGFloat = 12) -> some View {
        background(Theme.card, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.divider))
    }
}

/// A frame from the video, or a dark placeholder until there is one.
struct VideoThumbnail: View {
    let path: String?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color(hex: 0x15161A)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "film").font(.system(size: 22)).foregroundStyle(Color(hex: 0x8E887C))
            }
        }
        .frame(width: 240, height: 135)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: path) { image = await Self.frame(path) }
    }

    private static func frame(_ path: String?) async -> NSImage? {
        guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 270)
        let length = (try? await asset.load(.duration).seconds) ?? 0
        let at = CMTime(seconds: length > 0 ? min(length * 0.1, 120) : 0, preferredTimescale: 600)
        guard let frame = try? await gen.image(at: at) else { return nil }
        return NSImage(cgImage: frame.image, size: .zero)
    }
}
