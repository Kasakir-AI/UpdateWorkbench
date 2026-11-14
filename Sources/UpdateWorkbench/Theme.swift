import SwiftUI
import AppKit

/// One pastel color in three roles: a soft surface, a deeper ink for text and icons, and a hairline.
/// Light mode puts dark ink on pastel; dark mode puts the pastel itself on a faint tint of it.
struct Tone {
    let fill: Color
    let ink: Color
    let stroke: Color
    let solid: Color

    init(pastel: UInt32, ink: UInt32, darkInk: UInt32) {
        fill = .adaptive(light: .hex(pastel), dark: .hex(darkInk, alpha: 0.16))
        self.ink = .adaptive(light: .hex(ink), dark: .hex(darkInk))
        stroke = .adaptive(light: .hex(ink, alpha: 0.16), dark: .hex(darkInk, alpha: 0.28))
        solid = .adaptive(light: .hex(pastel), dark: .hex(darkInk, alpha: 0.30))
    }
}

/// The palette. Every color is soft; meaning is always carried by text and symbols too, never by color alone.
enum Pastel {
    static let lavender = Tone(pastel: 0xE8E3FF, ink: 0x5F4FD6, darkInk: 0xB8ADFF)
    static let lilac = Tone(pastel: 0xF0E2FB, ink: 0x8A47C4, darkInk: 0xD7B6F7)
    static let sky = Tone(pastel: 0xDCEBFF, ink: 0x2E6AB8, darkInk: 0x9CC5FF)
    static let mint = Tone(pastel: 0xD5F3E5, ink: 0x1F7D59, darkInk: 0x8BDDB9)
    static let aqua = Tone(pastel: 0xD5F1F4, ink: 0x1C7580, darkInk: 0x8AD8E2)
    static let rose = Tone(pastel: 0xFFE0EB, ink: 0xB83D72, darkInk: 0xFFA9C9)
    static let peach = Tone(pastel: 0xFFE5D3, ink: 0xAD5726, darkInk: 0xFFBE96)
    static let butter = Tone(pastel: 0xFFF1C4, ink: 0x8C680A, darkInk: 0xF3D57A)
    static let coral = Tone(pastel: 0xFFDEDB, ink: 0xBE3A31, darkInk: 0xFFA39C)
    static let slate = Tone(pastel: 0xE8EBF1, ink: 0x566073, darkInk: 0xB4BCCB)
}

/// Visual language: native macOS controls on calm surfaces, with pastel color for state and source.
enum Theme {
    /// Control tint: a lavender deep enough for white text on prominent buttons.
    static let accent = Color.adaptive(light: .hex(0x5F4FD6), dark: .hex(0x8476F0))
    static let indigo = Pastel.lavender.ink
    static let violet = Pastel.lilac.ink
    static let pink = Pastel.rose.ink
    static let mint = Pastel.mint.ink

    /// Small accents (arrows, bullets) that must stay visible on plain backgrounds.
    static let inkGradient = LinearGradient(colors: [Pastel.lavender.ink, Pastel.rose.ink], startPoint: .leading, endPoint: .trailing)
    /// Hero and sheet headers: pastel in light mode, a deep muted version in dark mode.
    static let accentGradient = gradient(light: [0xE6E0FF, 0xFFDDEA, 0xFFE6D6], dark: [0x3A3470, 0x4D2F4D, 0x4B3731])
    static let successGradient = gradient(light: [0xD4F3E6, 0xDCEBFF], dark: [0x1D4339, 0x213856])
    static let idleGradient = gradient(light: [0xDDE8FF, 0xEAE4FF], dark: [0x263257, 0x372F5E])
    static let warningGradient = gradient(light: [0xFFE5D3, 0xFFE0EB], dark: [0x4D3528, 0x4D2C3D])
    /// Text on those gradients.
    static let heroText = Color.adaptive(light: .hex(0x2A2549), dark: .white)
    /// Translucent surface for secondary buttons and chips on the hero gradients.
    static let frosted = Color.adaptive(light: .hex(0xFFFFFF, alpha: 0.55), dark: .hex(0xFFFFFF, alpha: 0.14))
    static let heroSecondary = Color.adaptive(light: .hex(0x2A2549, alpha: 0.72), dark: .hex(0xFFFFFF, alpha: 0.80))

    static let cardRadius: CGFloat = 16
    static let spacing: CGFloat = 16

    private static func gradient(light: [UInt32], dark: [UInt32]) -> LinearGradient {
        LinearGradient(colors: zip(light, dark).map { Color.adaptive(light: .hex($0), dark: .hex($1)) }, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension NSColor {
    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    /// Resolves per appearance, so one value serves the window, sheets and the menu bar panel.
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
}

extension UpdateProvider {
    var tone: Tone {
        switch self {
        case .homebrewCask: Pastel.peach
        case .homebrewFormula: Pastel.butter
        case .appStore: Pastel.sky
        case .sparkle: Pastel.lilac
        case .github: Pastel.slate
        case .electron: Pastel.aqua
        case .vendor: Pastel.rose
        case .manual: Pastel.slate
        }
    }
    var tint: Color { tone.ink }
    var symbol: String {
        switch self {
        case .homebrewCask: "mug.fill"
        case .homebrewFormula: "terminal.fill"
        case .appStore: "bag.fill"
        case .sparkle: "sparkles"
        case .github: "chevron.left.forwardslash.chevron.right"
        case .electron: "atom"
        case .vendor: "building.2.fill"
        case .manual: "hand.raised.fill"
        }
    }
    var shortName: String {
        switch self {
        case .homebrewCask: "Homebrew"
        case .homebrewFormula: "Formula"
        case .appStore: "App Store"
        case .sparkle: "Sparkle"
        case .github: "GitHub"
        case .electron: "Electron"
        case .vendor: "Vendor"
        case .manual: "Manual"
        }
    }
    var explanation: String {
        switch self {
        case .homebrewCask: "Installed and updated by Homebrew."
        case .homebrewFormula: "A command-line package managed by Homebrew."
        case .appStore: "Updated through the Mac App Store."
        case .sparkle: "Uses a Sparkle update feed published by the developer."
        case .github: "Checked against the latest release of a GitHub repository you chose."
        case .electron: "Uses the update feed declared by this Electron app."
        case .vendor: "Updated by the developer's own updater app."
        case .manual: "No update source found yet. See Suggestions or add a source."
        }
    }
}

extension ItemStatus {
    var tone: Tone {
        switch self {
        case .failed: Pastel.coral
        case .ready: Pastel.lavender
        case .manualUpdate: Pastel.peach
        case .selfUpdating: Pastel.rose
        case .snoozed: Pastel.lilac
        case .heldBack: Pastel.butter
        case .skipped, .ignored, .unknown: Pastel.slate
        case .upToDate: Pastel.mint
        }
    }
    var tint: Color { tone.ink }
}

extension PermissionState {
    var tone: Tone {
        switch self { case .granted: Pastel.mint; case .denied: Pastel.peach; case .unknown, .notNeeded: Pastel.slate }
    }
    var tint: Color { tone.ink }
    var symbol: String {
        switch self { case .granted: "checkmark.circle.fill"; case .denied: "exclamationmark.circle.fill"; case .unknown: "questionmark.circle.fill"; case .notNeeded: "minus.circle.fill" }
    }
}

extension SidebarSection {
    var tone: Tone {
        switch self {
        case .updates: Pastel.lavender
        case .applications: Pastel.sky
        case .packages: Pastel.butter
        case .suggestions: Pastel.peach
        case .ignored: Pastel.slate
        case .history: Pastel.rose
        case .permissions: Pastel.mint
        }
    }
    var tint: Color { tone.ink }
}

/// Small capsule with icon + text. Color is decorative; the text carries the meaning.
struct Pill: View {
    let text: String
    let symbol: String
    let tone: Tone
    init(text: String, symbol: String, tone: Tone) { self.text = text; self.symbol = symbol; self.tone = tone }
    var body: some View {
        Label { Text(text).lineLimit(1) } icon: { Image(systemName: symbol).imageScale(.small) }
            .font(.caption.weight(.semibold))
            .foregroundStyle(tone.ink)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(tone.fill))
            .overlay(Capsule().strokeBorder(tone.stroke, lineWidth: 0.5))
            .fixedSize()
    }
}

struct SourceBadge: View {
    let provider: UpdateProvider
    var body: some View {
        Pill(text: provider.shortName, symbol: provider.symbol, tone: provider.tone)
            .help(provider.explanation)
            .accessibilityLabel("Source: \(provider.rawValue)")
    }
}

struct StatusBadge: View {
    let status: ItemStatus
    var body: some View {
        Pill(text: status.rawValue, symbol: status.symbol, tone: status.tone)
            .accessibilityLabel("Status: \(status.rawValue)")
    }
}

/// A symbol on a soft rounded tile, used for section, card and history headers.
struct IconTile: View {
    let symbol: String
    let tone: Tone
    var size: CGFloat = 40
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(tone.ink)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(tone.fill))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(tone.stroke, lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

/// App icon from disk when available, otherwise a colored tile with the app's initial.
struct AppIconView: View {
    let item: UpdateItem
    var size: CGFloat = 36
    var body: some View {
        Group {
            if let path = item.path, FileManager.default.fileExists(atPath: path) {
                Image(nsImage: AppIconCache.icon(forFile: path)).resizable().interpolation(.high)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(item.provider.tone.fill)
                    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(item.provider.tone.stroke, lineWidth: 0.5)
                    if item.provider == .homebrewFormula {
                        Image(systemName: "terminal.fill").font(.system(size: size * 0.40, weight: .semibold)).foregroundStyle(item.provider.tone.ink)
                    } else {
                        Text(String(item.name.prefix(1)).uppercased()).font(.system(size: size * 0.46, weight: .bold, design: .rounded)).foregroundStyle(item.provider.tone.ink)
                    }
                }
                .padding(size * 0.06)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Rounded container used for detail and settings cards.
struct Card<Content: View>: View {
    var title: String? = nil
    var symbol: String? = nil
    var tone: Tone = Pastel.slate
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(spacing: 10) {
                    IconTile(symbol: symbol ?? "circle", tone: tone, size: 26)
                    Text(title).font(.headline)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(.separator.opacity(0.45), lineWidth: 0.5))
    }
}

/// Count tile for the summary row.
struct StatTile: View {
    let value: Int
    let label: String
    let symbol: String
    let tone: Tone
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol).font(.callout.weight(.semibold)).foregroundStyle(tone.ink)
            Text("\(value)").font(.title2.weight(.bold)).monospacedDigit().foregroundStyle(tone.ink)
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tone.fill))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tone.stroke, lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(label)")
    }
}

/// Capsule button on a pastel hero card: filled lavender for the main action, frosted for the rest.
struct HeroButtonStyle: ButtonStyle {
    var filled = true
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .foregroundStyle(filled ? Color.white : Theme.heroText)
            .background(Capsule().fill(filled ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.frosted)))
            .overlay(Capsule().strokeBorder(filled ? Color.clear : Theme.heroText.opacity(0.18), lineWidth: 1))
            .shadow(color: filled ? Theme.accent.opacity(0.28) : .clear, radius: 6, y: 2)
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.5)
            .contentShape(Capsule())
    }
}

/// Compact pastel capsule for in-row actions; looks the same whether or not the window is active.
struct PastelButtonStyle: ButtonStyle {
    let tone: Tone
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(tone.ink)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(Capsule().fill(tone.solid))
            .overlay(Capsule().strokeBorder(tone.stroke, lineWidth: 0.5))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .contentShape(Capsule())
    }
}

/// Labeled value row used in detail cards.
struct InfoRow: View {
    let label: String
    let value: String
    var monospaced = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
            Text(value).font(monospaced ? .system(.callout, design: .monospaced) : .callout)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

extension AppearanceMode {
    var colorScheme: ColorScheme? {
        switch self { case .dark: .dark; case .light: .light; case .system: nil }
    }
    var nsAppearance: NSAppearance? {
        switch self { case .dark: NSAppearance(named: .darkAqua); case .light: NSAppearance(named: .aqua); case .system: nil }
    }
    var symbol: String {
        switch self { case .dark: "moon.stars.fill"; case .light: "sun.max.fill"; case .system: "circle.lefthalf.filled" }
    }
}

/// Workspace icons are loaded once per path instead of on every view update.
@MainActor
enum AppIconCache {
    private static let cache: NSCache<NSString, NSImage> = { let cache = NSCache<NSString, NSImage>(); cache.countLimit = 600; return cache }()
    static func icon(forFile path: String) -> NSImage {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(icon, forKey: path as NSString)
        return icon
    }
}
