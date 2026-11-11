import Darwin
import Foundation

/// Enumerated Homebrew management actions. Arbitrary commands are never accepted.
enum HomebrewAction: String, CaseIterable, Sendable {
    case reinstall = "Reinstall (Repair)"
    case uninstall = "Uninstall"
    case unpin = "Unpin"

    static func arguments(_ action: HomebrewAction, for item: UpdateItem) throws -> [String] {
        guard let token = item.token, Engine.validToken(token) else { throw UpdateError.unavailable("Invalid Homebrew package identifier.") }
        switch (action, item.provider) {
        case (.reinstall, .homebrewCask): return ["reinstall", "--cask", token]
        case (.reinstall, .homebrewFormula): return ["reinstall", "--formula", token]
        case (.uninstall, .homebrewCask): return ["uninstall", "--cask", token]
        case (.uninstall, .homebrewFormula): return ["uninstall", "--formula", token]
        case (.unpin, .homebrewFormula):
            guard item.isPinned == true else { throw UpdateError.unavailable("\(item.name) is not pinned.") }
            return ["unpin", token]
        case (.unpin, .homebrewCask): throw UpdateError.unavailable("Homebrew casks cannot be pinned.")
        default: throw UpdateError.unavailable("This item is not managed by Homebrew.")
        }
    }

    var confirmationMessage: String {
        switch self {
        case .reinstall: return "Homebrew downloads the package again and replaces the installed copy. Use this to repair a damaged installation."
        case .uninstall: return "Homebrew removes the package. Casks remove their app; user data is kept (no --zap)."
        case .unpin: return "Homebrew will include this formula in future upgrades again."
        }
    }
}

/// Moves a user-chosen application bundle to the Trash after safety checks. Never deletes outright.
enum AppRemoval {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func validate(path: String, runningBundlePaths: [String], selfPath: String,
                         fileManager: FileManager = .default) throws -> URL {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var directory: ObjCBool = false
        guard path.hasPrefix("/"), !path.contains("\0"), url.pathExtension.lowercased() == "app",
              fileManager.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
            throw Failure(message: "Choose an existing application bundle.")
        }
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw Failure(message: "This is a link to an app, not the app itself. Remove the link in Finder.")
        }
        let canonical = url.resolvingSymlinksInPath().path
        guard !canonical.hasPrefix("/System/"), !canonical.hasPrefix("/Library/Apple/") else {
            throw Failure(message: "macOS system apps cannot be removed.")
        }
        guard canonical != URL(fileURLWithPath: selfPath).resolvingSymlinksInPath().path else {
            throw Failure(message: "Update Workbench cannot move itself to the Trash. Quit it and use Finder.")
        }
        guard !runningBundlePaths.map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }).contains(canonical) else {
            throw Failure(message: "Quit the app before moving it to the Trash.")
        }
        return url
    }

    static func moveToTrash(_ url: URL, trash: (URL) throws -> URL?) throws -> String {
        let destination = try trash(url)
        return "Moved \(url.lastPathComponent) to the Trash" + (destination.map { " (\($0.path))." } ?? ".") + " Restore it from the Trash if needed."
    }

    static func systemTrash(_ url: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }
}

enum PermissionState: String, Sendable {
    case granted = "Allowed"
    case denied = "Not allowed"
    case unknown = "Unknown"
    case notNeeded = "Not needed"
}

struct PermissionCheck: Identifiable, Sendable {
    var id: String { title }
    let title: String
    let state: PermissionState
    let detail: String
    let settingsURL: URL?
}

/// Read-only probes summarizing what this app can and cannot access.
enum PermissionsBackend {
    struct Probes: Sendable {
        var fullDiskAccess: Bool?
        var notifications: Bool?
        var isAdmin: Bool
        var destinations: [(path: String, writable: Bool)]
        var launchAtLogin: String
        var proxyPasswordStored: Bool
    }

    static let fullDiskAccessURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    static let appManagementURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!
    static let automationURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
    static let notificationsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
    static let loginItemsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!

    /// Protected locations used for the Full Disk Access heuristic.
    static func fullDiskAccessCandidates(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        [home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path,
         "/Library/Application Support/com.apple.TCC/TCC.db",
         home.appendingPathComponent("Library/Safari").path,
         home.appendingPathComponent("Library/Mail").path,
         home.appendingPathComponent("Library/Messages").path]
    }

    /// Full Disk Access heuristic: whether a TCC-protected file or folder can be opened for reading.
    /// true on the first readable location, false if any is blocked by privacy controls, nil if none exist.
    static func probeFullDiskAccess(candidates: [String] = fullDiskAccessCandidates()) -> Bool? {
        var blocked = false
        for path in candidates {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                if let directory = opendir(path) { closedir(directory); return true }
            } else {
                let descriptor = open(path, O_RDONLY)
                if descriptor >= 0 { close(descriptor); return true }
            }
            if errno == EPERM || errno == EACCES { blocked = true }
        }
        return blocked ? false : nil
    }

    static func isAdminUser() -> Bool {
        var count: Int32 = 64
        var groups = [Int32](repeating: 0, count: Int(count))
        guard let name = getpwuid(getuid())?.pointee.pw_name else { return false }
        let base = Int32(bitPattern: getgid())
        guard getgrouplist(name, base, &groups, &count) != -1 else { return false }
        return groups.prefix(Int(count)).contains(80)
    }

    static func writable(_ paths: [String]) -> [(path: String, writable: Bool)] {
        paths.map { ($0, access($0, W_OK) == 0) }
    }

    static func checks(_ probes: Probes) -> [PermissionCheck] {
        var result: [PermissionCheck] = []
        let fda: PermissionState = probes.fullDiskAccess.map { $0 ? .granted : .denied } ?? .unknown
        result.append(PermissionCheck(title: "Full Disk Access", state: fda,
            detail: fda == .granted ? "Protected folders can be read during discovery." :
                "Optional. Only needed when custom discovery folders are in protected locations. Detection is a heuristic based on reading a protected file.",
            settingsURL: fullDiskAccessURL))
        result.append(PermissionCheck(title: "App Management", state: .unknown,
            detail: "macOS has no public query for this permission. If replacing another developer's app fails with \"Operation not permitted\", allow Update Workbench under App Management.",
            settingsURL: appManagementURL))
        result.append(PermissionCheck(title: "Automation (Apple Events)", state: .notNeeded,
            detail: "Update Workbench never controls Terminal or other apps.", settingsURL: automationURL))
        let notifications: PermissionState = probes.notifications.map { $0 ? .granted : .denied } ?? .unknown
        result.append(PermissionCheck(title: "Notifications", state: notifications,
            detail: notifications == .granted ? "Update notifications can be shown when enabled in Settings." : "Enable notifications in Settings, then allow them in System Settings if macOS blocks them.",
            settingsURL: notificationsURL))
        result.append(PermissionCheck(title: "Administrator account", state: probes.isAdmin ? .granted : .denied,
            detail: probes.isAdmin ? "This account is an administrator. Update Workbench still never asks for or stores your password." :
                "Standard account. Apps owned by other users or installers needing administrator rights must be updated by an administrator.",
            settingsURL: nil))
        for destination in probes.destinations {
            result.append(PermissionCheck(title: "Write access: \(destination.path)", state: destination.writable ? .granted : .denied,
                detail: destination.writable ? "Apps here can be replaced directly (subject to each app's own permissions)." :
                    "Your account cannot write here. Direct updates for apps in this folder will fail closed.", settingsURL: nil))
        }
        result.append(PermissionCheck(title: "Launch at login", state: probes.launchAtLogin == "Enabled" ? .granted : (probes.launchAtLogin == "Requires approval" ? .denied : .notNeeded),
            detail: "Login item status: \(probes.launchAtLogin).", settingsURL: loginItemsURL))
        result.append(PermissionCheck(title: "Keychain (proxy password)", state: probes.proxyPasswordStored ? .granted : .notNeeded,
            detail: probes.proxyPasswordStored ? "A proxy password is stored in your login Keychain." : "No proxy password is stored.", settingsURL: nil))
        return result
    }
}

/// Decides which updates deserve a notification. Each item/version is announced once.
enum UpdateNotificationPolicy {
    struct Candidate: Sendable, Equatable { let id: String; let name: String; let version: String }

    static func newlyAvailable(_ updates: [Candidate], alreadyNotified: [String: String]) -> [Candidate] {
        updates.filter { alreadyNotified[$0.id] != $0.version }
    }

    static func record(_ updates: [Candidate], current: [Candidate], into notified: [String: String]) -> [String: String] {
        var result = notified.filter { entry in current.contains { $0.id == entry.key } }
        for update in updates { result[update.id] = update.version }
        return result
    }

    static func availableMessage(_ updates: [Candidate]) -> (title: String, body: String)? {
        guard !updates.isEmpty else { return nil }
        if updates.count == 1 { return ("Update available", "\(updates[0].name) \(updates[0].version) is available.") }
        let names = updates.prefix(3).map(\.name).joined(separator: ", ")
        let more = updates.count > 3 ? " and \(updates.count - 3) more" : ""
        return ("\(updates.count) updates available", names + more + ".")
    }

    static func resultMessage(succeeded: [String], failed: [String]) -> (title: String, body: String)? {
        switch (succeeded.isEmpty, failed.isEmpty) {
        case (true, true): return nil
        case (false, true): return ("Updates complete", "Updated \(succeeded.joined(separator: ", ")).")
        case (true, false): return ("Update failed", "\(failed.joined(separator: ", ")) could not be updated. See Console for details.")
        case (false, false): return ("Updates finished with errors", "Updated \(succeeded.count); failed: \(failed.joined(separator: ", ")).")
        }
    }
}

/// Where Update Workbench looks for its own releases. Disabled by default; there is no published feed.
enum SelfUpdateFeed: Equatable, Sendable {
    case disabled
    case github(String)
    case appcast(URL)

    static let defaultsKey = "selfUpdateFeed"

    static func parse(_ raw: String) throws -> SelfUpdateFeed {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return .disabled }
        if value.lowercased().hasPrefix("github:") {
            let repository = String(value.dropFirst("github:".count))
            guard GitHubBackend.validRepository(repository) else { throw UpdateError.unavailable("Use github:owner/repository.") }
            return .github(repository)
        }
        guard let url = URL(string: value), HTTPFetcher.isSafeHTTPS(url) else {
            throw UpdateError.unavailable("Enter github:owner/repository, a GitHub repository URL, or an HTTPS appcast URL.")
        }
        if url.host?.lowercased() == "github.com" {
            let parts = url.path.split(separator: "/")
            guard parts.count == 2, GitHubBackend.validRepository("\(parts[0])/\(parts[1])") else {
                throw UpdateError.unavailable("Use the repository URL, for example https://github.com/owner/repository.")
            }
            return .github("\(parts[0])/\(parts[1])")
        }
        return .appcast(url)
    }

    var description: String {
        switch self {
        case .disabled: return "Disabled"
        case .github(let repository): return "GitHub Releases: \(repository)"
        case .appcast(let url): return "Appcast: \(url.absoluteString)"
        }
    }
}

enum SelfUpdate {
    /// Checks the configured feed; returns a release only when a single verifiable payload exists.
    static func check(_ feed: SelfUpdateFeed, installedVersion: String) async throws -> SparkleRelease? {
        switch feed {
        case .disabled: throw UpdateError.unavailable("Self-update is disabled. Configure a release feed first.")
        case .appcast(let url): return try await SparkleBackend.check(feedURL: url, installedVersion: installedVersion)
        case .github(let repository):
            guard let release = try await GitHubBackend.check(repository: repository, installedVersion: installedVersion) else { return nil }
            guard let download = release.downloadURL else {
                throw UpdateError.unavailable("Version \(release.version) is available, but no single native macOS ZIP/DMG was found: \(release.releasePageURL.absoluteString)")
            }
            return SparkleRelease(version: release.version, downloadURL: download, releaseNotesURL: release.releasePageURL)
        }
    }
}
