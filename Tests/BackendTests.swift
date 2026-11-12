import AppKit
import CryptoKit
import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}

@main
struct BackendTests {
    static func main() async throws {
        try GitHubTests.run()
        try await FeatureTests.run()
        try PresentationTests.run()
        try ArchiveSafetyTests.run()
        try WorkflowTests.run()
        try await DiskImageTests.run()
        try testHomebrewDestination()
        try testAppcasts()
        try testSignatures()
        try testSerializationAndAvailability()
        try testReadOnlyDiscovery()
        try await testCommands()
        try await testRejectedUpdate()
        print("PASS: appcasts, archive authentication, serialization, discovery, command streams/timeouts, rejected updates")
    }

    private static func testHomebrewDestination() throws {
        let item = UpdateItem(id: "custom", name: "Custom", path: "/Users/example/My Apps/Custom.app", installedVersion: "1", provider: .homebrewCask, token: "custom", isOutdated: true)
        let arguments = try Engine.homebrewArguments(for: item)
        try expect(arguments.contains("--appdir=/Users/example/My Apps"), "A custom application folder must be passed as a single literal argument")
        try expect(arguments.last == "custom", "The cask token must remain a separate validated argument")
        for token in ["--force", "../../tmp/cask.rb", "custom; touch /tmp/unsafe"] {
            var bad = item; bad.token = token
            var rejected = false
            do { _ = try Engine.homebrewArguments(for: bad) } catch { rejected = true }
            try expect(rejected, "Untrusted cask tokens must fail before command execution")
        }
    }

    private static func testAppcasts() throws {
        let xml = """
        <?xml version="1.0"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        <item><sparkle:channel>beta</sparkle:channel><enclosure url="https://vendor.example/beta.zip" sparkle:shortVersionString="9.0" /></item>
        <item><enclosure url="http://vendor.example/insecure.zip" sparkle:shortVersionString="8.0" /></item>
        <item><enclosure url="https://vendor.example/delta.zip" sparkle:shortVersionString="7.0" sparkle:deltaFrom="1.0" /></item>
        <item><sparkle:minimumSystemVersion>999.0</sparkle:minimumSystemVersion><enclosure url="https://vendor.example/newos.zip" sparkle:shortVersionString="6.0" /></item>
        <item><enclosure url="https://vendor.example/wrongcpu.zip" sparkle:shortVersionString="5.0" sparkle:arch="mips" /></item>
        <item><sparkle:releaseNotesLink>https://vendor.example/notes</sparkle:releaseNotesLink><enclosure url="https://vendor.example/stable.dmg" sparkle:shortVersionString="2.10" sparkle:edSignature="signature-fixture" /></item>
        <item><enclosure url="https://vendor.example/old.zip" sparkle:shortVersionString="2.9" /></item>
        </channel></rss>
        """
        let data = Data(xml.utf8)
        let release = try SparkleBackend.parseAppcast(data, installedVersion: "2.0")
        try expect(release?.version == "2.10", "Newest compatible stable release must be selected numerically")
        try expect(release?.downloadURL.absoluteString == "https://vendor.example/stable.dmg", "Unsupported appcast items must be excluded")
        try expect(release?.releaseNotesURL?.absoluteString == "https://vendor.example/notes", "Release notes must retain the matching item")
        try expect(release?.signature == "signature-fixture", "The archive signature must be retained")
        let none = try SparkleBackend.parseAppcast(data, installedVersion: "2.10")
        try expect(none == nil, "The installed latest version must not be offered again")
        try expect(SparkleBackend.isNewer("1.10", than: "1.9"), "Version components must compare numerically")
        var rejected = false
        do { _ = try SparkleBackend.parseAppcast(Data("<bad".utf8), installedVersion: "1") }
        catch { rejected = true }
        try expect(rejected, "Malformed XML must fail rather than report up-to-date")
    }

    private static func testSignatures() throws {
        let temporary = TestTemp.root.appendingPathComponent("UpdateWorkbenchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let archive = temporary.appendingPathComponent("payload.zip")
        let bytes = Data("A locally generated, inert update payload".utf8)
        try bytes.write(to: archive)
        let key = Curve25519.Signing.PrivateKey()
        let signature = try key.signature(for: bytes).base64EncodedString()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        try SparkleBackend.verifyArchiveSignature(archive, signature: signature, publicKey: publicKey)
        let otherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        var wrongKeyRejected = false
        do { try SparkleBackend.verifyArchiveSignature(archive, signature: signature, publicKey: otherKey) }
        catch { wrongKeyRejected = true }
        try expect(wrongKeyRejected, "A valid signature from a different publisher key must be rejected")
        for invalid in [nil, "invalid-base64!", Data(repeating: 0, count: 64).base64EncodedString()] as [String?] {
            var rejected = false
            do { try SparkleBackend.verifyArchiveSignature(archive, signature: invalid, publicKey: publicKey) }
            catch { rejected = true }
            try expect(rejected, "Missing or invalid archive signatures must be rejected")
        }
        try Data("modified payload".utf8).write(to: archive)
        var tamperingRejected = false
        do { try SparkleBackend.verifyArchiveSignature(archive, signature: signature, publicKey: publicKey) }
        catch { tamperingRejected = true }
        try expect(tamperingRejected, "A valid signature must not authenticate modified bytes")
        var keyRejected = false
        do { try SparkleBackend.verifyArchiveSignature(archive, signature: signature, publicKey: "invalid") }
        catch { keyRejected = true }
        try expect(keyRejected, "Malformed installed public keys must fail closed")
    }

    private static func testSerializationAndAvailability() throws {
        let release = SparkleRelease(version: "2.0", downloadURL: URL(string: "https://vendor.example/app.dmg")!, releaseNotesURL: nil, signature: "signature")
        let original = UpdateItem(id: "fixture", name: "Fixture", bundleID: "test.fixture", path: "/Applications/Fixture.app",
                                  installedVersion: "1.0", latestVersion: "2.0", provider: .sparkle,
                                  feedURL: URL(string: "https://vendor.example/feed.xml"), isOutdated: true,
                                  detail: "Fixture only", sparkleRelease: release)
        let restored = try JSONDecoder().decode(UpdateItem.self, from: JSONEncoder().encode(original))
        try expect(restored.id == original.id && restored.path == original.path && restored.sparkleRelease?.signature == "signature", "Update plans must survive persistence with signature and destination")
        try expect(restored.canUpdateDirectly, "A discovered Sparkle release and destination should permit the installation attempt")
        var item = original
        item.path = nil
        try expect(!item.canUpdateDirectly, "Missing Sparkle destinations must disable update actions")
        item = original; item.sparkleRelease = nil
        try expect(!item.canUpdateDirectly, "Missing release metadata must disable update actions")
        item = original; item.isOutdated = false
        try expect(!item.canUpdateDirectly, "Current apps must not offer direct updates")
        item = original; item.provider = .manual
        try expect(!item.canUpdateDirectly, "Manual sources must not claim direct update support")
        item = original; item.provider = .homebrewCask; item.token = nil
        try expect(!item.canUpdateDirectly, "Package sources require a package identifier")
        item.token = "fixture"
        try expect(item.canUpdateDirectly, "A stale package with an identifier should permit the package manager attempt")
        let legacy = Data(#"{"version":"2","downloadURL":"https://vendor.example/app.zip","releaseNotesURL":null}"#.utf8)
        try expect(tryDecodeRelease(legacy)?.signature == nil, "Previously saved releases without signatures must decode")
    }

    private static func tryDecodeRelease(_ data: Data) -> SparkleRelease? { try? JSONDecoder().decode(SparkleRelease.self, from: data) }

    private static func testReadOnlyDiscovery() throws {
        let apps = Engine.installedApps()
        try expect(Set(apps.map(\.id)).count == apps.count, "Discovery must not duplicate canonical app paths")
        for item in apps {
            guard let path = item.path else { throw TestFailure(description: "A discovered app must retain its path") }
            let url = URL(fileURLWithPath: path)
            try expect(url.pathExtension.lowercased() == "app", "Discovery must return application bundles")
            try expect(item.id == url.resolvingSymlinksInPath().path, "Discovery identity must use canonical paths")
            try expect(Bundle(url: url)?.bundleIdentifier == item.bundleID, "Discovered identity must match the bundle")
            try expect(item.latestVersion == nil && !item.isOutdated && !item.canUpdateDirectly, "Inventory alone must not invent update availability")
            if item.provider == .sparkle { try expect(item.feedURL?.scheme == "https", "Only HTTPS appcasts may become check sources") }
            if item.provider == .appStore {
                try expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path), "App Store discovery requires a receipt")
            }
        }
        // No fixtures are created in /Applications: this inspects only already installed metadata.
        print("Read-only discovery validated \(apps.count) installed app records")
    }

    private static func testCommands() async throws {
        let literal = "$(do-not-execute); spaces * ' \""
        let args = try await CommandRunner.run("/usr/bin/printf", ["%s", literal])
        try expect(args.status == 0 && args.output == literal, "Process arguments must remain literal")
        let streams = try await CommandRunner.run("/bin/sh", ["-c", "i=0; while [ \"$i\" -lt 2048 ]; do printf '%0128d' 1; printf '%0128d' 2 >&2; i=$((i+1)); done; exit 7"], timeout: 10)
        try expect(streams.status == 7, "Nonzero process status must be preserved")
        try expect(streams.output.utf8.count == 262_144 && streams.errorOutput.utf8.count == 262_144, "Both large output streams must drain completely without a pipe deadlock")
        let started = Date()
        var timedOut = false
        do { _ = try await CommandRunner.run("/bin/sleep", ["30"], timeout: 0.15) }
        catch { timedOut = true }
        try expect(timedOut && Date().timeIntervalSince(started) < 5, "A timed-out process must report failure promptly")
        let stubbornStart = Date()
        var stubbornTimedOut = false
        do { _ = try await CommandRunner.run("/bin/sh", ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.15) }
        catch { stubbornTimedOut = true }
        try expect(stubbornTimedOut && Date().timeIntervalSince(stubbornStart) < 5, "A SIGTERM-ignoring process must be killed and report failure promptly")
        let inheritedStart = Date()
        let inherited = try await CommandRunner.run("/bin/sh", ["-c", "sleep 2 & printf done"], timeout: 0.5)
        try expect(inherited.output == "done" && Date().timeIntervalSince(inheritedStart) < 1.8, "Inherited output descriptors must not delay a completed parent")
        var missingRejected = false
        do { _ = try await CommandRunner.run("/nonexistent/updateworkbench-test-executable", []) }
        catch { missingRejected = true }
        try expect(missingRejected, "Launch failures must propagate")
    }

    private static func testRejectedUpdate() async throws {
        let item = UpdateItem(id: "manual-fixture", name: "Manual fixture", installedVersion: "1", provider: .manual, isOutdated: true)
        var rejected = false
        do { _ = try await Engine().update(item) }
        catch { rejected = true }
        try expect(rejected, "Unsupported direct updates must fail before any command executes")
    }
}
