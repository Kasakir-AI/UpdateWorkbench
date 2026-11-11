import Foundation

struct RepositorySuggestion: Codable, Sendable, Hashable {
    let repository: String
    let evidence: String
}

/// Suggests public GitHub repositories from metadata the app or Homebrew publishes.
/// Suggestions are never applied automatically; the user confirms each one.
enum RepositoryDiscovery {
    private static let reservedOwners: Set<String> = [
        "about", "apps", "blog", "collections", "contact", "customer-stories", "enterprise", "events", "explore", "features",
        "join", "login", "marketplace", "new", "notifications", "orgs", "organizations", "pricing", "security", "settings",
        "site", "sponsors", "topics", "trending", "users", "readme", "codespaces", "issues", "pulls", "search"
    ]

    /// Extracts owner/repository from github.com, raw.githubusercontent.com, api.github.com and owner.github.io URLs.
    static func repository(fromURL string: String) -> String? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), url.user == nil else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        var owner: String?, repo: String?
        switch host {
        case "github.com", "www.github.com", "raw.githubusercontent.com":
            if parts.count >= 2 { owner = parts[0]; repo = parts[1] }
        case "api.github.com":
            if parts.count >= 3, parts[0] == "repos" { owner = parts[1]; repo = parts[2] }
        default:
            if host.hasSuffix(".github.io"), let first = parts.first {
                owner = String(host.dropLast(".github.io".count)); repo = first
            }
        }
        guard var owner, var repo else { return nil }
        if repo.lowercased().hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        owner = owner.trimmingCharacters(in: .whitespaces)
        guard !reservedOwners.contains(owner.lowercased()) else { return nil }
        let value = "\(owner)/\(repo)"
        return GitHubBackend.validRepository(value) ? value : nil
    }

    private static func urls(in text: String) -> [String] {
        guard text.localizedCaseInsensitiveContains("github"),
              let expression = try? NSRegularExpression(pattern: #"https?://[^\s"'<>(),]+"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).prefix(20).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    private static func strings(in value: Any, key: String, depth: Int, into output: inout [(String, String)]) {
        guard depth <= 3, output.count < 500 else { return }
        if let text = value as? String { output.append((key, text)) }
        else if let array = value as? [Any] { for element in array.prefix(100) { strings(in: element, key: key, depth: depth + 1, into: &output) } }
        else if let dictionary = value as? [String: Any] {
            for (child, element) in dictionary.sorted(by: { $0.key < $1.key }) { strings(in: element, key: child, depth: depth + 1, into: &output) }
        }
    }

    static func suggestions(info: [String: Any], sparkleFeed: URL?, electron: ElectronUpdateConfig?,
                            extra: [(String, String)] = []) -> [RepositorySuggestion] {
        var found: [RepositorySuggestion] = []
        func add(_ repository: String?, _ evidence: String) {
            guard let repository, !found.contains(where: { $0.repository.caseInsensitiveCompare(repository) == .orderedSame }) else { return }
            found.append(RepositorySuggestion(repository: repository, evidence: evidence))
        }
        if let electron, electron.provider == .github { add(electron.repository, "Electron update configuration (app-update.yml)") }
        if let sparkleFeed { add(repository(fromURL: sparkleFeed.absoluteString), "Sparkle feed URL") }
        for (url, evidence) in extra { add(repository(fromURL: url), evidence) }
        var values: [(String, String)] = []
        strings(in: info, key: "", depth: 0, into: &values)
        for (key, text) in values { for url in urls(in: text) { add(repository(fromURL: url), "Info.plist \(key)") } }
        return Array(found.prefix(5))
    }
}

struct CaskSuggestion: Codable, Sendable, Hashable {
    enum Confidence: String, Codable, Sendable { case high = "High", medium = "Medium" }
    let token: String
    let name: String
    let version: String?
    let confidence: Confidence
    let evidence: String
    let homepage: URL?
}

struct CaskCandidate: Sendable, Equatable {
    var token: String
    var names: [String]
    var appNames: [String]
    var bundleIDs: [String]
    var homepage: String?
    var url: String?
    var version: String?
    var deprecated: Bool
    var disabled: Bool
}

/// Matches installed apps to Homebrew casks using public `brew info --json=v2 --cask` metadata.
enum CaskMatching {
    static func slug(_ value: String) -> String {
        var output = ""
        var previousDash = false
        for scalar in value.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII { output.unicodeScalars.append(scalar); previousDash = false }
            else if scalar == "+" || scalar == "@" { output.unicodeScalars.append(scalar); previousDash = false }
            else if !previousDash && !output.isEmpty { output.append("-"); previousDash = true }
        }
        while output.hasSuffix("-") { output.removeLast() }
        return output
    }

    /// Candidate tokens for a bundle, restricted to known cask tokens so `brew info` never sees unknown names.
    static func candidateTokens(appFileName: String, displayName: String, known: Set<String>) -> [String] {
        let base = appFileName.lowercased().hasSuffix(".app") ? String(appFileName.dropLast(4)) : appFileName
        var raw = [slug(base), slug(displayName), slug(base).replacingOccurrences(of: "-", with: "")]
        for value in raw where value.hasSuffix("-app") { raw.append(String(value.dropLast(4))) }
        if let first = slug(base).split(separator: "-").first, first.count >= 4 { raw.append(String(first)) }
        var seen = Set<String>()
        return raw.filter { !$0.isEmpty && known.contains($0) && seen.insert($0).inserted }
    }

    private static func strings(_ value: Any?) -> [String] {
        if let text = value as? String { return [text] }
        if let array = value as? [Any] { return array.compactMap { $0 as? String } }
        return []
    }

    static func parseCasks(_ data: Data) throws -> [CaskCandidate] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return (root["casks"] as? [[String: Any]] ?? []).compactMap { cask in
            guard let token = cask["token"] as? String else { return nil }
            var appNames: [String] = [], bundleIDs: [String] = []
            for artifact in cask["artifacts"] as? [[String: Any]] ?? [] {
                if let apps = artifact["app"] as? [Any] {
                    for app in apps {
                        if let name = app as? String { appNames.append(URL(fileURLWithPath: name).lastPathComponent) }
                        if let options = app as? [String: Any], let target = options["target"] as? String { appNames.append(URL(fileURLWithPath: target).lastPathComponent) }
                    }
                    if let target = artifact["target"] as? String, target.lowercased().hasSuffix(".app") { appNames.append(URL(fileURLWithPath: target).lastPathComponent) }
                }
                for key in ["uninstall", "zap"] {
                    for directive in artifact[key] as? [[String: Any]] ?? [] {
                        bundleIDs += strings(directive["quit"])
                    }
                }
            }
            return CaskCandidate(token: token, names: strings(cask["name"]), appNames: appNames, bundleIDs: bundleIDs,
                                 homepage: cask["homepage"] as? String, url: cask["url"] as? String,
                                 version: cask["version"] as? String, deprecated: cask["deprecated"] as? Bool ?? false,
                                 disabled: cask["disabled"] as? Bool ?? false)
        }
    }

    static func match(appFileName: String, bundleID: String?, casks: [CaskCandidate]) -> [CaskSuggestion] {
        let file = appFileName.lowercased()
        let suggestions: [CaskSuggestion] = casks.compactMap { cask in
            guard !cask.disabled, cask.appNames.contains(where: { $0.lowercased() == file }) else { return nil }
            let bundleMatch = bundleID.map { id in cask.bundleIDs.contains { $0.caseInsensitiveCompare(id) == .orderedSame } } ?? false
            var evidence = bundleMatch ? "App name \(appFileName) and bundle ID match the cask." : "App name \(appFileName) matches the cask's app artifact."
            if cask.deprecated { evidence += " The cask is deprecated in Homebrew." }
            return CaskSuggestion(token: cask.token, name: cask.names.first ?? cask.token,
                                  version: cask.version.map { String($0.split(separator: ",").first ?? Substring($0)) },
                                  confidence: bundleMatch ? .high : .medium, evidence: evidence,
                                  homepage: cask.homepage.flatMap(URL.init(string:)))
        }
        return suggestions.sorted { ($0.confidence == .high ? 0 : 1, $0.token) < ($1.confidence == .high ? 0 : 1, $1.token) }
    }
}

struct VendorUpdater: Codable, Sendable, Hashable {
    let name: String
    let instructions: String
    /// An installed vendor updater application to open; nil means open the app itself.
    let launchPath: String?
}

/// Recognizes apps that ship their own public updater. Only opens the vendor's tool or the app;
/// private vendor protocols are not driven.
enum VendorUpdaters {
    static let microsoftAutoUpdate = "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app"
    static let adobeCreativeCloud = ["/Applications/Utilities/Adobe Creative Cloud/ACC/Creative Cloud.app",
                                     "/Applications/Adobe Creative Cloud/Adobe Creative Cloud.app"]

    static func detect(bundleID: String?, info: [String: Any], appURL: URL,
                       exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> VendorUpdater? {
        let id = bundleID?.lowercased() ?? ""
        if id.hasPrefix("com.microsoft."), !["com.microsoft.vscode", "com.microsoft.vscodeinsiders"].contains(id) {
            if exists(microsoftAutoUpdate) {
                return VendorUpdater(name: "Microsoft AutoUpdate", instructions: "Microsoft updates this app through Microsoft AutoUpdate.", launchPath: microsoftAutoUpdate)
            }
        }
        if id.hasPrefix("com.adobe.") {
            if id.hasPrefix("com.adobe.reader") || id.hasPrefix("com.adobe.acrobat") {
                return VendorUpdater(name: "Adobe Acrobat updater", instructions: "Open the app and choose Help → Check for Updates.", launchPath: nil)
            }
            if let path = adobeCreativeCloud.first(where: exists) {
                return VendorUpdater(name: "Adobe Creative Cloud", instructions: "Adobe apps are updated from the Creative Cloud desktop app (Apps → Updates).", launchPath: path)
            }
            return VendorUpdater(name: "Adobe updater", instructions: "Adobe manages this app's updates. Install or open the Creative Cloud desktop app, or use the app's Help menu.", launchPath: nil)
        }
        if info["KSProductID"] != nil || info["KSUpdateURL"] != nil {
            return VendorUpdater(name: "Google Software Update", instructions: "Google's built-in updater keeps this app current. Open the app and check its About screen.", launchPath: nil)
        }
        if exists(appURL.appendingPathComponent("Contents/MacOS/updater.app").path) {
            return VendorUpdater(name: "Built-in Mozilla updater", instructions: "Open the app and choose its About window to download updates.", launchPath: nil)
        }
        if exists(appURL.appendingPathComponent("Contents/Frameworks/Squirrel.framework").path) {
            return VendorUpdater(name: "Built-in Electron updater (Squirrel.Mac)", instructions: "This Electron app configures its update feed inside its own code, so it is not publicly declared. Open the app to let it update itself.", launchPath: nil)
        }
        if exists(appURL.appendingPathComponent("Contents/Frameworks/Sparkle.framework").path) {
            return VendorUpdater(name: "Built-in Sparkle updater", instructions: "This app includes Sparkle but does not declare its feed in Info.plist. Use the app's Check for Updates command, or add its appcast as a custom feed.", launchPath: nil)
        }
        return nil
    }
}
