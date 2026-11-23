import Foundation
import SQLite3

/// The App Store's own list of pending updates, kept by appstoreagent in `storeSystem.db`.
/// mas asks a public lookup service that can lag behind by hours and doesn't know iPhone and iPad apps
/// installed on the Mac; this list is what the App Store's Updates page shows. It is read from a private
/// copy, never written, and an unreadable list means "unknown", never "up to date".
enum AppStoreQueue {
    struct Pending: Equatable, Sendable {
        var adamID: String
        var bundleID: String?
        var name: String
        var latestVersion: String?
        /// false for iPhone and iPad apps running on the Mac, which mas can't update.
        var isMacApp: Bool
    }

    /// The account's real home (appstoreagent's location), even when CFFIXED_USER_HOME redirects the app's own data.
    static var defaultDatabase: URL {
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Caches/com.apple.appstoreagent/storeSystem.db")
    }

    /// One `mapi_app_update` row; `metadata` is the App Store catalog record for the app.
    static func parse(adamID: String, bundleID: String?, metadata: String) -> Pending? {
        guard AppStoreCLI.validID(adamID) else { return nil }
        let object = metadata.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let attributes = object?["attributes"] as? [String: Any] ?? [:]
        let platforms = attributes["platformAttributes"] as? [String: Any] ?? [:]
        func version(_ platform: String) -> String? {
            ((platforms[platform] as? [String: Any])?["latestVersionInfo"] as? [String: Any])?["versionDisplay"] as? String
        }
        let families = attributes["deviceFamilies"] as? [String] ?? []
        let isMacApp = platforms["osx"] != nil || families.contains("mac") || platforms.isEmpty
        let name = (attributes["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? bundleID ?? "App \(adamID)"
        return Pending(adamID: adamID, bundleID: bundleID, name: name, latestVersion: isMacApp ? version("osx") ?? version("ios") : version("ios"), isMacApp: isMacApp)
    }

    /// The list is Apple's private file, so a macOS update can move or reshape it. Reading it never fails
    /// silently: `unavailable` carries a reason that the scan shows instead of reporting "no updates".
    enum Outcome: Equatable, Sendable {
        case pending([Pending])
        case unavailable(String)
    }

    static func warning(for reason: String) -> String {
        "Update Workbench couldn't read the App Store's Updates list: \(reason) App Store apps were checked with mas only, which can miss new updates and iPhone and iPad apps. Open App Store Updates to be sure."
    }

    static func read(database: URL = defaultDatabase) -> Outcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: database.path) else {
            return .unavailable("the list wasn't found (open the App Store app once, or a macOS update may have moved it).")
        }
        guard fm.isReadableFile(atPath: database.path) else {
            return .unavailable("macOS didn't allow reading the list.")
        }
        // appstoreagent keeps the database open in WAL mode; copy all three files so the read sees recent changes.
        let folder = fm.temporaryDirectory.appendingPathComponent("UpdateWorkbenchAppStore-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: folder) }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let copy = folder.appendingPathComponent("store.db")
            try fm.copyItem(at: database, to: copy)
            for suffix in ["-wal", "-shm"] {
                let side = URL(fileURLWithPath: database.path + suffix)
                if fm.fileExists(atPath: side.path) { try fm.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix)) }
            }
            return query(copy)
        } catch { return .unavailable("the list couldn't be copied for reading (\(error.localizedDescription)).") }
    }

    private static func query(_ url: URL) -> Outcome {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db); return .unavailable("the list couldn't be opened.")
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let sql = "SELECT CAST(item_id AS TEXT), bundle_id, metadata FROM mapi_app_update WHERE update_state = 0 ORDER BY pid"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return .unavailable("the list is in a format this version doesn't understand (a macOS update may have changed it).")
        }
        defer { sqlite3_finalize(statement) }
        func text(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
        var pending: [Pending] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let id = text(0), let entry = parse(adamID: id, bundleID: text(1), metadata: text(2) ?? "") { pending.append(entry) }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { return .unavailable("the list couldn't be read to the end.") }
        return .pending(pending)
    }

    /// Marks listed apps as outdated. Apps mas already reported keep mas's details; apps the scan didn't list
    /// (iPhone and iPad apps have no Contents/Info.plist) are added, located with `locate(bundleID)`.
    static func merge(_ pending: [Pending], into items: inout [UpdateItem], locate: (String) -> (path: String, version: String)?) {
        for entry in pending {
            let index = items.firstIndex { $0.token == entry.adamID && $0.provider == .appStore }
                ?? entry.bundleID.flatMap { id in items.firstIndex { $0.bundleID == id && $0.path != nil } }
            let storePage = URL(string: "macappstore://apps.apple.com/app/id\(entry.adamID)")
            let detail = entry.isMacApp
                ? "The App Store lists this update (ID \(entry.adamID)). Updating uses mas and may ask for your administrator password."
                : "The App Store lists this update. iPhone and iPad apps update in the App Store app."
            if let index {
                if items[index].isOutdated && items[index].provider == .appStore { continue }
                items[index].provider = .appStore
                items[index].token = entry.isMacApp ? entry.adamID : nil
                items[index].latestVersion = entry.latestVersion ?? "Update available"
                items[index].isOutdated = true
                items[index].homepage = items[index].homepage ?? storePage
                items[index].detail = detail
            } else {
                let found = entry.bundleID.flatMap(locate)
                items.append(UpdateItem(id: found?.path ?? "appstore:\(entry.adamID)", name: entry.name, bundleID: entry.bundleID, path: found?.path,
                                        installedVersion: found?.version ?? "Unknown", latestVersion: entry.latestVersion ?? "Update available",
                                        provider: .appStore, token: entry.isMacApp ? entry.adamID : nil, homepage: storePage,
                                        isOutdated: true, detail: detail))
            }
        }
    }

    /// iPhone and iPad apps on the Mac are wrappers (`Name.app/WrappedBundle -> Wrapper/Name.app`) whose
    /// Info.plist sits at the top of the inner bundle.
    static func locateWrappedApp(bundleID: String, roots: [URL] = [URL(fileURLWithPath: "/Applications")]) -> (path: String, version: String)? {
        let fm = FileManager.default
        for root in roots {
            guard let apps = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for app in apps where app.pathExtension.lowercased() == "app" {
                let plist = app.appendingPathComponent("WrappedBundle/Info.plist")
                guard let data = try? Data(contentsOf: plist),
                      let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      info["CFBundleIdentifier"] as? String == bundleID else { continue }
                return (app.path, info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String ?? "Unknown")
            }
        }
        return nil
    }
}
