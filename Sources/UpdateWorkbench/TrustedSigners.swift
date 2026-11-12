import CryptoKit
import Foundation
import Security

/// Runs a tool synchronously with literal arguments and optional standard input.
enum SyncCommand {
    struct Failure: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    static func status(_ path: String, _ arguments: [String], input: String? = nil) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        let inputPipe = input.map { _ in Pipe() }
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        try process.run()
        if let inputPipe, let input {
            inputPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inputPipe.fileHandleForWriting.close()
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @discardableResult
    static func run(_ path: String, _ arguments: [String], input: String? = nil) throws -> String {
        let result = try status(path, arguments, input: input)
        guard result.status == 0 else {
            throw Failure(message: "\(URL(fileURLWithPath: path).lastPathComponent) failed: \(result.output.suffix(2000))")
        }
        return result.output
    }
}

/// Who signed an app: Developer ID team, certificate chain and leaf certificate details.
struct SignerIdentity: Codable, Equatable, Sendable {
    var teamID: String
    var authorities: [String] = []
    var identifier: String?
    var signedTime: String?
    var leafSHA256: String?
    var leafExpires: Date?
    var gatekeeper: String?

    /// "Developer ID Application: Example Inc (TEAMID)" -> "Example Inc".
    var signerName: String {
        guard var name = authorities.first else { return "Unknown signer" }
        if let colon = name.firstIndex(of: ":") { name = String(name[name.index(after: colon)...]).trimmingCharacters(in: .whitespaces) }
        if name.hasSuffix(")"), let open = name.lastIndex(of: "(") { name = String(name[..<open]).trimmingCharacters(in: .whitespaces) }
        return name.isEmpty ? "Unknown signer" : name
    }
    var certificateKind: String {
        guard let first = authorities.first, let colon = first.firstIndex(of: ":") else { return "Certificate" }
        return String(first[..<colon])
    }

    /// Parses `codesign -d --verbose=4` output. Returns nil for ad-hoc or unsigned code.
    static func parse(codesignOutput output: String) -> SignerIdentity? {
        var authorities: [String] = []
        var values: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals]), value = String(line[line.index(after: equals)...])
            if key == "Authority" { authorities.append(value) } else if values[key] == nil { values[key] = value }
        }
        guard let team = values["TeamIdentifier"], !team.isEmpty, team != "not set" else { return nil }
        return SignerIdentity(teamID: team, authorities: authorities, identifier: values["Identifier"],
                              signedTime: values["Timestamp"] ?? values["Signed Time"])
    }

    /// SHA-256 fingerprint and expiry of a DER certificate.
    static func certificateDetails(_ der: Data) -> (sha256: String, expires: Date?) {
        let fingerprint = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
        var expires: Date?
        if let certificate = SecCertificateCreateWithData(nil, der as CFData),
           let values = SecCertificateCopyValues(certificate, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [String: Any],
           let entry = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any],
           let number = entry[kSecPropertyKeyValue as String] as? NSNumber {
            expires = Date(timeIntervalSinceReferenceDate: number.doubleValue)
        }
        return (fingerprint, expires)
    }
}

/// Signature checks used by the installer. Tests substitute a fake to model Developer ID teams.
protocol SignatureVerifier: Sendable {
    /// `codesign --verify --deep --strict --all-architectures`.
    func verify(_ app: URL) throws
    /// Gatekeeper (`spctl --assess --type execute`); returns the assessment source.
    func assess(_ app: URL) throws -> String
    /// Signing identity; throws for ad-hoc or unsigned apps.
    func identity(_ app: URL) throws -> SignerIdentity
}

struct CodesignVerifier: SignatureVerifier {
    func verify(_ app: URL) throws {
        try SyncCommand.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--all-architectures", app.path])
    }

    func assess(_ app: URL) throws -> String {
        let output = try SyncCommand.run("/usr/sbin/spctl", ["--assess", "--type", "execute", "--verbose=2", app.path])
        return output.split(separator: "\n").first { $0.hasPrefix("source=") }.map { String($0.dropFirst("source=".count)) } ?? "accepted"
    }

    func identity(_ app: URL) throws -> SignerIdentity {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("UpdateWorkbench-certs-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let prefix = folder.appendingPathComponent("cert").path
        let output = try SyncCommand.run("/usr/bin/codesign", ["-d", "--verbose=4", "--extract-certificates=\(prefix)", app.path])
        guard var identity = SignerIdentity.parse(codesignOutput: output) else {
            throw SparkleBackend.Failure(message: "Ad-hoc or unsigned apps cannot be replaced directly.")
        }
        if let der = try? Data(contentsOf: URL(fileURLWithPath: prefix + "0")) {
            let details = SignerIdentity.certificateDetails(der)
            identity.leafSHA256 = details.sha256; identity.leafExpires = details.expires
        }
        return identity
    }
}

/// Thrown when an otherwise valid update (codesign and Gatekeeper passed) is signed by a
/// different Developer ID team than the installed app and no approval exists yet.
struct SignerChange: LocalizedError, Identifiable, Sendable, Equatable {
    var id = UUID()
    let appName: String
    let bundleID: String
    let version: String
    let installed: SignerIdentity
    let candidate: SignerIdentity
    var errorDescription: String? {
        "The update is signed by a different developer team (\(candidate.signerName), \(candidate.teamID)) than the installed app (\(installed.signerName), \(installed.teamID)). It was not installed. Review the new signer and approve it for this app only if you trust it."
    }
}

/// A user's explicit approval of a new signing team for one app.
struct TrustedSignerApproval: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var bundleID: String
    var appName: String
    var teamID: String
    var signerName: String
    var previousTeamID: String
    var previousSignerName: String
    var certificateSHA256: String?
    var approvedAt: Date
}

/// Approvals persisted as JSON (owner-only permissions). Nothing is ever approved automatically.
struct TrustedSignerStore: Sendable {
    let fileURL: URL

    static var standard: TrustedSignerStore {
        TrustedSignerStore(fileURL: AppSupport.folder.appendingPathComponent("trusted-signers.json"))
    }

    func load() -> [TrustedSignerApproval] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return ((try? decoder.decode([TrustedSignerApproval].self, from: data)) ?? []).sorted { $0.approvedAt > $1.approvedAt }
    }

    func isApproved(bundleID: String, teamID: String) -> Bool {
        load().contains { $0.bundleID == bundleID && $0.teamID == teamID }
    }

    @discardableResult
    func approve(_ change: SignerChange, now: Date = Date()) throws -> TrustedSignerApproval {
        var approvals = load().filter { !($0.bundleID == change.bundleID && $0.teamID == change.candidate.teamID) }
        let approval = TrustedSignerApproval(bundleID: change.bundleID, appName: change.appName, teamID: change.candidate.teamID,
                                             signerName: change.candidate.signerName, previousTeamID: change.installed.teamID,
                                             previousSignerName: change.installed.signerName,
                                             certificateSHA256: change.candidate.leafSHA256, approvedAt: now)
        approvals.insert(approval, at: 0)
        try save(approvals)
        return approval
    }

    func revoke(_ id: UUID) throws {
        try save(load().filter { $0.id != id })
    }

    private func save(_ approvals: [TrustedSignerApproval]) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AppSupport.write(try encoder.encode(approvals), to: fileURL)
    }
}

/// ~/Library/Application Support/Update Workbench, created on demand with owner-only permissions.
enum AppSupport {
    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Update Workbench", isDirectory: true)
    }

    static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: [.atomic])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
