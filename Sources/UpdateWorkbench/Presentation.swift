import Foundation

/// Appearance preference. Dark is the default for new installs.
enum AppearanceMode: String, CaseIterable, Sendable, Identifiable {
    case dark = "Dark"
    case light = "Light"
    case system = "System"
    static let defaultsKey = "appearance"
    var id: String { rawValue }
    /// Unknown or missing stored values fall back to Dark.
    static func stored(_ value: String?) -> AppearanceMode { value.flatMap(AppearanceMode.init(rawValue:)) ?? .dark }
}

/// Sidebar destinations of the main window.
enum SidebarSection: String, CaseIterable, Sendable, Identifiable {
    case updates = "Updates"
    case applications = "Applications"
    case packages = "Packages"
    case suggestions = "Suggestions"
    case ignored = "Ignored"
    case history = "History"
    case permissions = "Permissions"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .updates: "arrow.down.circle.fill"
        case .applications: "square.grid.2x2.fill"
        case .packages: "shippingbox.fill"
        case .suggestions: "lightbulb.fill"
        case .ignored: "eye.slash.fill"
        case .history: "clock.arrow.circlepath"
        case .permissions: "lock.shield.fill"
        }
    }
    var subtitle: String {
        switch self {
        case .updates: "Apps and packages with a newer version"
        case .applications: "Everything installed in your app folders"
        case .packages: "Command-line tools installed with Homebrew"
        case .suggestions: "Ways to keep more apps up to date"
        case .ignored: "Ignored apps, skipped versions, held betas and snoozes"
        case .history: "A log of every update attempt"
        case .permissions: "What Update Workbench can access"
        }
    }
}

/// Per-item status shown as a colored badge with an icon and text (never color alone).
enum ItemStatus: String, Sendable, Equatable {
    case failed = "Update failed"
    case ready = "Update ready"
    case manualUpdate = "Manual update"
    case selfUpdating = "Updates itself"
    case snoozed = "Snoozed"
    case skipped = "Version skipped"
    case heldBack = "Pre-release held"
    case ignored = "Ignored"
    case upToDate = "Up to date"
    case unknown = "No update source"

    var symbol: String {
        switch self {
        case .failed: "exclamationmark.triangle.fill"
        case .ready: "arrow.down.circle.fill"
        case .manualUpdate: "hand.point.up.left.fill"
        case .selfUpdating: "arrow.triangle.2.circlepath"
        case .snoozed: "moon.zzz.fill"
        case .skipped: "forward.end.fill"
        case .heldBack: "flask.fill"
        case .ignored: "eye.slash.fill"
        case .upToDate: "checkmark.seal.fill"
        case .unknown: "questionmark.circle"
        }
    }

    /// Precedence: failure > user choices (ignore, skip, snooze) > update state.
    static func classify(_ item: UpdateItem, ignored: Bool, skippedVersion: String?, snoozedUntil: Double?,
                         failure: String?, heldPrerelease: Bool = false, now: Double = Date().timeIntervalSince1970) -> ItemStatus {
        if failure != nil { return .failed }
        if ignored { return .ignored }
        if item.isOutdated, let skippedVersion, skippedVersion == item.latestVersion { return .skipped }
        if item.isOutdated, heldPrerelease { return .heldBack }
        if item.isOutdated, let snoozedUntil, snoozedUntil > now { return .snoozed }
        if item.isOutdated { return item.canUpdateDirectly ? .ready : .manualUpdate }
        if item.provider == .vendor, item.latestVersion == nil { return .selfUpdating }
        if item.latestVersion != nil || [.homebrewCask, .homebrewFormula, .appStore].contains(item.provider) { return .upToDate }
        return .unknown
    }
}

/// Short user-facing copy for the Updates hero card.
enum HeroSummary {
    static func title(updates: Int, scanned: Bool) -> String {
        guard scanned else { return "Let's check your apps" }
        switch updates {
        case 0: return "Everything is up to date"
        case 1: return "1 update available"
        default: return "\(updates) updates available"
        }
    }
    static func subtitle(updates: Int, direct: Int, scanned: Bool, total: Int) -> String {
        guard scanned else { return "Scan your apps and Homebrew packages. Nothing is installed until you choose Update." }
        if updates == 0 { return "Checked \(total) apps and packages." }
        let manual = updates - direct
        var parts = ["\(direct) can be installed here"]
        if manual > 0 { parts.append("\(manual) update through their own app") }
        return parts.joined(separator: " · ")
    }
}

/// Replaces the home folder with "~" so paths shown on screen and in screenshots don't reveal the account name.
func abbreviatedPath(_ path: String, home: String = NSHomeDirectory()) -> String {
    guard !home.isEmpty, home != "/" else { return path }
    if path == home { return "~" }
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

/// Helpers for state that system controls write back on their own.
enum StateWrites {
    /// Assigns and calls `willChange` only when the value actually changes. Returns whether it changed.
    @discardableResult
    static func assignIfChanged<T: Equatable>(_ target: inout T, _ value: T, willChange: () -> Void) -> Bool {
        guard target != value else { return false }
        willChange()
        target = value
        return true
    }
}
