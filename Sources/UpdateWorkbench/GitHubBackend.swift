import Foundation

struct GitHubRelease: Codable, Sendable {
    let version: String
    let releasePageURL: URL
    let downloadURL: URL?
    /// Sanitized release body (Markdown).
    var notes: String?
    var isPrerelease: Bool?

    init(version: String, releasePageURL: URL, downloadURL: URL?, notes: String? = nil, isPrerelease: Bool? = nil) {
        self.version = version; self.releasePageURL = releasePageURL; self.downloadURL = downloadURL
        self.notes = notes; self.isPrerelease = isPrerelease
    }
}

/// Public, explicitly selected GitHub repositories only; no credentials. Discovered repositories are suggestions the user confirms.
enum GitHubBackend {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func validRepository(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 100, let first = part.first,
                  first.isASCII && (first.isLetter || first.isNumber) else { return false }
            return part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
                && part != "." && part != ".." && !part.hasSuffix(".git")
        }
    }

    /// Numeric versions; with `allowPrerelease`, a suffix such as `-beta.1` or `-rc2` is accepted too.
    static func normalizedVersion(_ value: String, allowPrerelease: Bool = false) -> String? {
        let version = value.hasPrefix("v") || value.hasPrefix("V") ? String(value.dropFirst()) : value
        let pattern = allowPrerelease ? #"^[0-9]+(?:\.[0-9]+){0,4}(?:-[0-9A-Za-z][0-9A-Za-z.]{0,30})?$"# : #"^[0-9]+(?:\.[0-9]+){0,4}$"#
        guard version.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return version
    }

    static func check(repository: String, installedVersion: String, allowPrerelease: Bool = false) async throws -> GitHubRelease? {
        if allowPrerelease {
            return try parseReleaseList(try await fetchReleaseData(repository: repository, list: true), repository: repository, installedVersion: installedVersion)
        }
        return try parseRelease(try await fetchLatestReleaseData(repository: repository), repository: repository, installedVersion: installedVersion)
    }

    /// Latest public release metadata; also used by Electron GitHub-provider checks.
    static func fetchLatestRelease(repository: String) async throws -> APIRelease {
        try JSONDecoder().decode(APIRelease.self, from: try await fetchLatestReleaseData(repository: repository))
    }

    /// Newest non-draft release including pre-releases (used when pre-releases are allowed for an app).
    static func fetchNewestRelease(repository: String) async throws -> APIRelease? {
        try JSONDecoder().decode([APIRelease].self, from: try await fetchReleaseData(repository: repository, list: true)).first { !$0.draft }
    }

    static func fetchLatestReleaseData(repository: String) async throws -> Data {
        try await fetchReleaseData(repository: repository, list: false)
    }

    static func fetchReleaseData(repository: String, list: Bool) async throws -> Data {
        guard validRepository(repository) else { throw Failure(message: "Use a GitHub repository in owner/repository form.") }
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases" + (list ? "?per_page=15" : "/latest"))!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        ProxySettings.apply(to: configuration)
        let delegate = GitHubResponseGuard()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(AppIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (file, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse else { throw Failure(message: "GitHub did not return an HTTP response.") }
        guard http.statusCode == 200 else {
            if http.statusCode == 403 || http.statusCode == 429 { throw Failure(message: rateLimitMessage(http)) }
            if http.statusCode == 404 { throw Failure(message: "No public latest release was found for \(repository). Check the repository setting.") }
            throw Failure(message: "GitHub release check returned HTTP \(http.statusCode).")
        }
        let size = (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard size <= GitHubResponseGuard.maximumBytes else { throw Failure(message: "GitHub release metadata exceeds 8 MB.") }
        return try Data(contentsOf: file)
    }

    /// GitHub allows 60 unauthenticated API requests an hour per IP address. Conditional requests
    /// don't help: without a token, a `304 Not Modified` answer counts against the limit too.
    static func rateLimitMessage(_ response: HTTPURLResponse) -> String {
        guard response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" || response.statusCode == 429 else {
            return "GitHub refused this check (HTTP \(response.statusCode)). Private repositories are unsupported."
        }
        guard let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init) else {
            return "GitHub's limit of 60 checks an hour was reached. Try again later."
        }
        let time = Date(timeIntervalSince1970: reset).formatted(date: .omitted, time: .shortened)
        return "GitHub's limit of 60 checks an hour was reached. It resets at \(time)."
    }

    static func parseRelease(_ data: Data, repository: String, installedVersion: String,
                             architecture: String = SparkleBackend.hostArchitecture) throws -> GitHubRelease? {
        guard validRepository(repository), data.count <= GitHubResponseGuard.maximumBytes else { throw Failure(message: "Invalid GitHub repository or oversized release metadata.") }
        return try evaluate(try JSONDecoder().decode(APIRelease.self, from: data), repository: repository, installedVersion: installedVersion,
                            architecture: architecture, allowPrerelease: false)
    }

    /// Newest non-draft entry of a `/releases` list, pre-releases included.
    static func parseReleaseList(_ data: Data, repository: String, installedVersion: String,
                                 architecture: String = SparkleBackend.hostArchitecture) throws -> GitHubRelease? {
        guard validRepository(repository), data.count <= GitHubResponseGuard.maximumBytes else { throw Failure(message: "Invalid GitHub repository or oversized release metadata.") }
        guard let release = try JSONDecoder().decode([APIRelease].self, from: data).first(where: { !$0.draft }) else { return nil }
        return try evaluate(release, repository: repository, installedVersion: installedVersion, architecture: architecture, allowPrerelease: true)
    }

    static func evaluate(_ release: APIRelease, repository: String, installedVersion: String,
                         architecture: String, allowPrerelease: Bool) throws -> GitHubRelease? {
        guard !release.draft, allowPrerelease || !release.prerelease else { return nil }
        guard let version = normalizedVersion(release.tag_name, allowPrerelease: allowPrerelease),
              let installed = normalizedVersion(installedVersion, allowPrerelease: true) else {
            throw Failure(message: "This repository uses a version format that cannot be compared automatically.")
        }
        guard SparkleBackend.isNewer(version, than: installed) else { return nil }
        guard let page = URL(string: release.html_url), validGitHubURL(page, repository: repository, pathPrefix: "releases/tag/") else {
            throw Failure(message: "The release page does not belong to the configured GitHub repository.")
        }
        let candidates = release.assets.filter { asset in
            guard asset.state == nil || asset.state == "uploaded",
                  let url = URL(string: asset.browser_download_url),
                  validGitHubURL(url, repository: repository, pathPrefix: "releases/download/"),
                  ["zip", "dmg"].contains(url.pathExtension.lowercased()) else { return false }
            let name = asset.name.lowercased()
            guard !["windows", "linux", "source", "debug", "symbols", "checksums", ".delta"].contains(where: name.contains) else { return false }
            let arm = ["arm64", "aarch64", "apple-silicon", "apple_silicon"].contains(where: name.contains)
            let intel = ["x86_64", "x86-64", "x64", "amd64", "intel"].contains(where: name.contains)
            let universal = name.contains("universal")
            let mac = ["macos", "darwin", "osx", "mac-", "mac_"].contains(where: name.contains) || url.pathExtension.lowercased() == "dmg"
            guard mac else { return false }
            switch architecture {
            case "arm64": return universal || (arm && !intel)
            case "x86_64": return universal || (intel && !arm)
            default: return false
            }
        }
        // A single native DMG wins over ZIPs; any other ambiguity remains an explicit manual choice.
        let dmgs = candidates.filter { $0.name.lowercased().hasSuffix(".dmg") }
        let chosen = dmgs.count == 1 ? dmgs[0] : (candidates.count == 1 ? candidates[0] : nil)
        let assetURL = chosen.flatMap { URL(string: $0.browser_download_url) }
        let notes = release.body.map(ReleaseNotes.sanitize).flatMap { $0.isEmpty ? nil : $0 }
        return GitHubRelease(version: version, releasePageURL: page, downloadURL: assetURL, notes: notes, isPrerelease: release.prerelease)
    }

    static func validGitHubURL(_ url: URL, repository: String, pathPrefix: String) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "github.com"
            && url.user == nil && url.password == nil && url.port == nil
            && url.path.lowercased().hasPrefix("/\(repository.lowercased())/\(pathPrefix)")
    }

    struct APIRelease: Decodable, Sendable {
        let tag_name: String
        let html_url: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
        var body: String?
    }
    struct Asset: Decodable, Sendable {
        let name: String
        let browser_download_url: String
        let state: String?
    }
}

private final class GitHubResponseGuard: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let maximumBytes = 8 * 1024 * 1024
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > Self.maximumBytes || totalBytesExpectedToWrite > Self.maximumBytes { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme?.lowercased() == "https", url.host?.lowercased() == "api.github.com",
              url.user == nil, url.password == nil, url.port == nil else { completionHandler(nil); return }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        ProxySettings.respond(to: challenge)
    }
}
