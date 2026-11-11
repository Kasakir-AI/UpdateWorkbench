import AppKit
import Foundation
import Darwin

enum UpdateProvider: String, Codable, CaseIterable, Sendable {
    case homebrewCask = "Homebrew app"
    case homebrewFormula = "Homebrew package"
    case appStore = "App Store"
    case sparkle = "Sparkle"
    case github = "GitHub"
    case electron = "Electron"
    case vendor = "Vendor updater"
    case manual = "Manual"
}

struct UpdateItem: Identifiable, Codable, Sendable, Hashable {
    var id: String
    var name: String
    var bundleID: String?
    var path: String?
    var installedVersion: String
    var latestVersion: String?
    var provider: UpdateProvider
    var token: String?
    var feedURL: URL?
    var homepage: URL?
    var isOutdated: Bool
    var detail: String
    var sparkleRelease: SparkleRelease?
    var githubRepository: String?
    var githubRelease: GitHubRelease?
    var requiresSparkleSignature: Bool?
    var electronUpdate: ElectronUpdateConfig?
    var vendorUpdater: VendorUpdater?
    var repositorySuggestions: [RepositorySuggestion]?
    var caskSuggestions: [CaskSuggestion]?
    var isPinned: Bool?

    init(id: String, name: String, bundleID: String? = nil, path: String? = nil,
         installedVersion: String, latestVersion: String? = nil,
         provider: UpdateProvider = .manual, token: String? = nil,
         feedURL: URL? = nil, homepage: URL? = nil, isOutdated: Bool = false,
         detail: String = "", sparkleRelease: SparkleRelease? = nil,
         githubRepository: String? = nil, githubRelease: GitHubRelease? = nil, requiresSparkleSignature: Bool? = nil,
         electronUpdate: ElectronUpdateConfig? = nil, vendorUpdater: VendorUpdater? = nil,
         repositorySuggestions: [RepositorySuggestion]? = nil, caskSuggestions: [CaskSuggestion]? = nil, isPinned: Bool? = nil) {
        self.id = id; self.name = name; self.bundleID = bundleID; self.path = path
        self.installedVersion = installedVersion; self.latestVersion = latestVersion
        self.provider = provider; self.token = token; self.feedURL = feedURL
        self.homepage = homepage; self.isOutdated = isOutdated; self.detail = detail
        self.sparkleRelease = sparkleRelease
        self.githubRepository = githubRepository; self.githubRelease = githubRelease
        self.requiresSparkleSignature = requiresSparkleSignature
        self.electronUpdate = electronUpdate; self.vendorUpdater = vendorUpdater
        self.repositorySuggestions = repositorySuggestions; self.caskSuggestions = caskSuggestions
        self.isPinned = isPinned
    }

    var canUpdateDirectly: Bool {
        switch provider {
        case .homebrewCask, .homebrewFormula, .appStore: return token != nil && isOutdated
        case .sparkle: return sparkleRelease != nil && path != nil && isOutdated
        case .github: return githubRelease?.downloadURL != nil && path != nil && isOutdated && requiresSparkleSignature != true
        case .electron: return sparkleRelease?.sha512 != nil && path != nil && isOutdated && requiresSparkleSignature != true
        case .vendor, .manual: return false
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct CommandResult: Sendable {
    let output: String
    let errorOutput: String
    let status: Int32
}

enum UpdateError: LocalizedError {
    case unavailable(String)
    case command(String, String, Int32)
    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .command(let command, let output, let status):
            return "\(command) exited with status \(status).\n\(output)"
        }
    }
}

enum CommandRunner {
    /// Arguments go directly to exec. File-backed capture cannot block on inherited pipes.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 180) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let fm = FileManager.default
                let directory = fm.temporaryDirectory.appendingPathComponent("UpdateWorkbenchCommand-\(UUID().uuidString)", isDirectory: true)
                do {
                    try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    defer { try? fm.removeItem(at: directory) }
                    let outputURL = directory.appendingPathComponent("stdout")
                    let errorsURL = directory.appendingPathComponent("stderr")
                    guard fm.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                          fm.createFile(atPath: errorsURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                        throw UpdateError.unavailable("Unable to create temporary command output files.")
                    }
                    let output = try FileHandle(forWritingTo: outputURL)
                    let errors = try FileHandle(forWritingTo: errorsURL)
                    defer { try? output.close(); try? errors.close() }
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments
                    process.standardInput = FileHandle.nullDevice
                    process.standardOutput = output
                    process.standardError = errors
                    var environment = ProcessInfo.processInfo.environment
                    environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                    environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
                    environment["HOMEBREW_NO_ANALYTICS"] = "1"
                    environment["NONINTERACTIVE"] = "1"
                    environment.merge(ProxySettings.load().commandEnvironment()) { _, proxy in proxy }
                    process.environment = environment
                    let maximumBytes: UInt64 = 64 * 1024 * 1024
                    func capturedSize() -> UInt64 {
                        [outputURL, errorsURL].reduce(UInt64(0)) { total, url in
                            total + ((try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0)
                        }
                    }
                    try process.run()
                    let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
                    var failure: String?
                    var terminateAt: TimeInterval?
                    var sentKill = false
                    // All timeout decisions stay on this owner thread. No delayed callback can
                    // fire after completion and target a recycled process identifier.
                    while process.isRunning {
                        let now = ProcessInfo.processInfo.systemUptime
                        if failure == nil {
                            if now >= deadline { failure = "Command timed out after \(timeout) seconds." }
                            else if capturedSize() > maximumBytes { failure = "Command output exceeded the 64 MiB capture limit." }
                            if failure != nil && process.isRunning {
                                process.terminate()
                                terminateAt = now
                            }
                        }
                        if let terminateAt, now - terminateAt >= 1, !sentKill, process.isRunning {
                            // Kill only this still-running owned Process, never a process group.
                            _ = Darwin.kill(process.processIdentifier, SIGKILL)
                            sentKill = true
                        }
                        Thread.sleep(forTimeInterval: 0.025)
                    }
                    process.waitUntilExit()
                    try? output.close(); try? errors.close()
                    if let failure {
                        throw UpdateError.unavailable("\(failure) The owned command has exited. Subprocesses may still be running; check the installation state before retrying.")
                    }
                    guard capturedSize() <= maximumBytes else {
                        throw UpdateError.unavailable("Command output exceeded the 64 MiB capture limit; output was not loaded.")
                    }
                    func readBounded(_ url: URL, allowance: Int) throws -> Data {
                        let handle = try FileHandle(forReadingFrom: url)
                        defer { try? handle.close() }
                        var bytes = Data()
                        while true {
                            let chunk = try handle.read(upToCount: min(1_048_576, allowance - bytes.count + 1)) ?? Data()
                            if chunk.isEmpty { break }
                            guard bytes.count + chunk.count <= allowance else {
                                throw UpdateError.unavailable("Command output exceeded the 64 MiB capture limit while reading.")
                            }
                            bytes.append(chunk)
                        }
                        return bytes
                    }
                    let bytes = try readBounded(outputURL, allowance: Int(maximumBytes))
                    let errorBytes = try readBounded(errorsURL, allowance: Int(maximumBytes) - bytes.count)
                    continuation.resume(returning: CommandResult(
                        output: String(decoding: bytes, as: UTF8.self),
                        errorOutput: String(decoding: errorBytes, as: UTF8.self), status: process.terminationStatus))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

actor Engine {
    private var diagnostics: [String] = []
    private let brewPath: String?
    private let masPath: String?

    init() {
        brewPath = Self.executable(["/opt/homebrew/bin/brew", "/usr/local/bin/brew"])
        masPath = Self.executable(["/opt/homebrew/bin/mas", "/usr/local/bin/mas"])
    }

    func lastDiagnostics() -> [String] { diagnostics }

    /// Refresh package metadata without installing or upgrading packages.
    func refreshHomebrewCatalog() async throws -> String {
        guard let brewPath else { throw UpdateError.unavailable("Homebrew is not installed.") }
        return try await execute(brewPath, ["update"])
    }

    /// Maintenance actions are deliberately enumerated; arbitrary commands are never accepted.
    func maintenance(_ action: String) async throws -> String {
        guard let brewPath else { throw UpdateError.unavailable("Homebrew is not installed.") }
        switch action {
        case "cleanup": return try await execute(brewPath, ["cleanup"])
        case "doctor": return try await execute(brewPath, ["doctor"])
        default: throw UpdateError.unavailable("Unknown Homebrew maintenance action: \(action)")
        }
    }

    func adoptCask(token: String) async throws -> String {
        guard let brewPath else { throw UpdateError.unavailable("Homebrew is not installed.") }
        guard Self.validToken(token) else { throw UpdateError.unavailable("Enter a valid Homebrew cask token.") }
        return try await execute(brewPath, ["install", "--cask", "--adopt", token])
    }

    func scan() async -> [UpdateItem] {
        diagnostics = []
        var items = Self.installedApps()
        if let brewPath {
            do { try await mergeHomebrew(executable: brewPath, items: &items) }
            catch { diagnostics.append("Homebrew: \(error.localizedDescription)") }
        } else { diagnostics.append("Homebrew is not installed. Homebrew updates are unavailable.") }
        if let masPath {
            do { try await mergeAppStore(executable: masPath, items: &items) }
            catch { diagnostics.append("App Store: \(error.localizedDescription)") }
        } else if items.contains(where: { $0.provider == .appStore }) {
            diagnostics.append("Install the optional mas command-line tool to check and update App Store apps directly.")
        }
        // Keep requests bounded and preserve failures as unknown, never as up-to-date.
        let feedIndices = items.indices.filter { items[$0].provider == .sparkle && items[$0].feedURL != nil }
        for start in stride(from: 0, to: feedIndices.count, by: 6) {
            let batch = feedIndices[start..<min(start + 6, feedIndices.count)].map {
                ($0, items[$0].feedURL!, items[$0].installedVersion)
            }
            let results = await withTaskGroup(of: (Int, SparkleRelease?, String?).self) { group in
                for (index, feed, version) in batch {
                    group.addTask {
                        do { return (index, try await SparkleBackend.check(feedURL: feed, installedVersion: version), nil) }
                        catch { return (index, nil, error.localizedDescription) }
                    }
                }
                var values: [(Int, SparkleRelease?, String?)] = []
                for await value in group { values.append(value) }
                return values
            }
            for (index, release, error) in results {
                if let error {
                    items[index].detail = "Feed check failed: \(error)"
                    diagnostics.append("\(items[index].name): \(error)")
                } else if let release {
                    items[index].latestVersion = release.version
                    items[index].sparkleRelease = release
                    items[index].isOutdated = true
                    items[index].detail = "Update available from the app's Sparkle feed. Installation verifies bundle identity and signing team."
                } else { items[index].detail = "No compatible newer release found in the Sparkle feed." }
            }
        }
        // Electron apps that publicly declare an electron-updater feed in app-update.yml.
        let electronIndices = items.indices.filter { items[$0].provider == .electron && items[$0].electronUpdate != nil }
        for start in stride(from: 0, to: electronIndices.count, by: 6) {
            let batch = electronIndices[start..<min(start + 6, electronIndices.count)].map {
                ($0, items[$0].electronUpdate!, items[$0].installedVersion)
            }
            let results = await withTaskGroup(of: (Int, ElectronCheckResult?, String?).self) { group in
                for (index, config, version) in batch {
                    group.addTask {
                        do { return (index, try await ElectronBackend.check(config: config, installedVersion: version), nil) }
                        catch { return (index, nil, error.localizedDescription) }
                    }
                }
                var values: [(Int, ElectronCheckResult?, String?)] = []
                for await value in group { values.append(value) }
                return values
            }
            for (index, result, error) in results {
                if let error {
                    items[index].detail = "Electron update check failed: \(error)"
                    diagnostics.append("\(items[index].name): \(error)")
                } else if let result {
                    items[index].latestVersion = result.version
                    items[index].sparkleRelease = result.release
                    items[index].isOutdated = true
                    if let page = result.releasePage { items[index].homepage = page }
                    items[index].detail = items[index].requiresSparkleSignature == true
                        ? "Electron update available. This app requires a Sparkle archive signature; use its own updater." : result.note
                } else { items[index].detail = "No newer stable release found in the app's Electron update feed." }
            }
        }
        // Explicit GitHub repositories supplement apps without a package-manager route.
        let githubIndices = items.indices.filter { items[$0].provider == .github && items[$0].githubRepository != nil }
        for start in stride(from: 0, to: githubIndices.count, by: 6) {
            let batch = githubIndices[start..<min(start + 6, githubIndices.count)].map {
                ($0, items[$0].githubRepository!, items[$0].installedVersion)
            }
            let results = await withTaskGroup(of: (Int, GitHubRelease?, String?).self) { group in
                for (index, repository, version) in batch {
                    group.addTask {
                        do { return (index, try await GitHubBackend.check(repository: repository, installedVersion: version), nil) }
                        catch { return (index, nil, error.localizedDescription) }
                    }
                }
                var values: [(Int, GitHubRelease?, String?)] = []
                for await value in group { values.append(value) }
                return values
            }
            for (index, release, error) in results {
                if let error {
                    items[index].detail = "GitHub check failed: \(error)"
                    diagnostics.append("\(items[index].name): \(error)")
                } else if let release {
                    items[index].latestVersion = release.version
                    items[index].githubRelease = release
                    items[index].homepage = release.releasePageURL
                    items[index].isOutdated = true
                    if items[index].requiresSparkleSignature == true {
                        items[index].detail = "GitHub release available. This app requires a Sparkle archive signature; use its signed feed or vendor updater."
                    } else if release.downloadURL == nil {
                        items[index].detail = "GitHub release available. No single clearly native macOS payload was identified; choose a download on the release page."
                    } else {
                        items[index].detail = "GitHub release available from your configured repository. Direct installation verifies the app bundle, signing team, Gatekeeper, version and native CPU."
                    }
                } else { items[index].detail = "No newer stable GitHub release found." }
            }
        }
        return items.sorted {
            if $0.isOutdated != $1.isOutdated { return $0.isOutdated }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func update(_ item: UpdateItem) async throws -> String {
        guard item.canUpdateDirectly else { throw UpdateError.unavailable("No verified direct update is available for \(item.name).") }
        if let bundleID = item.bundleID,
           !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            throw UpdateError.unavailable("Quit \(item.name) before updating it, then try again.")
        }
        switch item.provider {
        case .homebrewCask, .homebrewFormula:
            guard let brewPath else {
                throw UpdateError.unavailable("Homebrew or the package identifier is unavailable.")
            }
            let args = try Self.homebrewArguments(for: item)
            return try await execute(brewPath, args)
        case .appStore:
            guard let masPath, let token = item.token, token.allSatisfy(\.isNumber), !token.isEmpty else {
                throw UpdateError.unavailable("The mas helper or App Store identifier is unavailable.")
            }
            return try await execute(masPath, ["upgrade", token])
        case .sparkle:
            guard let release = item.sparkleRelease, let path = item.path else {
                throw UpdateError.unavailable("The Sparkle release or destination is unavailable.")
            }
            return try await SparkleBackend.install(release: release, target: URL(fileURLWithPath: path))
        case .github:
            guard let release = item.githubRelease, let download = release.downloadURL, let path = item.path,
                  item.requiresSparkleSignature != true else {
                throw UpdateError.unavailable("This GitHub release requires manual installation or the app's signed Sparkle feed.")
            }
            return try await SparkleBackend.install(
                release: SparkleRelease(version: release.version, downloadURL: download, releaseNotesURL: release.releasePageURL),
                target: URL(fileURLWithPath: path))
        case .electron:
            guard let release = item.sparkleRelease, release.sha512 != nil, let path = item.path else {
                throw UpdateError.unavailable("No verifiable Electron payload is available; open the app to use its own updater.")
            }
            return try await SparkleBackend.install(release: release, target: URL(fileURLWithPath: path))
        case .vendor, .manual: throw UpdateError.unavailable("This app requires its own updater.")
        }
    }

    /// Reinstall, uninstall or unpin a Homebrew item after explicit user confirmation in the UI.
    func manage(_ action: HomebrewAction, item: UpdateItem) async throws -> String {
        guard let brewPath else { throw UpdateError.unavailable("Homebrew is not installed.") }
        if action != .unpin, let bundleID = item.bundleID,
           !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            throw UpdateError.unavailable("Quit \(item.name) before changing its installation.")
        }
        return try await execute(brewPath, try HomebrewAction.arguments(action, for: item))
    }

    /// Moves a non-Homebrew app bundle to the Trash (recoverable), never deleting it.
    func moveToTrash(_ item: UpdateItem) async throws -> String {
        guard let path = item.path else { throw UpdateError.unavailable("This item has no application bundle.") }
        guard item.provider != .homebrewCask else { throw UpdateError.unavailable("Use Homebrew Uninstall for Homebrew-managed apps.") }
        let running = await MainActor.run { NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path } }
        let url = try AppRemoval.validate(path: path, runningBundlePaths: running, selfPath: Bundle.main.bundlePath)
        return try AppRemoval.moveToTrash(url, trash: AppRemoval.systemTrash)
    }

    /// Read-only matching of non-Homebrew apps to casks. Uses `brew casks` and `brew info --json=v2 --cask`;
    /// never runs `brew update` or changes installations.
    func caskSuggestions(for items: [UpdateItem]) async throws -> [String: [CaskSuggestion]] {
        guard let brewPath else { throw UpdateError.unavailable("Homebrew is not installed.") }
        let list = try await CommandRunner.run(brewPath, ["casks"], timeout: 60)
        guard list.status == 0 else { throw UpdateError.command("brew casks", list.errorOutput, list.status) }
        var known = Set(list.output.split(whereSeparator: \.isNewline).map(String.init).filter(Self.validToken))
        for item in items where item.provider == .homebrewCask { if let token = item.token { known.remove(token) } }
        let apps = items.filter { $0.path != nil && ![.homebrewCask, .homebrewFormula, .appStore].contains($0.provider) }
        var tokensByItem: [String: [String]] = [:]
        for app in apps {
            let file = URL(fileURLWithPath: app.path!).lastPathComponent
            let tokens = CaskMatching.candidateTokens(appFileName: file, displayName: app.name, known: known)
            if !tokens.isEmpty { tokensByItem[app.id] = tokens }
        }
        let allTokens = Array(Set(tokensByItem.values.joined())).sorted()
        var casks: [CaskCandidate] = []
        for start in stride(from: 0, to: allTokens.count, by: 40) {
            let batch = Array(allTokens[start..<min(start + 40, allTokens.count)])
            let result = try await CommandRunner.run(brewPath, ["info", "--json=v2", "--cask"] + batch, timeout: 180)
            guard result.status == 0 else { diagnostics.append("Homebrew cask lookup failed: \(result.errorOutput.prefix(500))"); continue }
            casks += try CaskMatching.parseCasks(Data(result.output.utf8))
        }
        var output: [String: [CaskSuggestion]] = [:]
        for app in apps {
            guard let tokens = tokensByItem[app.id] else { continue }
            let relevant = casks.filter { tokens.contains($0.token) }
            let matches = CaskMatching.match(appFileName: URL(fileURLWithPath: app.path!).lastPathComponent, bundleID: app.bundleID, casks: relevant)
            if !matches.isEmpty { output[app.id] = matches }
        }
        return output
    }

    static func homebrewArguments(for item: UpdateItem) throws -> [String] {
        guard let token = item.token, validToken(token) else { throw UpdateError.unavailable("Invalid Homebrew package identifier.") }
        if item.provider == .homebrewFormula { return ["upgrade", "--formula", token] }
        guard item.provider == .homebrewCask else { throw UpdateError.unavailable("This item is not managed by Homebrew.") }
        var arguments = ["upgrade", "--cask", "--greedy"]
        if let path = item.path {
            guard path.hasPrefix("/"), !path.contains("\0"), URL(fileURLWithPath: path).pathExtension.lowercased() == "app" else {
                throw UpdateError.unavailable("The installed application's destination is invalid.")
            }
            arguments.append("--appdir=\(URL(fileURLWithPath: path).deletingLastPathComponent().path)")
        }
        arguments.append(token)
        return arguments
    }

    private func execute(_ executable: String, _ args: [String]) async throws -> String {
        let result = try await CommandRunner.run(executable, args, timeout: 1800)
        let text = result.output + result.errorOutput
        guard result.status == 0 else { throw UpdateError.command(([executable] + args).joined(separator: " "), text, result.status) }
        return text.isEmpty ? "Update completed." : text
    }

    private static func executable(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func validToken(_ token: String) -> Bool {
        let segments = token.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count == 1 || segments.count == 3,
              !token.lowercased().hasSuffix(".rb") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@+._-")
        return segments.allSatisfy { segment in
            guard let first = segment.unicodeScalars.first, CharacterSet.alphanumerics.contains(first) else { return false }
            return segment.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }

    static func installedApps() -> [UpdateItem] {
        let fm = FileManager.default
        let defaults = UserDefaults.standard
        let customRoots = defaults.stringArray(forKey: "customRoots") ?? []
        let feedOverrides = defaults.dictionary(forKey: "feedOverrides") as? [String: String] ?? [:]
        let githubOverrides = defaults.dictionary(forKey: "githubOverrides") as? [String: String] ?? [:]
        let candidates = [URL(fileURLWithPath: "/Applications"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
            + customRoots.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        var seenRoots = Set<String>()
        let roots = candidates.filter { seenRoots.insert($0.resolvingSymlinksInPath().standardizedFileURL.path).inserted }
        var items: [UpdateItem] = [], seen = Set<String>()
        for root in roots {
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "app" else { continue }
                enumerator.skipDescendants()
                let canonicalPath = url.resolvingSymlinksInPath().path
                guard seen.insert(canonicalPath).inserted,
                      let bundle = Bundle(url: url), let info = bundle.infoDictionary else { continue }
                let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent
                let version = info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String ?? "Unknown"
                let override = bundle.bundleIdentifier.flatMap { feedOverrides[$0] } ?? feedOverrides[canonicalPath]
                let feed = (override ?? (info["SUFeedURL"] as? String)).flatMap(URL.init(string:)).flatMap {
                    $0.scheme?.lowercased() == "https" && $0.host != nil && $0.user == nil && $0.password == nil ? $0 : nil
                }
                let appStore = fm.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path)
                let repository = bundle.bundleIdentifier.flatMap { githubOverrides[$0] } ?? githubOverrides[canonicalPath]
                let validRepository = repository.flatMap { GitHubBackend.validRepository($0) ? $0 : nil }
                let electron = (appStore || validRepository != nil || feed != nil) ? nil : ElectronBackend.readConfig(appURL: url)
                let vendor = (appStore || validRepository != nil || feed != nil || electron != nil) ? nil
                    : VendorUpdaters.detect(bundleID: bundle.bundleIdentifier, info: info, appURL: url)
                let provider: UpdateProvider = appStore ? .appStore : (validRepository != nil ? .github : (feed != nil ? .sparkle : (electron != nil ? .electron : (vendor != nil ? .vendor : .manual))))
                let detail: String
                switch provider {
                case .appStore: detail = "App Store receipt found; checking requires mas."
                case .github: detail = "Explicit GitHub repository configured."
                case .sparkle: detail = "Sparkle feed found."
                case .electron: detail = "Electron update feed declared (\(electron!.summary))."
                case .vendor: detail = "\(vendor!.name): \(vendor!.instructions)"
                default: detail = "No supported update feed found. Open the app to use its own updater."
                }
                let suggestions = validRepository != nil ? [] : RepositoryDiscovery.suggestions(info: info, sparkleFeed: feed, electron: electron)
                items.append(UpdateItem(id: canonicalPath, name: name, bundleID: bundle.bundleIdentifier,
                                        path: url.path, installedVersion: version, provider: provider, feedURL: feed,
                                        detail: detail, githubRepository: validRepository, requiresSparkleSignature: info["SUPublicEDKey"] is String,
                                        electronUpdate: electron, vendorUpdater: vendor,
                                        repositorySuggestions: suggestions.isEmpty ? nil : suggestions))
            }
        }
        return items
    }

    private func mergeHomebrew(executable: String, items: inout [UpdateItem]) async throws {
        let info = try await CommandRunner.run(executable, ["info", "--json=v2", "--installed"])
        guard info.status == 0 else { throw UpdateError.command("brew info", info.errorOutput, info.status) }
        guard let root = try JSONSerialization.jsonObject(with: Data(info.output.utf8)) as? [String: Any] else { return }
        let outdated = try await CommandRunner.run(executable, ["outdated", "--json=v2", "--greedy"])
        // brew outdated can return 1 when updates exist; parse successful JSON rather than treating that as a scan failure.
        let stale = (try? JSONSerialization.jsonObject(with: Data(outdated.output.utf8))) as? [String: Any]
        if stale == nil { diagnostics.append("Homebrew outdated check failed: \(outdated.errorOutput)") }
        let caskUpdates = Dictionary((stale?["casks"] as? [[String: Any]] ?? []).compactMap { row -> (String, String)? in
            guard let name = row["name"] as? String ?? row["token"] as? String else { return nil }
            return (name, row["current_version"] as? String ?? "Available")
        }, uniquingKeysWith: { _, new in new })
        let formulaUpdates = Dictionary((stale?["formulae"] as? [[String: Any]] ?? []).compactMap { row -> (String, String)? in
            guard let name = row["name"] as? String else { return nil }
            return (name, row["current_version"] as? String ?? "Available")
        }, uniquingKeysWith: { _, new in new })
        for cask in root["casks"] as? [[String: Any]] ?? [] {
            guard let token = cask["token"] as? String, Self.validToken(token) else { continue }
            let name = (cask["name"] as? [String])?.first ?? token
            let installed = (cask["installed"] as? String) ?? (cask["installed"] as? [String])?.first ?? "Unknown"
            let latest = caskUpdates[token]
            let homepage = (cask["homepage"] as? String).flatMap(URL.init(string:))
            var appNames = Set<String>()
            for artifact in cask["artifacts"] as? [[String: Any]] ?? [] {
                if let app = (artifact["app"] as? [Any])?.first as? String { appNames.insert(URL(fileURLWithPath: app).lastPathComponent.lowercased()) }
            }
            let index = items.firstIndex { item in
                guard let path = item.path else { return false }
                return appNames.contains(URL(fileURLWithPath: path).lastPathComponent.lowercased())
            }
            if let index {
                items[index].provider = .homebrewCask; items[index].token = token
                items[index].latestVersion = latest; items[index].isOutdated = latest != nil
                items[index].homepage = homepage
                let caskSources = [(cask["homepage"] as? String, "Homebrew cask homepage"), (cask["url"] as? String, "Homebrew cask download URL")]
                    .compactMap { value, evidence in value.map { ($0, evidence) } }
                let caskRepositories = RepositoryDiscovery.suggestions(info: [:], sparkleFeed: nil, electron: nil, extra: caskSources)
                if !caskRepositories.isEmpty {
                    let existing = items[index].repositorySuggestions ?? []
                    items[index].repositorySuggestions = existing + caskRepositories.filter { new in !existing.contains { $0.repository == new.repository } }
                }
                items[index].detail = stale == nil ? "Homebrew-managed app; update status unknown." : "Managed by Homebrew cask \(token)."
            } else {
                items.append(UpdateItem(id: "cask:\(token)", name: name, installedVersion: installed,
                                        latestVersion: latest, provider: .homebrewCask, token: token,
                                        homepage: homepage, isOutdated: latest != nil,
                                        detail: "Homebrew cask \(token); no application bundle matched."))
            }
        }
        for formula in root["formulae"] as? [[String: Any]] ?? [] {
            guard let name = formula["name"] as? String, Self.validToken(name) else { continue }
            let token = formula["full_name"] as? String ?? name
            let installed = (formula["installed"] as? [[String: Any]])?.compactMap { $0["version"] as? String }.joined(separator: ", ") ?? "Unknown"
            let latest = formulaUpdates[name] ?? formulaUpdates[token]
            items.append(UpdateItem(id: "formula:\(token)", name: name, installedVersion: installed,
                                    latestVersion: latest, provider: .homebrewFormula, token: token,
                                    homepage: (formula["homepage"] as? String).flatMap(URL.init(string:)),
                                    isOutdated: latest != nil, detail: (formula["pinned"] as? Bool == true ? "Pinned. " : "") + (stale == nil ? "Homebrew update status unknown." : "Homebrew formula \(token)."),
                                    isPinned: formula["pinned"] as? Bool))
        }
    }

    private func mergeAppStore(executable: String, items: inout [UpdateItem]) async throws {
        let result = try await CommandRunner.run(executable, ["outdated"])
        guard result.status == 0 else { throw UpdateError.command("mas outdated", result.errorOutput, result.status) }
        let pattern = #"^(\d+)\s+(.+?)\s+\((.+?)\s+->\s+(.+?)\)\s*$"#
        let regex = try NSRegularExpression(pattern: pattern)
        for line in result.output.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range) else { continue }
            func field(_ index: Int) -> String { Range(match.range(at: index), in: line).map { String(line[$0]) } ?? "" }
            let token = field(1), name = field(2), installed = field(3), latest = field(4)
            let index = items.firstIndex { $0.provider == .appStore && $0.name.caseInsensitiveCompare(name) == .orderedSame }
            if let index {
                items[index].token = token; items[index].latestVersion = latest; items[index].isOutdated = true
                items[index].detail = "App Store update available through mas. Apple authentication may be required."
            } else {
                items.append(UpdateItem(id: "mas:\(token)", name: name, installedVersion: installed,
                                        latestVersion: latest, provider: .appStore, token: token,
                                        homepage: URL(string: "macappstore://itunes.apple.com/app/id\(token)"), isOutdated: true,
                                        detail: "App Store update available through mas."))
            }
        }
    }
}
