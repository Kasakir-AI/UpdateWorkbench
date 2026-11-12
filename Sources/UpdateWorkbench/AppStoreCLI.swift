import Foundation

/// The optional `mas` command-line tool for Mac App Store apps: detection, parsing of `mas outdated`,
/// matching to installed apps and readable errors. Only `outdated` runs during checks; `update` runs
/// only after the user confirms an update.
enum AppStoreCLI {
    static let candidates = ["/opt/homebrew/bin/mas", "/usr/local/bin/mas"]

    /// Looked up on every check, so installing mas while the app runs takes effect on the next check.
    static func locate(fileManager: FileManager = .default) -> String? {
        candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    struct OutdatedApp: Equatable, Sendable {
        var adamID: String
        var name: String
        var bundleID: String?
        var path: String?
        var installedVersion: String
        var latestVersion: String
    }

    /// Parses `mas outdated --json` (one JSON object per line) and, for older mas versions,
    /// the text form `123456789  Name  (1.0 -> 1.1)`.
    static func parseOutdated(_ output: String) -> [OutdatedApp] {
        var apps: [OutdatedApp] = []
        let legacy = try! NSRegularExpression(pattern: #"^\s*(\d+)\s+(.+?)\s+\((.+?)\s+(?:->|→)\s+(.+?)\)\s*$"#)
        for raw in output.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("{"), let data = line.data(using: .utf8),
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                func string(_ keys: String...) -> String? {
                    for key in keys {
                        if let value = object[key] as? String, !value.isEmpty { return value }
                        if let value = object[key] as? NSNumber { return value.stringValue }
                    }
                    return nil
                }
                guard let id = string("adamID", "kMDItemAppStoreAdamID"), id.allSatisfy(\.isNumber), id != "0",
                      let latest = string("newVersion") else { continue }
                let path = string("path", "kMDItemPath")
                let name = string("name", "displayName") ?? path.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "App \(id)"
                apps.append(OutdatedApp(adamID: id, name: name, bundleID: string("bundleID", "kMDItemCFBundleIdentifier"), path: path,
                                        installedVersion: string("version", "kMDItemVersion") ?? "Unknown", latestVersion: latest))
                continue
            }
            let range = NSRange(line.startIndex..., in: line)
            guard let match = legacy.firstMatch(in: line, range: range) else { continue }
            func field(_ index: Int) -> String { Range(match.range(at: index), in: line).map { String(line[$0]).trimmingCharacters(in: .whitespaces) } ?? "" }
            apps.append(OutdatedApp(adamID: field(1), name: field(2), bundleID: nil, path: nil, installedVersion: field(3), latestVersion: field(4)))
        }
        return apps
    }

    /// Index of the installed app an outdated entry belongs to: same path, then bundle ID, then name.
    static func match(_ app: OutdatedApp, in items: [UpdateItem]) -> Int? {
        func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }
        if let path = app.path {
            let target = canonical(path)
            if let index = items.firstIndex(where: { $0.path.map(canonical) == target }) { return index }
        }
        if let bundleID = app.bundleID, !bundleID.isEmpty,
           let index = items.firstIndex(where: { $0.bundleID == bundleID && $0.path != nil }) { return index }
        return items.firstIndex { $0.provider == .appStore && $0.name.caseInsensitiveCompare(app.name) == .orderedSame }
    }

    enum Problem: Equatable, Sendable {
        case notSignedIn
        case needsAdministrator
        case network
        case other
    }

    static func classify(_ text: String) -> Problem {
        let lower = text.lowercased()
        if lower.contains("not signed in") || lower.contains("sign in") || lower.contains("signed out") || lower.contains("apple account")
            || lower.contains("authenticat") || lower.contains("no account") { return .notSignedIn }
        if lower.contains("sudo") || lower.contains("password") || lower.contains("root privileges") || lower.contains("terminal is required")
            || lower.contains("not permitted") && lower.contains("installer") { return .needsAdministrator }
        if lower.contains("nsurlerrordomain") || lower.contains("timed out") || lower.contains("offline") || lower.contains("network") { return .network }
        return .other
    }

    /// A readable sentence for a failed mas command, with the useful part of its output.
    static func message(for text: String, action: String) -> String {
        switch classify(text) {
        case .notSignedIn:
            return "mas couldn't \(action) because you aren't signed in to the App Store. Open the App Store app, sign in, then try again."
        case .needsAdministrator:
            return "macOS needs an administrator password to finish this App Store update. Choose “Finish in Terminal” to run mas there (it asks for your password), or update it in the App Store app."
        case .network:
            return "mas couldn't reach the App Store (the request timed out). Check your connection and try again."
        case .other:
            let detail = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.prefix(3).joined(separator: " ")
            return "mas couldn't \(action)" + (detail.isEmpty ? "." : ": \(String(detail.prefix(300)))")
        }
    }

    /// App Store IDs are numbers only; nothing else is ever passed to mas or Terminal.
    static func validID(_ id: String?) -> Bool {
        guard let id, !id.isEmpty, id.count <= 12 else { return false }
        return id.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Shell script used by “Finish in Terminal”, where mas can ask for the administrator password itself.
    static func terminalScript(mas: String, adamID: String, name: String) -> String? {
        guard validID(adamID), candidates.contains(mas) else { return nil }
        let safeName = name.filter { $0.isLetter || $0.isNumber || " .-+".contains($0) }
        return """
        #!/bin/zsh
        echo "Updating \(safeName) from the App Store with mas. macOS may ask for your administrator password."
        '\(mas)' update \(adamID)
        status=$?
        echo
        if [ $status -eq 0 ]; then echo "Done. Check for updates again in Update Workbench."; else echo "mas exited with status $status."; fi
        rm -f -- "$0"
        """
    }
}
