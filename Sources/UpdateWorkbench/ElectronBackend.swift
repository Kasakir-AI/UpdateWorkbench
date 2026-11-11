import Foundation

/// The public electron-builder/electron-updater configuration an app ships in
/// `Contents/Resources/app-update.yml`. Only public, unauthenticated providers are supported.
struct ElectronUpdateConfig: Codable, Sendable, Equatable, Hashable {
    enum Provider: String, Codable, Sendable { case github, generic, s3 }
    var provider: Provider
    var owner: String?
    var repo: String?
    var url: URL?
    var channel: String?
    var bucket: String?
    var region: String?
    var path: String?
    var endpoint: URL?

    var metadataFileName: String { "\(channel ?? "latest")-mac.yml" }
    var repository: String? { owner.flatMap { owner in repo.map { "\(owner)/\($0)" } } }
    var summary: String {
        switch provider {
        case .github: return "electron-updater GitHub provider: \(repository ?? "unknown")"
        case .generic: return "electron-updater generic provider: \(url?.absoluteString ?? "unknown")"
        case .s3: return "electron-updater S3 provider: \(bucket ?? "unknown")"
        }
    }
}

/// Result of an Electron metadata check. `release` is nil when an update exists but no single
/// verifiable native payload could be selected.
struct ElectronCheckResult: Sendable {
    let version: String
    let release: SparkleRelease?
    let releasePage: URL?
    let note: String
}

enum ElectronBackend {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct MetadataFile: Sendable, Equatable {
        var url: String
        var sha512: String?
        var size: Int?
    }

    struct Metadata: Sendable, Equatable {
        var version: String
        var files: [MetadataFile]
        var path: String?
        var sha512: String?
    }

    static let updateConfigPath = "Contents/Resources/app-update.yml"

    static func unquote(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespaces)
        if let hash = text.range(of: " #") { text = String(text[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces) }
        if text.count >= 2, let first = text.first, let last = text.last, (first == "'" && last == "'") || (first == "\"" && last == "\"") {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }

    /// Top-level `key: value` scalars of a small YAML document. Nested blocks are ignored.
    static func topLevelScalars(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            guard let first = raw.first, first != " ", first != "\t", first != "#", first != "-",
                  let colon = raw.firstIndex(of: ":") else { continue }
            let key = String(raw[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = unquote(String(raw[raw.index(after: colon)...]))
            if !key.isEmpty, !value.isEmpty { result[key] = value }
        }
        return result
    }

    static func validChannel(_ value: String) -> Bool {
        value.count <= 40 && !value.isEmpty && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    /// Parses app-update.yml. Returns nil for private, token-based or unsupported providers.
    static func parseUpdateConfig(_ text: String) -> ElectronUpdateConfig? {
        guard text.utf8.count <= 65_536 else { return nil }
        let values = topLevelScalars(text)
        guard let rawProvider = values["provider"], let provider = ElectronUpdateConfig.Provider(rawValue: rawProvider.lowercased()),
              values["private"]?.lowercased() != "true", values["token"] == nil else { return nil }
        var config = ElectronUpdateConfig(provider: provider)
        if let channel = values["channel"] {
            guard validChannel(channel) else { return nil }
            config.channel = channel
        }
        switch provider {
        case .github:
            guard let owner = values["owner"], let repo = values["repo"], GitHubBackend.validRepository("\(owner)/\(repo)") else { return nil }
            if let host = values["host"], host.lowercased() != "github.com" { return nil }
            config.owner = owner; config.repo = repo
        case .generic:
            guard let raw = values["url"], let url = URL(string: raw), HTTPFetcher.isSafeHTTPS(url) else { return nil }
            config.url = url
        case .s3:
            guard let bucket = values["bucket"], bucket.count >= 3, bucket.count <= 63,
                  bucket.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || ".-".contains($0)) }) else { return nil }
            config.bucket = bucket
            if let region = values["region"] {
                guard region.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }) else { return nil }
                config.region = region
            }
            if let path = values["path"] {
                guard !path.contains(".."), !path.contains("?"), !path.contains("#") else { return nil }
                config.path = path
            }
            if let raw = values["endpoint"] {
                guard let endpoint = URL(string: raw), HTTPFetcher.isSafeHTTPS(endpoint) else { return nil }
                config.endpoint = endpoint
            }
            if values["accelerate"]?.lowercased() == "true" { return nil }
        }
        return config
    }

    static func readConfig(appURL: URL) -> ElectronUpdateConfig? {
        let file = appURL.appendingPathComponent(updateConfigPath)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              (attributes[.size] as? NSNumber)?.intValue ?? .max <= 65_536,
              let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return parseUpdateConfig(text)
    }

    private static func appending(_ path: String?, to base: String) -> String {
        guard let path, !path.isEmpty else { return base }
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? base : base + "/" + trimmed
    }

    /// Mirrors electron-builder's public URL derivation for generic and S3 providers.
    static func metadataURL(for config: ElectronUpdateConfig) -> URL? {
        let base: String
        switch config.provider {
        case .github: return nil
        case .generic:
            guard let url = config.url else { return nil }
            base = url.absoluteString.hasSuffix("/") ? String(url.absoluteString.dropLast()) : url.absoluteString
        case .s3:
            guard let bucket = config.bucket else { return nil }
            var root: String
            if let endpoint = config.endpoint {
                root = endpoint.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + bucket
            } else if bucket.contains(".") {
                guard let region = config.region else { return nil }
                root = region == "us-east-1" ? "https://s3.amazonaws.com/\(bucket)" : "https://s3-\(region).amazonaws.com/\(bucket)"
            } else if config.region == "cn-north-1" {
                root = "https://\(bucket).s3.cn-north-1.amazonaws.com.cn"
            } else {
                root = "https://\(bucket).s3.amazonaws.com"
            }
            base = appending(config.path, to: root)
        }
        return URL(string: base + "/" + config.metadataFileName)
    }

    /// Parses latest-mac.yml (version, files list with url/sha512/size, legacy path/sha512).
    static func parseMetadata(_ text: String) throws -> Metadata {
        guard text.utf8.count <= 1_048_576 else { throw Failure(message: "The Electron update metadata exceeds 1 MB.") }
        let scalars = topLevelScalars(text)
        guard let version = scalars["version"], !version.isEmpty else { throw Failure(message: "The Electron update metadata has no version.") }
        var files: [MetadataFile] = []
        var inFiles = false
        for raw in text.components(separatedBy: .newlines) {
            if let first = raw.first, first != " ", first != "-", first != "#" { inFiles = raw.hasPrefix("files:"); continue }
            guard inFiles else { continue }
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") { files.append(MetadataFile(url: "")); line = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            guard !files.isEmpty, let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = unquote(String(line[line.index(after: colon)...]))
            switch key {
            case "url": files[files.count - 1].url = value
            case "sha512": files[files.count - 1].sha512 = value
            case "size": files[files.count - 1].size = Int(value)
            default: break
            }
        }
        files.removeAll { $0.url.isEmpty }
        if files.isEmpty, let path = scalars["path"] { files = [MetadataFile(url: path, sha512: scalars["sha512"], size: nil)] }
        return Metadata(version: version, files: files, path: scalars["path"], sha512: scalars["sha512"])
    }

    static func normalized(_ version: String) -> String {
        version.hasPrefix("v") || version.hasPrefix("V") ? String(version.dropFirst()) : version
    }

    /// Picks one native ZIP (preferred, as electron-updater uses) or DMG. Ambiguity disables direct installation.
    static func select(_ metadata: Metadata, baseURL: URL, installedVersion: String,
                       architecture: String = SparkleBackend.hostArchitecture,
                       allowURL: (URL) -> Bool = HTTPFetcher.isSafeHTTPS) -> ElectronCheckResult? {
        let version = normalized(metadata.version), installed = normalized(installedVersion)
        if version.contains("-") && !installed.contains("-") { return nil }
        guard SparkleBackend.isNewer(version, than: installed) else { return nil }
        struct Candidate { let url: URL; let sha512: String?; let name: String; let ext: String }
        let candidates: [Candidate] = metadata.files.compactMap { file in
            guard let url = URL(string: file.url, relativeTo: baseURL)?.absoluteURL, allowURL(url) else { return nil }
            let ext = url.pathExtension.lowercased()
            guard ["zip", "dmg"].contains(ext) else { return nil }
            return Candidate(url: url, sha512: file.sha512, name: url.lastPathComponent.lowercased(), ext: ext)
        }
        func isArm(_ name: String) -> Bool { name.contains("arm64") || name.contains("aarch64") }
        func isIntel(_ name: String) -> Bool { name.contains("x64") || name.contains("x86_64") || name.contains("intel") }
        let marked = candidates.filter { $0.name.contains("universal") || (architecture == "arm64" ? isArm($0.name) && !isIntel($0.name) : isIntel($0.name) && !isArm($0.name)) }
        let unmarked = candidates.filter { !$0.name.contains("universal") && !isArm($0.name) && !isIntel($0.name) }
        let native = marked.isEmpty ? unmarked : marked
        let chosen: Candidate?
        let zips = native.filter { $0.ext == "zip" }, dmgs = native.filter { $0.ext == "dmg" }
        if zips.count == 1 { chosen = zips[0] } else if zips.isEmpty && dmgs.count == 1 { chosen = dmgs[0] } else { chosen = nil }
        guard let chosen else {
            return ElectronCheckResult(version: version, release: nil, releasePage: nil,
                                       note: "Electron update \(version) is available, but no single native macOS ZIP/DMG could be selected. Open the app to use its own updater.")
        }
        guard let sha512 = chosen.sha512, sha512.count >= 64 else {
            return ElectronCheckResult(version: version, release: nil, releasePage: nil,
                                       note: "Electron update \(version) is available, but its metadata has no SHA-512 checksum, so direct installation is disabled.")
        }
        return ElectronCheckResult(version: version, release: SparkleRelease(version: version, downloadURL: chosen.url, releaseNotesURL: nil, sha512: sha512),
                                   releasePage: nil, note: "Electron update available from the app's declared update feed. Installation verifies SHA-512, bundle identity, signing team, Gatekeeper, version and native CPU.")
    }

    static func check(config: ElectronUpdateConfig, installedVersion: String) async throws -> ElectronCheckResult? {
        switch config.provider {
        case .github:
            guard let repository = config.repository else { throw Failure(message: "Invalid GitHub update configuration.") }
            let release = try await GitHubBackend.fetchLatestRelease(repository: repository)
            guard !release.draft, !release.prerelease else { return nil }
            guard let asset = release.assets.first(where: { $0.name == config.metadataFileName }),
                  let metadataURL = URL(string: asset.browser_download_url),
                  GitHubBackend.validGitHubURL(metadataURL, repository: repository, pathPrefix: "releases/download/") else {
                throw Failure(message: "The latest GitHub release of \(repository) has no \(config.metadataFileName).")
            }
            let (data, response) = try await HTTPFetcher.fetch(metadataURL, maximumBytes: 1_048_576)
            guard response.statusCode == 200 else { throw Failure(message: "Electron update metadata returned HTTP \(response.statusCode).") }
            let metadata = try parseMetadata(String(decoding: data, as: UTF8.self))
            let base = metadataURL.deletingLastPathComponent()
            let result = select(metadata, baseURL: base, installedVersion: installedVersion) {
                GitHubBackend.validGitHubURL($0, repository: repository, pathPrefix: "releases/download/")
            }
            let page = URL(string: release.html_url).flatMap { GitHubBackend.validGitHubURL($0, repository: repository, pathPrefix: "releases/tag/") ? $0 : nil }
            return result.map { ElectronCheckResult(version: $0.version, release: $0.release, releasePage: page, note: $0.note) }
        case .generic, .s3:
            guard let url = metadataURL(for: config) else { throw Failure(message: "The Electron update feed URL could not be derived.") }
            let (data, response) = try await HTTPFetcher.fetch(url, maximumBytes: 1_048_576)
            guard response.statusCode == 200 else { throw Failure(message: "Electron update metadata returned HTTP \(response.statusCode).") }
            return select(try parseMetadata(String(decoding: data, as: UTF8.self)), baseURL: url.deletingLastPathComponent(), installedVersion: installedVersion)
        }
    }
}
