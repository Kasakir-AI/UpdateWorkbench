import AppKit
import Foundation

/// One update attempt. History is a log only: installs never keep a copy of the previous version.
struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    enum Result: String, Codable, Sendable, CaseIterable {
        case installed = "Installed"
        case failed = "Failed"
        /// Only written by earlier 0.4.0 test builds, which could restore kept copies; still readable.
        case restored = "Restored"
        case restoreFailed = "Restore failed"
    }

    var id = UUID()
    var date: Date
    var itemID: String
    var appName: String
    var bundleID: String?
    var appPath: String?
    var fromVersion: String
    var toVersion: String
    var source: String
    var result: Result
    var message: String

    var succeeded: Bool { result == .installed || result == .restored }
}

/// Update history persisted as JSON, newest first, capped at 500 entries.
struct HistoryStore: Sendable {
    let fileURL: URL
    static let maximumEntries = 500

    static var standard: HistoryStore { HistoryStore(fileURL: AppSupport.folder.appendingPathComponent("history.json")) }

    func load() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return ((try? decoder.decode([HistoryEntry].self, from: data)) ?? []).sorted { $0.date > $1.date }
    }

    func save(_ entries: [HistoryEntry]) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let trimmed = Array(entries.sorted { $0.date > $1.date }.prefix(Self.maximumEntries))
        try AppSupport.write(try encoder.encode(trimmed), to: fileURL)
    }

    @discardableResult
    func append(_ entry: HistoryEntry) throws -> [HistoryEntry] {
        var entries = load()
        entries.insert(entry, at: 0)
        try save(entries)
        return load()
    }

    @discardableResult
    func update(_ id: UUID, _ change: (inout HistoryEntry) -> Void) throws -> [HistoryEntry] {
        var entries = load()
        if let index = entries.firstIndex(where: { $0.id == id }) { change(&entries[index]) }
        try save(entries)
        return entries
    }
}

/// Reads an app's Info.plist straight from disk. `Bundle(url:)` caches its info dictionary for the life of the
/// process, so after an in-place update it kept reporting the old version and the update was offered again.
enum AppBundleInfo {
    static func read(_ app: URL) -> [String: Any] {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [:] }
        return value
    }

    /// Hidden bundles (`.Name.app`) and copies named `*-backup-*.app` are never treated as installed apps.
    static func isHiddenOrBackupCopy(_ app: URL) -> Bool {
        let name = app.lastPathComponent
        return name.hasPrefix(".") || (name.lowercased().hasSuffix(".app") && name.lowercased().contains("-backup-"))
    }
}
