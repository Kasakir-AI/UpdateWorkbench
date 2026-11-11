import Foundation

struct SecurityReport: Codable, Sendable {
    let summary: String
    let details: String
}

/// On-demand, read-only observations of the currently installed app.
/// Signature validity and Gatekeeper assessment are separate facts, not a safety guarantee.
enum SecurityBackend {
    static func inspect(path: String) async -> SecurityReport {
        let requested = URL(fileURLWithPath: path).standardizedFileURL
        let canonical = requested.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard path.hasPrefix("/"), requested.pathExtension.lowercased() == "app",
              canonical.pathExtension.lowercased() == "app",
              FileManager.default.fileExists(atPath: canonical.path, isDirectory: &directory), directory.boolValue,
              Bundle(url: canonical) != nil else {
            return SecurityReport(summary: "Security inspection unavailable", details: "Choose an existing application bundle at an absolute path.")
        }
        let observedAt = Date().formatted(date: .abbreviated, time: .standard)
        let metadata = await observation("/usr/bin/codesign", ["--display", "--verbose=4", canonical.path], timeout: 10)
        let verification = await observation("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--all-architectures", canonical.path], timeout: 20)
        let gatekeeper = await observation("/usr/sbin/spctl", ["--assess", "--type", "execute", "--verbose=2", canonical.path], timeout: 25)
        return report(path: canonical.path, observedAt: observedAt, metadata: metadata, verification: verification, gatekeeper: gatekeeper)
    }

    struct Observation: Sendable {
        let status: Int32?
        let text: String
    }

    private static func observation(_ executable: String, _ arguments: [String], timeout: TimeInterval) async -> Observation {
        do {
            let result = try await CommandRunner.run(executable, arguments, timeout: timeout)
            return Observation(status: result.status, text: (result.output + "\n" + result.errorOutput).trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return Observation(status: nil, text: error.localizedDescription)
        }
    }

    /// Separate formatting from subprocess invocation so status handling is testable offline.
    static func report(path: String, observedAt: String, metadata: Observation, verification: Observation, gatekeeper: Observation) -> SecurityReport {
        let signatureState = state(verification.status, passed: "Code signature verifies", failed: "Code signature did not verify")
        let gatekeeperState = state(gatekeeper.status, passed: "Gatekeeper accepted", failed: "Gatekeeper did not accept")
        let selected = metadata.text.components(separatedBy: .newlines).filter { line in
            ["Identifier=", "Format=", "CodeDirectory ", "Signature=", "Authority=", "TeamIdentifier=", "Runtime Version=", "Notarization Ticket="].contains(where: line.hasPrefix)
        }
        let identity = selected.isEmpty ? "Signing identity was not reported." : selected.joined(separator: "\n")
        let metadataStatus = metadata.status.map { "exit \($0)" } ?? "unavailable"
        let details = """
        Observed: \(observedAt)
        Application: \(path)

        Signing identity (\(metadataStatus))
        \(identity)
        \(metadata.status != 0 ? limited(metadata.text) : "")

        Code signature verification: \(signatureState)
        \(resultDetails(verification))

        Gatekeeper assessment: \(gatekeeperState)
        \(resultDetails(gatekeeper))

        This is a snapshot of the current bundle and macOS assessment. A valid signature identifies signed contents; Gatekeeper is a separate execution policy assessment. Neither proves that an app is safe or that a future update is trustworthy. Assessment can change with macOS policy, network access, or changes to the app.
        """
        return SecurityReport(summary: "\(signatureState). \(gatekeeperState).", details: details)
    }

    private static func state(_ status: Int32?, passed: String, failed: String) -> String {
        guard let status else { return "Unavailable" }
        return status == 0 ? passed : "\(failed) (exit \(status))"
    }

    private static func resultDetails(_ observation: Observation) -> String {
        if observation.text.isEmpty { return observation.status == 0 ? "Command completed without diagnostics." : "No diagnostic output was returned." }
        return limited(observation.text)
    }

    private static func limited(_ text: String) -> String {
        let limit = 8_000
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n[Remaining diagnostic text omitted.]"
    }
}
