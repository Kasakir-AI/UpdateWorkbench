import Foundation

/// Per-app choice for pre-release (beta) versions.
enum PrereleaseRule: String, Codable, CaseIterable, Sendable, Identifiable {
    case followGlobal = "Use global setting"
    case hold = "Hold back"
    case allow = "Allow"
    var id: String { rawValue }
}

/// Ignore, skip and pre-release rules. Keys are item IDs (the app's canonical path, `cask:token`, ...).
struct UpdateRules: Codable, Equatable, Sendable {
    var ignored: Set<String> = []
    var skipped: [String: String] = [:]
    var holdPrereleases = true
    var prereleaseRules: [String: PrereleaseRule] = [:]

    enum Decision: Equatable, Sendable {
        case show
        case ignored
        case skipped(String)
        case heldPrerelease
    }

    static let ignoredKey = "ignored", skippedKey = "skipped", holdKey = "holdPrereleases", prereleaseKey = "prereleaseRules"

    /// True for versions such as 2.0.0-beta.1, 3.1b2, 4.0rc1, 1.2-alpha, 5.0 Preview, 2026.1-nightly.
    static func isPrerelease(_ version: String) -> Bool {
        let text = version.lowercased()
        let range = NSRange(text.startIndex..., in: text)
        return prereleasePatterns.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    /// Compiled once; `isPrerelease` runs for every item whenever the update list is drawn.
    private static let prereleasePatterns: [NSRegularExpression] = [
        #"^v?\d+(\.\d+)*-"#,
        #"(^|[^a-z])(alpha|beta|rc|pre|preview|dev|nightly|canary|insiders?|snapshot|ea|unstable|test)([^a-z]|$)"#,
        #"\d(a|b|rc)\d+$"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    func allowsPrereleases(for id: String) -> Bool {
        switch prereleaseRules[id] ?? .followGlobal {
        case .allow: return true
        case .hold: return false
        case .followGlobal: return !holdPrereleases
        }
    }

    /// Precedence: ignored app > skipped version > held pre-release > show.
    func decision(id: String, latestVersion: String?, isOutdated: Bool) -> Decision {
        if ignored.contains(id) { return .ignored }
        guard isOutdated, let latestVersion else { return .show }
        if skipped[id] == latestVersion { return .skipped(latestVersion) }
        if Self.isPrerelease(latestVersion), !allowsPrereleases(for: id) { return .heldPrerelease }
        return .show
    }

    /// IDs with any rule, for the Settings list.
    var ruleIDs: [String] {
        Array(ignored.union(skipped.keys).union(prereleaseRules.filter { $0.value != .followGlobal }.keys)).sorted()
    }

    mutating func removeRules(for id: String) {
        ignored.remove(id); skipped.removeValue(forKey: id); prereleaseRules.removeValue(forKey: id)
    }

    static func load(_ defaults: UserDefaults = .standard) -> UpdateRules {
        var rules = UpdateRules()
        rules.ignored = Set(defaults.stringArray(forKey: ignoredKey) ?? [])
        rules.skipped = defaults.dictionary(forKey: skippedKey) as? [String: String] ?? [:]
        rules.holdPrereleases = defaults.object(forKey: holdKey) as? Bool ?? true
        let raw = defaults.dictionary(forKey: prereleaseKey) as? [String: String] ?? [:]
        rules.prereleaseRules = raw.compactMapValues(PrereleaseRule.init(rawValue:))
        return rules
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(Array(ignored).sorted(), forKey: Self.ignoredKey)
        defaults.set(skipped, forKey: Self.skippedKey)
        defaults.set(holdPrereleases, forKey: Self.holdKey)
        defaults.set(prereleaseRules.mapValues(\.rawValue), forKey: Self.prereleaseKey)
    }

    /// Human-readable name for a rule key when the app isn't in the current scan.
    static func displayName(for id: String) -> String {
        if id.hasPrefix("/") { return URL(fileURLWithPath: id).deletingPathExtension().lastPathComponent }
        if let colon = id.firstIndex(of: ":") { return String(id[id.index(after: colon)...]) }
        return id
    }
}

/// Background check schedule. Checks only look for updates; nothing installs automatically.
enum CheckSchedule: String, CaseIterable, Codable, Sendable, Identifiable {
    case off = "Off"
    case daily = "Daily"
    case weekly = "Weekly"
    static let defaultsKey = "checkSchedule"
    static let lastCheckKey = "lastCheckDate"
    var id: String { rawValue }

    var interval: TimeInterval? {
        switch self {
        case .off: nil
        case .daily: 86_400
        case .weekly: 7 * 86_400
        }
    }

    /// Reads the setting, migrating the 0.3.x `interval` (seconds) value once.
    static func stored(_ defaults: UserDefaults = .standard) -> CheckSchedule {
        if let raw = defaults.string(forKey: defaultsKey), let value = CheckSchedule(rawValue: raw) { return value }
        let legacy = defaults.double(forKey: "interval")
        if legacy <= 0 { return .off }
        return legacy <= 86_400 ? .daily : .weekly
    }

    /// Due when never checked, or when the interval has passed. Clock changes into the past count as due.
    func isDue(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let interval else { return false }
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed < 0 || elapsed >= interval
    }

    func nextCheck(after lastCheck: Date?, now: Date = Date()) -> Date? {
        guard let interval else { return nil }
        guard let lastCheck, !isDue(lastCheck: lastCheck, now: now) else { return now }
        return lastCheck.addingTimeInterval(interval)
    }
}
