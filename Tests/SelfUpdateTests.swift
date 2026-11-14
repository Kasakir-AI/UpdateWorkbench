import CryptoKit
import Foundation
@testable import UpdateWorkbench

/// 0.5.0: apps without a Developer ID team (Update Workbench itself) update only through their own Ed25519 key,
/// plus the self-update helpers and the History badge.
enum SelfUpdateTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if !(try condition()) { throw Failure(description: message) }
    }

    static func run() async throws {
        try await testKeyAnchoredInstalls()
        try testHelpers()
        try testHistoryBadge()
        print("PASS: Ed25519-anchored installs of team-less apps (signed, unsigned, wrong key, swapped key, no key, team downgrade), self-update helpers, History badge")
    }

    static func testKeyAnchoredInstalls() async throws {
        let fm = FileManager.default
        let work = TestTemp.root.appendingPathComponent("uw-self-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let otherKey = Curve25519.Signing.PrivateKey()

        /// A fixture app; no "team" means FixtureVerifier treats it as ad-hoc signed.
        func app(_ folder: URL, version: String, edKey: String?, team: String? = nil) throws -> URL {
            var extra: [String: Any] = [:]
            if let edKey { extra["SUPublicEDKey"] = edKey }
            let app = try DiskImageTests.app(in: folder, name: "Workbench", version: version, team: team ?? "", extra: extra)
            if team == nil {
                var info = AppBundleInfo.read(app); info.removeValue(forKey: "UWFixtureTeam")
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
            }
            return app
        }
        func zip(_ app: URL, _ name: String) throws -> URL {
            let output = work.appendingPathComponent("\(name).zip")
            try SyncCommand.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, output.path])
            return output
        }
        func installed(_ name: String, edKey: String?, team: String? = nil) throws -> URL {
            try app(work.appendingPathComponent(name).appendingPathComponent("Applications"), version: "1.0", edKey: edKey, team: team)
        }
        func install(_ payload: URL, into target: URL, signer: Curve25519.Signing.PrivateKey?) async throws -> InstallOutcome {
            let signature = try signer.map { try $0.signature(for: Data(contentsOf: payload)).base64EncodedString() }
            let release = SparkleRelease(version: "2.0", downloadURL: URL(string: "https://example.com/Workbench.zip")!, releaseNotesURL: nil, signature: signature)
            return try await SparkleBackend.installPayload(payload, fileExtension: "zip", release: release, target: target,
                                                           options: InstallOptions(trustedSigners: nil, verifier: FixtureVerifier(), appName: "Workbench"))
        }
        func version(_ app: URL) -> String? { AppBundleInfo.read(app)["CFBundleShortVersionString"] as? String }
        func failure(_ fragment: String, _ label: String, _ body: () async throws -> Void) async throws {
            try await DiskImageTests.expectFailure(fragment, label, body)
        }

        let good = try zip(try app(work.appendingPathComponent("src-good"), version: "2.0", edKey: publicKey), "good")
        var target = try installed("t-good", edKey: publicKey)
        let outcome = try await install(good, into: target, signer: key)
        try expect(version(target) == "2.0" && outcome.message.contains("Ed25519 update key"), "A team-less app updates with its own signed archive: \(outcome.message)")
        try expect(DiskImageTests.leftovers(beside: target).isEmpty, "No staging or previous copy is left behind")

        target = try installed("t-unsigned", edKey: publicKey)
        try await failure("Ed25519", "Unsigned archive") { _ = try await install(good, into: target, signer: nil) }
        try await failure("Ed25519", "Archive signed by another key") { _ = try await install(good, into: target, signer: otherKey) }
        try expect(version(target) == "1.0", "Rejected updates leave the installed app untouched")

        let swapped = try zip(try app(work.appendingPathComponent("src-swapped"), version: "2.0", edKey: otherKey.publicKey.rawRepresentation.base64EncodedString()), "swapped")
        target = try installed("t-swapped", edKey: publicKey)
        try await failure("same Ed25519 update key", "Update that replaces the update key") { _ = try await install(swapped, into: target, signer: key) }

        let keyless = try zip(try app(work.appendingPathComponent("src-keyless"), version: "2.0", edKey: nil), "keyless")
        target = try installed("t-keyless", edKey: nil)
        try await failure("Ad-hoc or unsigned", "A team-less app without an update key") { _ = try await install(keyless, into: target, signer: nil) }

        // A Developer ID app never accepts a team-less update, even one signed with its update key.
        target = try installed("t-team", edKey: publicKey, team: "TEAMA11111")
        try await failure("Ad-hoc or unsigned", "Team-signed app offered a team-less update") { _ = try await install(good, into: target, signer: key) }
        try expect(version(target) == "1.0", "The Developer ID app stays as installed")
    }

    static func testHelpers() throws {
        try expect(SelfUpdate.installedWithHomebrew(exists: { $0 == "/opt/homebrew/Caskroom/update-workbench" }), "Apple silicon Caskroom detected")
        try expect(SelfUpdate.installedWithHomebrew(exists: { $0 == "/usr/local/Caskroom/update-workbench" }), "Intel Caskroom detected")
        try expect(!SelfUpdate.installedWithHomebrew(exists: { _ in false }), "No Caskroom folder means a direct install")
        let folder = TestTemp.root.appendingPathComponent("uw-selfitem-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = try DiskImageTests.app(in: folder, name: "Update Workbench", bundleID: "local.updateworkbench.app", version: "0.5.0", team: "", extra: ["CFBundleDisplayName": "Update Workbench", "SUPublicEDKey": "a2V5"])
        let direct = SelfUpdate.currentItem(bundle: app, homebrew: false)
        try expect(direct.provider == .sparkle && direct.token == nil && direct.installedVersion == "0.5.0" && direct.requiresSparkleSignature == true, "Direct install updates from its signed feed")
        try expect(direct.id == app.resolvingSymlinksInPath().path && direct.bundleID == "local.updateworkbench.app", "Same ID the scanner uses")
        let brew = SelfUpdate.currentItem(bundle: app, homebrew: true)
        try expect(brew.provider == .homebrewCask && brew.token == "update-workbench", "Homebrew install updates through its cask")
        var outdated = brew; outdated.isOutdated = true; outdated.latestVersion = "0.5.1"
        try expect(outdated.canUpdateDirectly && (try Engine.homebrewArguments(for: outdated)).last == "update-workbench", "The cask can be upgraded from inside the app")
        try expect(!direct.isSelf, "A fixture copy is not the running app")
    }

    static func testHistoryBadge() throws {
        let now = Date()
        func entry(_ id: String, _ result: HistoryEntry.Result, ago: TimeInterval) -> HistoryEntry {
            HistoryEntry(date: now.addingTimeInterval(-ago), itemID: id, appName: id, fromVersion: "1", toVersion: "2", source: "Sparkle", result: result, message: "")
        }
        try expect(HistoryEntry.unresolvedFailures([]) == 0, "Empty history has no badge")
        try expect(HistoryEntry.unresolvedFailures([entry("a", .failed, ago: 100), entry("a", .installed, ago: 10)]) == 0, "A later success clears a failure")
        try expect(HistoryEntry.unresolvedFailures([entry("a", .installed, ago: 100), entry("a", .failed, ago: 10), entry("b", .failed, ago: 5), entry("b", .failed, ago: 50)]) == 2, "Counts apps whose latest attempt failed")
    }
}
