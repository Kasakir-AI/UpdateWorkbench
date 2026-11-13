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
    /// Sanitized release notes from the feed (Sparkle `description`, Electron `releaseNotes`).
    var notes: String?

    init(version: String, downloadURL: URL, releaseNotesURL: URL?, signature: String? = nil, sha512: String? = nil, notes: String? = nil) {
        self.version = version
        self.downloadURL = downloadURL
        self.releaseNotesURL = releaseNotesURL
        self.signature = signature
        self.sha512 = sha512
        self.notes = notes
    }
}

/// Settings for one direct installation.
struct InstallOptions: Sendable {
    /// Approved signer changes; nil disables approvals (self-update).
    var trustedSigners: TrustedSignerStore? = .standard
    /// The user accepted the disk image's license agreement.
    var acceptLicense = false
    var verifier: any SignatureVerifier = CodesignVerifier()
    var appName: String?
}

struct InstallOutcome: Sendable {
    let message: String
    let installedVersion: String
    let signerApproved: Bool
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
        VersionOrder.compare(candidate, installed) == .orderedDescending
    }

    static func check(feedURL: URL, installedVersion: String, allowPrerelease: Bool = false) async throws -> SparkleRelease? {
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
        return try parseAppcast(data, installedVersion: installedVersion, allowPrerelease: allowPrerelease)
    }

    /// Stable items only, unless pre-releases are allowed for this app (then any `sparkle:channel` counts).
    static func parseAppcast(_ data: Data, installedVersion: String, allowPrerelease: Bool = false) throws -> SparkleRelease? {
        guard data.count <= 8 * 1024 * 1024 else { throw Failure(message: "The appcast exceeds 8 MB.") }
        let reader = AppcastReader()
        reader.allowPrerelease = allowPrerelease
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse() else { throw Failure(message: "The update feed is not a supported XML appcast.") }
        return reader.releases.filter { isNewer($0.version, than: installedVersion) }
            .sorted { isNewer($0.version, than: $1.version) }.first
    }

    /// `replacingRunningSelf` is only honored when the target is this running app's own bundle (self-update).
    static func install(release: SparkleRelease, target: URL, replacingRunningSelf: Bool = false,
                        options: InstallOptions = InstallOptions()) async throws -> InstallOutcome {
        try requireHTTPS(release.downloadURL)
        let isSelf = replacingRunningSelf && target.resolvingSymlinksInPath().standardizedFileURL == Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        if !isSelf { try await assertNotRunning(target) }
        let fm = FileManager.default
        let original = target.standardizedFileURL
        try requireReplaceable(original)
        let temporary = fm.temporaryDirectory.appendingPathComponent("UpdateWorkbench-\(UUID().uuidString).noindex", isDirectory: true)
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
        return try await installPayload(payload, fileExtension: fileExtension, release: release, target: original, isSelf: isSelf, options: options)
    }

    private static func requireReplaceable(_ original: URL) throws {
        let fm = FileManager.default
        guard original.pathExtension.lowercased() == "app",
              (try? original.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
              fm.isWritableFile(atPath: original.path),
              fm.isWritableFile(atPath: original.deletingLastPathComponent().path) else {
            throw Failure(message: "This app cannot be replaced by your account. Use its own updater or package manager.")
        }
    }

    /// Verifies and installs an already downloaded ZIP or DMG. ZIPs are extracted with symlink checks;
    /// DMGs are mounted read-only (nobrowse, noautoopen) and always detached, also on errors.
    static func installPayload(_ payload: URL, fileExtension: String, release: SparkleRelease, target: URL,
                               isSelf: Bool = false, options: InstallOptions = InstallOptions()) async throws -> InstallOutcome {
        let original = target.standardizedFileURL
        try requireReplaceable(original)
        guard ["zip", "dmg"].contains(fileExtension) else { throw Failure(message: "Direct installation supports complete ZIP or DMG app bundles.") }
        if let sha512 = release.sha512 { try verifySHA512(payload, expected: sha512) }
        if let publicKey = AppBundleInfo.read(original)["SUPublicEDKey"] as? String {
            try verifyArchiveSignature(payload, signature: release.signature, publicKey: publicKey)
        }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("UpdateWorkbench-work-\(UUID().uuidString).noindex", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        return try await Task.detached(priority: .userInitiated) {
            let sourceRoot = work.appendingPathComponent("payload", isDirectory: true)
            try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
            let originalInfo = AppBundleInfo.read(original)
            let appName = options.appName ?? (originalInfo["CFBundleName"] as? String) ?? original.deletingPathExtension().lastPathComponent
            if fileExtension == "zip" {
                // Validates every entry and link target before writing anything, then extracts.
                try ArchiveSafety.extractZIP(payload, to: sourceRoot)
            } else {
                try DiskImage.attach(payload, at: sourceRoot, acceptLicense: options.acceptLicense, appName: appName, version: release.version)
            }
            defer { if fileExtension == "dmg" { DiskImage.detach(sourceRoot) } }
            return try await verifyAndReplace(sourceRoot: sourceRoot, original: original, release: release, appName: appName,
                                              isZIP: fileExtension == "zip", isSelf: isSelf, options: options)
        }.value
    }

    /// The checks shared by ZIP and DMG payloads, then staging and replacement. The previous copy exists only
    /// during the swap: it is deleted once the new app is in place and verified, or put back if anything fails.
    private static func verifyAndReplace(sourceRoot: URL, original: URL, release: SparkleRelease, appName: String,
                                         isZIP: Bool, isSelf: Bool, options: InstallOptions) async throws -> InstallOutcome {
        let fm = FileManager.default
        let verifier = options.verifier
        let oldInfo = AppBundleInfo.read(original)
        guard let identifier = oldInfo["CFBundleIdentifier"] as? String else { throw Failure(message: "The installed app has no bundle identity.") }
        let candidates = try applicationCandidates(in: sourceRoot).filter { AppBundleInfo.read($0)["CFBundleIdentifier"] as? String == identifier }
        guard candidates.count == 1, let candidate = candidates.first else {
            throw Failure(message: candidates.isEmpty ? "The download contains no app with the installed bundle identifier (\(identifier))."
                          : "The download contains \(candidates.count) apps with the bundle identifier \(identifier), so the right one can't be chosen safely.")
        }
        try ArchiveSafety.validateExtracted(app: candidate, rejectHardLinks: isZIP)
        let newInfo = AppBundleInfo.read(candidate)
        let newVersion = newInfo["CFBundleShortVersionString"] as? String ?? ""
        let newBuild = newInfo["CFBundleVersion"] as? String ?? ""
        guard let executable = newInfo["CFBundleExecutable"] as? String,
              !executable.isEmpty, !executable.contains("/"), executable != ".", executable != ".." else {
            throw Failure(message: "The downloaded app has no valid executable declaration.")
        }
        let architectures = try SyncCommand.run("/usr/bin/lipo", ["-archs", candidate.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable).path])
            .split(whereSeparator: \.isWhitespace).map(String.init)
        guard architectures.contains(hostArchitecture) else {
            throw Failure(message: "The update has no native \(hostArchitecture) executable. Use the vendor updater for translated apps.")
        }
        if let minimumOS = newInfo["LSMinimumSystemVersion"] as? String {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            guard !isNewer(minimumOS, than: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)") else {
                throw Failure(message: "The downloaded app requires a newer version of macOS.")
            }
        }
        guard VersionOrder.isSame(release.version, newVersion) || release.version == newBuild else {
            throw Failure(message: "The downloaded app version (\(newVersion)) does not match the selected update (\(release.version)).")
        }
        let oldVersion = oldInfo["CFBundleShortVersionString"] as? String ?? ""
        let oldBuild = oldInfo["CFBundleVersion"] as? String ?? ""
        guard isNewer(newVersion, than: oldVersion) || (VersionOrder.isSame(newVersion, oldVersion) && isNewer(newBuild, than: oldBuild)) else {
            throw Failure(message: "The downloaded app is not newer than the installed app.")
        }
        try verifier.verify(original)
        let installedSigner = try verifier.identity(original)
        // The candidate must pass codesign and Gatekeeper before any signer question is asked.
        try verifier.verify(candidate)
        var candidateSigner = try verifier.identity(candidate)
        candidateSigner.gatekeeper = try verifier.assess(candidate)
        var approved = false
        if candidateSigner.teamID != installedSigner.teamID {
            guard let store = options.trustedSigners, store.isApproved(bundleID: identifier, teamID: candidateSigner.teamID) else {
                throw SignerChange(appName: appName, bundleID: identifier, version: release.version, installed: installedSigner, candidate: candidateSigner)
            }
            approved = true
        }
        // Staging happens in a private replacement folder on the same volume, never beside the app.
        let workspace = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: original, create: true)
        var keepWorkspace = false
        defer { if !keepWorkspace { try? fm.removeItem(at: workspace) } }
        // A `.noindex` folder keeps Spotlight and Launch Services from listing the staged and previous apps.
        let holding = workspace.appendingPathComponent("staging.noindex", isDirectory: true)
        try fm.createDirectory(at: holding, withIntermediateDirectories: true)
        let staged = holding.appendingPathComponent(original.lastPathComponent)
        let previous = holding.appendingPathComponent("previous-" + original.lastPathComponent)
        try SyncCommand.run("/usr/bin/ditto", [candidate.path, staged.path])
        try verifier.verify(staged)
        guard try verifier.identity(staged).teamID == candidateSigner.teamID else { throw Failure(message: "The staged app failed its signing identity check.") }
        // Re-check the original identity immediately before replacing it.
        guard AppBundleInfo.read(original)["CFBundleIdentifier"] as? String == identifier, try verifier.identity(original).teamID == installedSigner.teamID else {
            throw Failure(message: "The installed app changed while downloading. Scan again.")
        }
        let isRunning = await MainActor.run {
            NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.resolvingSymlinksInPath() == original.resolvingSymlinksInPath() }
        }
        guard isSelf || !isRunning else { throw Failure(message: "Quit the app before installing its update.") }
        try fm.moveItem(at: original, to: previous)
        do {
            try fm.moveItem(at: staged, to: original)
            // Verify the app now in place before the previous copy is discarded.
            guard AppBundleInfo.read(original)["CFBundleShortVersionString"] as? String == newVersion,
                  AppBundleInfo.read(original)["CFBundleIdentifier"] as? String == identifier else {
                throw Failure(message: "The installed app didn't match the update after it was moved into place.")
            }
            try verifier.verify(original)
            guard try verifier.identity(original).teamID == candidateSigner.teamID else { throw Failure(message: "The installed app failed its signing identity check.") }
        } catch {
            do {
                if fm.fileExists(atPath: original.path) { try fm.removeItem(at: original) }
                try fm.moveItem(at: previous, to: original)
            } catch {
                keepWorkspace = true
                throw Failure(message: "Installation and rollback failed. The previous app is at \(previous.path); move it back to \(original.deletingLastPathComponent().path).")
            }
            throw Failure(message: "The update was rolled back and the previous version is back in place: \(error.localizedDescription)")
        }
        try? fm.removeItem(at: previous)
        let signerNote = approved ? " Signed by approved team \(candidateSigner.teamID) (\(candidateSigner.signerName))." : ""
        return InstallOutcome(message: "Installed \(release.version).\(signerNote) The previous version was removed after the new one passed its checks.",
                              installedVersion: newVersion, signerApproved: approved)
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
    var allowPrerelease = false
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
            if channel.isEmpty || channel == "stable" || allowPrerelease, !SparkleBackend.isNewer(minimumOS, than: currentOS) {
                for enclosure in enclosures {
                    guard enclosure["sparkle:deltaFrom"] == nil,
                          enclosure["sparkle:os"] == nil || enclosure["sparkle:os"] == "macos",
                          enclosure["sparkle:arch"] == nil || [SparkleBackend.hostArchitecture, "universal", "universal2"].contains(enclosure["sparkle:arch"]!),
                          let rawURL = enclosure["url"], let url = URL(string: rawURL), url.scheme?.lowercased() == "https",
                          let version = enclosure["sparkle:shortVersionString"] ?? current["sparkle:shortVersionString"] ?? enclosure["sparkle:version"] ?? current["sparkle:version"] else { continue }
                    let notes = current["sparkle:releaseNotesLink"].flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
                    let description = current["description"].map(ReleaseNotes.sanitize).flatMap { $0.isEmpty ? nil : $0 }
                    releases.append(SparkleRelease(version: version, downloadURL: url, releaseNotesURL: notes,
                                                   signature: enclosure["sparkle:edSignature"], notes: description))
                }
            }
        }
        itemDepth -= 1
        element = ""
        text = ""
    }
}
