import AppKit
import CryptoKit
import Foundation

struct SparkleRelease: Codable, Sendable {
    let version: String
    let downloadURL: URL
    let releaseNotesURL: URL?
    let signature: String?
    /// Base64 (electron-builder) or hex SHA-512 of the complete download, when the feed publishes one.
    let sha512: String?

    init(version: String, downloadURL: URL, releaseNotesURL: URL?, signature: String? = nil, sha512: String? = nil) {
        self.version = version
        self.downloadURL = downloadURL
        self.releaseNotesURL = releaseNotesURL
        self.signature = signature
        self.sha512 = sha512
    }
}

/// Reads public appcasts and installs authenticated, complete macOS app bundles.
/// This deliberately does not implement Sparkle delta updates or privileged installers.
enum SparkleBackend {
    static var hostArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unsupported"
        #endif
    }
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        candidate.compare(installed, options: [.numeric, .caseInsensitive]) == .orderedDescending
    }

    static func check(feedURL: URL, installedVersion: String) async throws -> SparkleRelease? {
        try requireHTTPS(feedURL)
        let guardDelegate = HTTPSOnlyDelegate(maximumBytes: 8 * 1024 * 1024)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 45
        ProxySettings.apply(to: configuration)
        let session = URLSession(configuration: configuration, delegate: guardDelegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (file, response) = try await session.download(from: feedURL)
        let size = (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard (response as? HTTPURLResponse)?.statusCode == 200, size <= 8 * 1024 * 1024 else {
            throw Failure(message: "The appcast was unavailable or larger than 8 MB.")
        }
        let data = try Data(contentsOf: file)
        return try parseAppcast(data, installedVersion: installedVersion)
    }

    static func parseAppcast(_ data: Data, installedVersion: String) throws -> SparkleRelease? {
        guard data.count <= 8 * 1024 * 1024 else { throw Failure(message: "The appcast exceeds 8 MB.") }
        let reader = AppcastReader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse() else { throw Failure(message: "The update feed is not a supported XML appcast.") }
        return reader.releases.filter { isNewer($0.version, than: installedVersion) }
            .sorted { isNewer($0.version, than: $1.version) }.first
    }

    /// `replacingRunningSelf` is only honored when the target is this running app's own bundle (self-update).
    static func install(release: SparkleRelease, target: URL, replacingRunningSelf: Bool = false) async throws -> String {
        try requireHTTPS(release.downloadURL)
        let isSelf = replacingRunningSelf && target.resolvingSymlinksInPath().standardizedFileURL == Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        if !isSelf { try await assertNotRunning(target) }
        let fm = FileManager.default
        let original = target.standardizedFileURL
        guard original.pathExtension.lowercased() == "app",
              (try? original.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
              fm.isWritableFile(atPath: original.path),
              fm.isWritableFile(atPath: original.deletingLastPathComponent().path) else {
            throw Failure(message: "This app cannot be replaced by your account. Use its own updater or package manager.")
        }
        let temporary = fm.temporaryDirectory.appendingPathComponent("UpdateWorkbench-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let guardDelegate = HTTPSOnlyDelegate(maximumBytes: 2_147_483_648)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 900
        ProxySettings.apply(to: configuration)
        let session = URLSession(configuration: configuration, delegate: guardDelegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (downloaded, response) = try await session.download(from: release.downloadURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(message: "The update download failed.") }
        let size = (try downloaded.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard size > 0, size <= 2_147_483_648 else { throw Failure(message: "The update is empty or exceeds the 2 GB download limit.") }
        let fileExtension = release.downloadURL.pathExtension.lowercased()
        guard ["zip", "dmg"].contains(fileExtension) else {
            throw Failure(message: "Direct installation supports complete ZIP or DMG app bundles. Use the vendor updater for this format.")
        }
        let payload = temporary.appendingPathComponent("download.\(fileExtension)")
        try fm.moveItem(at: downloaded, to: payload)
        if let sha512 = release.sha512 { try verifySHA512(payload, expected: sha512) }
        if let publicKey = Bundle(url: original)?.object(forInfoDictionaryKey: "SUPublicEDKey") as? String {
            try verifyArchiveSignature(payload, signature: release.signature, publicKey: publicKey)
        }
        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let sourceRoot = temporary.appendingPathComponent("payload", isDirectory: true)
            try fm.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
            var mounted = false
            defer {
                if mounted { _ = try? command("/usr/bin/hdiutil", ["detach", sourceRoot.path, "-quiet"]) }
            }
            if fileExtension == "zip" {
                // Validates every entry and link target before writing anything, then extracts.
                try ArchiveSafety.extractZIP(payload, to: sourceRoot)
            } else {
                _ = try command("/usr/bin/hdiutil", ["attach", payload.path, "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", sourceRoot.path, "-plist"])
                mounted = true
            }
            let oldBundle = Bundle(url: original)
            guard let identifier = oldBundle?.bundleIdentifier else { throw Failure(message: "The installed app has no bundle identity.") }
            let candidates = try applicationCandidates(in: sourceRoot).filter { Bundle(url: $0)?.bundleIdentifier == identifier }
            guard candidates.count == 1, let candidate = candidates.first else {
                throw Failure(message: "The download must contain exactly one app matching the installed bundle identifier.")
            }
            try ArchiveSafety.validateExtracted(app: candidate, rejectHardLinks: fileExtension == "zip")
            let newBundle = Bundle(url: candidate)
            let newVersion = newBundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            let newBuild = newBundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            guard let executable = newBundle?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
                  !executable.isEmpty, !executable.contains("/"), executable != ".", executable != ".." else {
                throw Failure(message: "The downloaded app has no valid executable declaration.")
            }
            let architectures = try command("/usr/bin/lipo", ["-archs", candidate.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable).path])
                .split(whereSeparator: \.isWhitespace).map(String.init)
            guard architectures.contains(hostArchitecture) else {
                throw Failure(message: "The update has no native \(hostArchitecture) executable. Use the vendor updater for translated apps.")
            }
            if let minimumOS = newBundle?.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String {
                let os = ProcessInfo.processInfo.operatingSystemVersion
                guard !isNewer(minimumOS, than: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)") else {
                    throw Failure(message: "The downloaded app requires a newer version of macOS.")
                }
            }
            guard release.version == newVersion || release.version == newBuild else {
                throw Failure(message: "The downloaded app version does not match the selected update.")
            }
            let oldVersion = oldBundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            let oldBuild = oldBundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            guard isNewer(newVersion, than: oldVersion) || (newVersion == oldVersion && isNewer(newBuild, than: oldBuild)) else {
                throw Failure(message: "The downloaded app is not newer than the installed app.")
            }
            _ = try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--all-architectures", original.path])
            let originalTeam = try signingTeam(original)
            let candidateTeam = try signingTeam(candidate)
            guard candidateTeam == originalTeam else {
                throw Failure(message: "The update is signed by a different developer team (\(candidateTeam)) than the installed app (\(originalTeam)), so it was not installed. Use the app's own updater or the vendor's download page if you trust the new signer.")
            }
            _ = try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--all-architectures", candidate.path])
            _ = try command("/usr/sbin/spctl", ["--assess", "--type", "execute", "--verbose=2", candidate.path])
            let parent = original.deletingLastPathComponent()
            let staged = parent.appendingPathComponent(".UpdateWorkbench-stage-\(UUID().uuidString).app")
            let backup = parent.appendingPathComponent(".\(original.deletingPathExtension().lastPathComponent)-backup-\(UUID().uuidString).app")
            defer { try? fm.removeItem(at: staged) }
            _ = try command("/usr/bin/ditto", [candidate.path, staged.path])
            _ = try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--all-architectures", staged.path])
            guard try signingTeam(staged) == originalTeam else { throw Failure(message: "The staged app failed its signing identity check.") }
            // Re-check the original identity immediately before replacing it.
            guard Bundle(url: original)?.bundleIdentifier == identifier, try signingTeam(original) == originalTeam else {
                throw Failure(message: "The installed app changed while downloading. Scan again.")
            }
            let isRunning = await MainActor.run {
                NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.resolvingSymlinksInPath() == original.resolvingSymlinksInPath() }
            }
            guard isSelf || !isRunning else { throw Failure(message: "Quit the app before installing its update.") }
            try fm.moveItem(at: original, to: backup)
            do { try fm.moveItem(at: staged, to: original) }
            catch {
                do { try fm.moveItem(at: backup, to: original) }
                catch { throw Failure(message: "Installation and rollback failed. The original app is at \(backup.path).") }
                throw error
            }
            return "Installed \(release.version). Previous app retained at \(backup.path)"
        }.value
    }

    private static func assertNotRunning(_ target: URL) async throws {
        let running = await MainActor.run {
            NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.resolvingSymlinksInPath() == target.resolvingSymlinksInPath() }
        }
        guard !running else { throw Failure(message: "Quit this app before installing its update.") }
    }

    private static func requireHTTPS(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw Failure(message: "Only HTTPS update URLs without embedded credentials are supported.")
        }
    }

    /// Sparkle's EdDSA keys and signatures are Base64-encoded Ed25519 bytes.
    /// Validate the entire distribution archive before mounting or extracting it.
    static func verifyArchiveSignature(_ payload: URL, signature: String?, publicKey: String) throws {
        guard let signature, let signatureBytes = Data(base64Encoded: signature),
              let keyBytes = Data(base64Encoded: publicKey) else {
            throw Failure(message: "The installed app requires a valid Sparkle Ed25519 update signature.")
        }
        do {
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)
            let data = try Data(contentsOf: payload, options: [.mappedIfSafe])
            guard key.isValidSignature(signatureBytes, for: data) else {
                throw Failure(message: "The update archive failed its Sparkle Ed25519 signature check.")
            }
        } catch let failure as Failure { throw failure }
        catch { throw Failure(message: "The Sparkle update signature or public key is invalid: \(error.localizedDescription)") }
    }

    /// Streams the payload through SHA-512 and compares with a Base64 or hex digest.
    static func verifySHA512(_ payload: URL, expected: String) throws {
        let handle = try FileHandle(forReadingFrom: payload)
        defer { try? handle.close() }
        var hasher = SHA512()
        while let chunk = try handle.read(upToCount: 4 * 1_048_576), !chunk.isEmpty { hasher.update(data: chunk) }
        let digest = Data(hasher.finalize())
        let trimmed = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        guard Data(base64Encoded: trimmed) == digest || trimmed.lowercased() == hex else {
            throw Failure(message: "The downloaded update failed its published SHA-512 checksum.")
        }
    }

    private static func command(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw Failure(message: "\(URL(fileURLWithPath: path).lastPathComponent) failed: \(output.suffix(2000))")
        }
        return output
    }

    private static func signingTeam(_ app: URL) throws -> String {
        let output = try command("/usr/bin/codesign", ["-d", "--verbose=4", app.path])
        guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix("TeamIdentifier=") }) else {
            throw Failure(message: "The app has no developer signing team. Direct replacement is unavailable.")
        }
        let value = String(line.dropFirst("TeamIdentifier=".count))
        guard !value.isEmpty, value != "not set" else { throw Failure(message: "Ad-hoc or unsigned apps cannot be replaced directly.") }
        return value
    }

    private static func applicationCandidates(in root: URL) throws -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else {
            throw Failure(message: "The update contents could not be inspected.")
        }
        var count = 0
        for case let url as URL in enumerator {
            count += 1
            guard count < 100_000 else { throw Failure(message: "The update contains too many files.") }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if url.pathExtension.lowercased() == "app", values.isDirectory == true {
                result.append(url)
                enumerator.skipDescendants()
            }
        }
        return result
    }
}

private final class HTTPSOnlyDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let maximumBytes: Int64
    init(maximumBytes: Int64) { self.maximumBytes = maximumBytes }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        ProxySettings.respond(to: challenge)
    }
}

private final class AppcastReader: NSObject, XMLParserDelegate {
    var releases: [SparkleRelease] = []
    private var current: [String: String] = [:]
    private var itemDepth = 0
    private var element = ""
    private var text = ""
    private var enclosures: [[String: String]] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if elementName == "item" { current = [:]; enclosures = []; itemDepth = 1 }
        else if itemDepth > 0 { itemDepth += 1 }
        element = elementName
        text = ""
        if itemDepth > 0, elementName == "enclosure" { enclosures.append(attributes) }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if itemDepth > 0 { text += string } }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { if itemDepth > 0 { text += String(decoding: CDATABlock, as: UTF8.self) } }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard itemDepth > 0 else { return }
        if elementName != "item" { current[elementName] = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if elementName == "item" {
            let channel = current["sparkle:channel"] ?? ""
            let minimumOS = current["sparkle:minimumSystemVersion"] ?? "0"
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let currentOS = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
            if channel.isEmpty || channel == "stable", !SparkleBackend.isNewer(minimumOS, than: currentOS) {
                for enclosure in enclosures {
                    guard enclosure["sparkle:deltaFrom"] == nil,
                          enclosure["sparkle:os"] == nil || enclosure["sparkle:os"] == "macos",
                          enclosure["sparkle:arch"] == nil || [SparkleBackend.hostArchitecture, "universal", "universal2"].contains(enclosure["sparkle:arch"]!),
                          let rawURL = enclosure["url"], let url = URL(string: rawURL), url.scheme?.lowercased() == "https",
                          let version = enclosure["sparkle:shortVersionString"] ?? current["sparkle:shortVersionString"] ?? enclosure["sparkle:version"] ?? current["sparkle:version"] else { continue }
                    let notes = current["sparkle:releaseNotesLink"].flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
                    releases.append(SparkleRelease(version: version, downloadURL: url, releaseNotesURL: notes,
                                                   signature: enclosure["sparkle:edSignature"]))
                }
            }
        }
        itemDepth -= 1
        element = ""
        text = ""
    }
}
