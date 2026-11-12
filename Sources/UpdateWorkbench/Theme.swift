import SwiftUI
import AppKit

/// Visual language: native macOS controls, dark by default, with a few deliberate color splashes.
enum Theme {
    static let indigo = Color(red: 0.36, green: 0.42, blue: 1.00)
    static let violet = Color(red: 0.62, green: 0.36, blue: 0.98)
    static let pink = Color(red: 0.98, green: 0.38, blue: 0.62)
    static let mint = Color(red: 0.20, green: 0.80, blue: 0.62)
    static let accent = indigo
    static let accentGradient = LinearGradient(colors: [indigo, violet, pink], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let successGradient = LinearGradient(colors: [Color(red: 0.13, green: 0.62, blue: 0.47), Color(red: 0.16, green: 0.55, blue: 0.80)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let idleGradient = LinearGradient(colors: [Color(red: 0.25, green: 0.30, blue: 0.62), Color(red: 0.45, green: 0.28, blue: 0.70)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let cardRadius: CGFloat = 14
    static let spacing: CGFloat = 16
}

extension UpdateProvider {
    var tint: Color {
        switch self {
        case .homebrewCask: Color(red: 0.98, green: 0.58, blue: 0.20)
        case .homebrewFormula: Color(red: 0.90, green: 0.72, blue: 0.22)
        case .appStore: Color(red: 0.25, green: 0.60, blue: 1.00)
        case .sparkle: Color(red: 0.72, green: 0.45, blue: 1.00)
        case .github: Color(red: 0.55, green: 0.62, blue: 0.72)
        case .electron: Color(red: 0.25, green: 0.82, blue: 0.90)
        case .vendor: Color(red: 0.98, green: 0.42, blue: 0.62)
        case .manual: Color(red: 0.58, green: 0.58, blue: 0.62)
        }
    }
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
    var tint: Color {
        switch self {
        case .failed: .red
        case .ready: Theme.accent
        case .manualUpdate: .orange
        case .selfUpdating: UpdateProvider.vendor.tint
        case .snoozed: .purple
        case .heldBack: .orange
        case .skipped, .ignored, .unknown: .secondary
        case .upToDate: .green
        }
    }
}

extension PermissionState {
    var tint: Color {
        switch self { case .granted: .green; case .denied: .orange; case .unknown: .secondary; case .notNeeded: .secondary }
    }
    var symbol: String {
        switch self { case .granted: "checkmark.circle.fill"; case .denied: "exclamationmark.circle.fill"; case .unknown: "questionmark.circle.fill"; case .notNeeded: "minus.circle.fill" }
    }
}

extension SidebarSection {
    var tint: Color {
        switch self {
        case .updates: Theme.indigo
        case .applications: Theme.violet
        case .packages: UpdateProvider.homebrewFormula.tint
        case .suggestions: Color(red: 1.0, green: 0.78, blue: 0.20)
        case .ignored: .gray
        case .history: Theme.pink
        case .permissions: Theme.mint
        }
    }
}

/// Small capsule with icon + text. Color is decorative; the text carries the meaning.
struct Pill: View {
    let text: String
    let symbol: String
    let tint: Color
    var prominent = false
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        // Bright tints read well on dark backgrounds; in light mode the text uses the primary color for contrast.
        Label { Text(text).lineLimit(1).foregroundStyle(prominent ? Color.white : (colorScheme == .dark ? tint : Color.primary.opacity(0.85))) }
            icon: { Image(systemName: symbol).imageScale(.small).foregroundStyle(prominent ? Color.white : tint) }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(prominent ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.16))))
            .overlay(Capsule().strokeBorder(tint.opacity(prominent ? 0 : 0.35), lineWidth: 0.5))
            .fixedSize()
    }
}

struct SourceBadge: View {
    let provider: UpdateProvider
    var body: some View {
        Pill(text: provider.shortName, symbol: provider.symbol, tint: provider.tint)
            .help(provider.explanation)
            .accessibilityLabel("Source: \(provider.rawValue)")
    }
}

struct StatusBadge: View {
    let status: ItemStatus
    var body: some View {
        Pill(text: status.rawValue, symbol: status.symbol, tint: status.tint)
            .accessibilityLabel("Status: \(status.rawValue)")
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
                    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                        .fill(LinearGradient(colors: [item.provider.tint, item.provider.tint.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    if item.provider == .homebrewFormula {
                        Image(systemName: "terminal.fill").font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white)
                    } else {
                        Text(String(item.name.prefix(1)).uppercased()).font(.system(size: size * 0.48, weight: .bold, design: .rounded)).foregroundStyle(.white)
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
    var tint: Color = .secondary
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Label { Text(title).font(.headline) } icon: { Image(systemName: symbol ?? "circle").foregroundStyle(tint) }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
    }
}

/// Count tile for the summary row.
struct StatTile: View {
    let value: Int
    let label: String
    let symbol: String
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol).font(.callout.weight(.semibold)).foregroundStyle(tint)
            Text("\(value)").font(.title2.weight(.bold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.25), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(label)")
    }
}

/// White button on a gradient hero card.
struct HeroButtonStyle: ButtonStyle {
    var filled = true
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .foregroundStyle(filled ? Color(red: 0.22, green: 0.18, blue: 0.55) : .white)
            .background(Capsule().fill(filled ? Color.white : Color.white.opacity(0.18)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(filled ? 0 : 0.45), lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.5)
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
