import CFNetwork
import Foundation
import Security

enum ProxyMode: String, Codable, CaseIterable, Sendable {
    case system = "Use system proxy settings"
    case none = "No proxy"
    case manual = "Manual proxy"
}

enum ProxyKind: String, Codable, CaseIterable, Sendable {
    case http = "HTTP/HTTPS"
    case socks = "SOCKS"
}

/// Proxy configuration for this app's own HTTPS requests. The password is never stored here;
/// it lives in the login Keychain under `keychainService` keyed by user name.
struct ProxySettings: Codable, Sendable, Equatable {
    var mode: ProxyMode = .system
    var kind: ProxyKind = .http
    var host: String = ""
    var port: Int = 8080
    var authenticated: Bool = false
    var username: String = ""

    static let defaultsKey = "proxySettings"
    static let keychainService = "local.updateworkbench.proxy"

    static func load(_ defaults: UserDefaults = .standard) -> ProxySettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(ProxySettings.self, from: data) else { return ProxySettings() }
        return value
    }

    func save(_ defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }

    var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Returns a user-facing problem, or nil when the configuration can be applied.
    func validationError() -> String? {
        guard mode == .manual else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:[]")
        if trimmedHost.isEmpty { return "Enter a proxy server host name or address." }
        if trimmedHost.count > 253 || !trimmedHost.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            return "Enter only the proxy host name or IP address, without a scheme, path or credentials."
        }
        if !(1...65_535).contains(port) { return "Enter a proxy port between 1 and 65535." }
        if authenticated {
            if username.isEmpty { return "Enter the proxy user name." }
            if username.contains(":") || username.contains(where: \.isNewline) || username.count > 256 {
                return "The proxy user name cannot contain colons or line breaks."
            }
        }
        return nil
    }

    /// CFNetwork proxy dictionary for `URLSessionConfiguration.connectionProxyDictionary`.
    /// nil keeps the system configuration; an empty dictionary disables proxies.
    func connectionProxyDictionary(password: String? = nil) -> [AnyHashable: Any]? {
        switch mode {
        case .system: return nil
        case .none: return [:]
        case .manual:
            guard validationError() == nil else { return nil }
            switch kind {
            case .http:
                return [kCFNetworkProxiesHTTPEnable as String: 1, kCFNetworkProxiesHTTPProxy as String: trimmedHost, kCFNetworkProxiesHTTPPort as String: port,
                        kCFNetworkProxiesHTTPSEnable as String: 1, kCFNetworkProxiesHTTPSProxy as String: trimmedHost, kCFNetworkProxiesHTTPSPort as String: port]
            case .socks:
                var dictionary: [AnyHashable: Any] = [kCFNetworkProxiesSOCKSEnable as String: 1, kCFNetworkProxiesSOCKSProxy as String: trimmedHost,
                                                      kCFNetworkProxiesSOCKSPort as String: port]
                if authenticated, let password {
                    dictionary[kCFStreamPropertySOCKSUser as String] = username
                    dictionary[kCFStreamPropertySOCKSPassword as String] = password
                }
                return dictionary
            }
        }
    }

    /// Environment for Homebrew/mas subprocesses. Credentials are deliberately not exported:
    /// process environments are visible to other processes of the same user.
    func commandEnvironment() -> [String: String] {
        guard mode == .manual, validationError() == nil else { return [:] }
        let hostPart = trimmedHost.contains(":") && !trimmedHost.hasPrefix("[") ? "[\(trimmedHost)]" : trimmedHost
        let value = (kind == .socks ? "socks5://" : "http://") + "\(hostPart):\(port)"
        if kind == .socks { return ["all_proxy": value, "ALL_PROXY": value] }
        return ["http_proxy": value, "https_proxy": value, "HTTP_PROXY": value, "HTTPS_PROXY": value]
    }

    func storedPassword(store: KeychainStore = KeychainStore(service: ProxySettings.keychainService)) -> String? {
        guard mode == .manual, authenticated, !username.isEmpty else { return nil }
        return try? store.read(account: username)
    }

    /// Applies the saved proxy to a session configuration used by this app.
    static func apply(to configuration: URLSessionConfiguration, settings: ProxySettings = .load()) {
        if let dictionary = settings.connectionProxyDictionary(password: settings.kind == .socks ? settings.storedPassword() : nil) {
            configuration.connectionProxyDictionary = dictionary
        }
    }

    /// Answers HTTP proxy authentication challenges only; server challenges get default handling.
    static func respond(to challenge: URLAuthenticationChallenge, settings: ProxySettings = .load(),
                        password: (ProxySettings) -> String? = { $0.storedPassword() }) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.isProxy(), settings.mode == .manual, settings.authenticated,
              challenge.previousFailureCount == 0, let secret = password(settings) else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(user: settings.username, password: secret, persistence: .forSession))
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
        return "Keychain error \(status): \(message)"
    }
}

/// Minimal generic-password wrapper over the Security framework.
struct KeychainStore: Sendable {
    let service: String

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func read(account: String) throws -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    func save(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let update = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var item = query(account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        item[kSecAttrLabel as String] = "Update Workbench proxy password"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// Bounded HTTPS-only metadata fetches that honor the proxy settings.
enum HTTPFetcher {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func isSafeHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil
    }

    static func fetch(_ url: URL, maximumBytes: Int, headers: [String: String] = [:], timeout: TimeInterval = 25) async throws -> (Data, HTTPURLResponse) {
        guard isSafeHTTPS(url) else { throw Failure(message: "Only HTTPS URLs without embedded credentials are supported.") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        ProxySettings.apply(to: configuration)
        let delegate = BoundedHTTPSDelegate(maximumBytes: Int64(maximumBytes))
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue(AppIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (file, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse else { throw Failure(message: "The server did not return an HTTP response.") }
        let size = (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard size <= maximumBytes else { throw Failure(message: "The response exceeded the \(maximumBytes / 1_048_576) MB limit.") }
        return (try Data(contentsOf: file), http)
    }
}

enum AppIdentity {
    static let version = "0.3.2"
    static let userAgent = "UpdateWorkbench/\(version)"
}

final class BoundedHTTPSDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let maximumBytes: Int64
    init(maximumBytes: Int64) { self.maximumBytes = maximumBytes }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(HTTPFetcher.isSafeHTTPS) == true ? request : nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        ProxySettings.respond(to: challenge)
    }
}
