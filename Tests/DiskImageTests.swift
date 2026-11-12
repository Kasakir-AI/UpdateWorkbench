import CryptoKit
import Foundation

/// Full DMG install path with fixture disk images built by hdiutil in a temporary folder:
/// good, wrong team, approved team, multiple apps, broken signature, version mismatch, license agreement,
/// plus the same signer check for a ZIP. Targets are fixture apps in the temporary folder only.
enum DiskImageTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if !(try condition()) { throw Failure(description: message) }
    }

    static let bundleID = "com.example.workbench-fixture"

    static func run() async throws {
        let fm = FileManager.default
        let work = TestTemp.root.appendingPathComponent("uw-dmg-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let store = TrustedSignerStore(fileURL: work.appendingPathComponent("trusted-signers.json"))

        let good = try dmg("good", in: work, apps: [
            try app(in: work.appendingPathComponent("src-good"), version: "2.0", team: "TEAMA11111"),
            try app(in: work.appendingPathComponent("src-good"), name: "Helper Tool", bundleID: "com.example.helper", version: "9.0", team: "TEAMA11111"),
        ])
        let wrongTeam = try dmg("wrong-team", in: work, apps: [try app(in: work.appendingPathComponent("src-wrong"), version: "2.0", team: "TEAMB22222", signer: "Someone Else")])
        let multiple = try dmg("multiple", in: work, apps: [
            try app(in: work.appendingPathComponent("src-multi"), version: "2.0", team: "TEAMA11111"),
            try app(in: work.appendingPathComponent("src-multi"), name: "Fixture Copy", version: "2.0", team: "TEAMA11111"),
        ])
        let broken = try dmg("broken", in: work, apps: [try app(in: work.appendingPathComponent("src-broken"), version: "2.0", team: "TEAMA11111", extra: ["UWFixtureBroken": true])])
        let rejected = try dmg("gatekeeper", in: work, apps: [try app(in: work.appendingPathComponent("src-gk"), version: "2.0", team: "TEAMB22222", extra: ["UWFixtureRejected": true])])
        let licensed = try dmg("license", in: work, apps: [try app(in: work.appendingPathComponent("src-sla"), version: "2.0", team: "TEAMA11111")], license: true)

        func release(_ payload: URL, version: String = "2.0", checksum: Bool = true) throws -> SparkleRelease {
            SparkleRelease(version: version, downloadURL: URL(string: "https://downloads.example.com/\(payload.lastPathComponent)")!, releaseNotesURL: nil,
                           sha512: checksum ? Data(SHA512.hash(data: try Data(contentsOf: payload))).base64EncodedString() : nil)
        }
        func options(accept: Bool = false) -> InstallOptions {
            InstallOptions(trustedSigners: store, acceptLicense: accept, verifier: FixtureVerifier(), appName: "Fixture")
        }
        func install(_ payload: URL, into target: URL, version: String = "2.0", accept: Bool = false, kind: String = "dmg") async throws -> InstallOutcome {
            try await SparkleBackend.installPayload(payload, fileExtension: kind, release: try release(payload, version: version), target: target, options: options(accept: accept))
        }
        func version(_ app: URL) -> String? { AppBundleInfo.read(app)["CFBundleShortVersionString"] as? String }
        func assertDetached(_ label: String) throws {
            let info = try SyncCommand.run("/usr/bin/hdiutil", ["info"])
            try expect(!info.contains(work.path) && !info.contains(work.resolvingSymlinksInPath().path), "\(label): the disk image must be detached")
        }

        // 1. Good DMG: exactly one matching app among several, installed with no copy left behind; the DMG is detached.
        var target = try installed(in: work, "t-good")
        let outcome = try await install(good, into: target)
        try expect(version(target) == "2.0" && !outcome.signerApproved, "Good DMG installs 2.0")
        try expect(leftovers(beside: target).isEmpty, "No previous-version or staging copy is left beside the app: \(leftovers(beside: target))")
        try expect(outcome.message.contains("previous version was removed"), "The outcome says the old copy is gone")

        // 2. Wrong team: stops with SignerChange before touching the app.
        target = try installed(in: work, "t-wrong")
        do { _ = try await install(wrongTeam, into: target); throw Failure(description: "A different team must not install without approval") }
        catch let change as SignerChange {
            try expect(change.installed.teamID == "TEAMA11111" && change.candidate.teamID == "TEAMB22222" && change.bundleID == bundleID, "SignerChange names both teams")
            try expect(change.candidate.signerName == "Someone Else" && change.candidate.gatekeeper == "Notarized Developer ID", "Signer details and Gatekeeper result are shown")
            try expect(version(target) == "1.0" && leftovers(beside: target).isEmpty, "Nothing changed for an unapproved team")
            try assertDetached("wrong team")

            // 3. Approved team: the same DMG installs after the user's explicit approval.
            try store.approve(change)
            let approved = try await install(wrongTeam, into: target)
            try expect(version(target) == "2.0" && approved.signerApproved && approved.message.contains("TEAMB22222"), "Approved team installs and says so")
            try assertDetached("approved team")
            try store.revoke(store.load()[0].id)
        }

        // 4. Multiple matching apps are refused.
        target = try installed(in: work, "t-multi")
        try await expectFailure("2 apps", "multiple matching apps") { _ = try await install(multiple, into: target) }
        try expect(version(target) == "1.0", "Multiple apps leave the app unchanged")
        try assertDetached("multiple")

        // 5. Broken code signature, Gatekeeper rejection (checked before any signer question), wrong version, bad checksum.
        try await expectFailure("sealed resource", "broken signature") { _ = try await install(broken, into: target) }
        try await expectFailure("spctl", "Gatekeeper rejection wins over a team question") { _ = try await install(rejected, into: target) }
        try await expectFailure("does not match the selected update", "version mismatch") { _ = try await install(good, into: target, version: "2.1") }
        try await expectFailure("SHA-512", "checksum mismatch") {
            var wrong = try release(good); wrong = SparkleRelease(version: wrong.version, downloadURL: wrong.downloadURL, releaseNotesURL: nil, sha512: Data(repeating: 1, count: 64).base64EncodedString())
            _ = try await SparkleBackend.installPayload(good, fileExtension: "dmg", release: wrong, target: target, options: options())
        }
        try expect(version(target) == "1.0" && leftovers(beside: target).isEmpty, "Failed checks leave the app unchanged")
        try assertDetached("failures")

        // 6. License agreement: refused until accepted, then installed.
        let resources = try DiskImage.resources(of: licensed)
        try expect(resources.hasLicense && resources.licenseText?.contains("FIXTURE LICENSE") == true, "License text is read from the DMG without mounting")
        try expect(try DiskImage.resources(of: good).hasLicense == false, "Plain DMGs have no license")
        do { _ = try await install(licensed, into: target); throw Failure(description: "A license must be accepted first") }
        catch let prompt as LicenseAgreementRequired {
            try expect(prompt.text.contains("You agree to test things") && prompt.appName == "Fixture" && prompt.version == "2.0", "License prompt carries the text")
        }
        try assertDetached("license declined")
        _ = try await install(licensed, into: target, accept: true)
        try expect(version(target) == "2.0", "Accepted license installs")

        // 6b. A failure after the swap rolls back to the previous version and leaves nothing behind.
        let rollbackTarget = try installed(in: work, "t-rollback")
        let failing = InstallOptions(trustedSigners: store, acceptLicense: false, verifier: PostSwapFailingVerifier(target: rollbackTarget.path), appName: "Fixture")
        do {
            _ = try await SparkleBackend.installPayload(good, fileExtension: "dmg", release: try release(good), target: rollbackTarget, options: failing)
            throw Failure(description: "A failed post-install check must not succeed")
        } catch let error as SparkleBackend.Failure {
            try expect(error.message.contains("rolled back"), "Rollback is reported: \(error.message)")
        }
        try expect(version(rollbackTarget) == "1.0" && leftovers(beside: rollbackTarget).isEmpty, "The previous version is back and nothing is left beside it")
        try assertDetached("rollback")
        try assertDetached("license accepted")

        // 7. The ZIP path shares the signer check.
        let zipSource = work.appendingPathComponent("src-zip")
        _ = try app(in: zipSource, version: "2.0", team: "TEAMB22222")
        let zip = work.appendingPathComponent("wrong-team.zip")
        try SyncCommand.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", zipSource.appendingPathComponent("Fixture.app").path, zip.path])
        let zipTarget = try installed(in: work, "t-zip")
        do { _ = try await install(zip, into: zipTarget, kind: "zip"); throw Failure(description: "ZIPs from another team need approval too") }
        catch is SignerChange { try expect(version(zipTarget) == "1.0", "ZIP signer change leaves the app unchanged") }

        // 8. Not a disk image.
        let junk = work.appendingPathComponent("junk.dmg")
        try Data(repeating: 0, count: 2048).write(to: junk)
        try await expectFailure("disk image", "junk DMG") { _ = try await install(junk, into: zipTarget, checksumless: true) }
        try assertDetached("junk")

        // 9. The real codesign verifier refuses ad-hoc signatures.
        let adhoc = try app(in: work.appendingPathComponent("src-adhoc"), version: "1.0", team: "TEAMA11111")
        try SyncCommand.run("/usr/bin/codesign", ["--force", "-s", "-", adhoc.path])
        try await expectFailure("Ad-hoc", "ad-hoc identity") { _ = try CodesignVerifier().identity(adhoc) }

        print("PASS: DMG install path (read-only mount, one matching app, team/approved team, codesign, Gatekeeper, version, checksum, license agreement, always detached, no copies left beside the app, rollback)")

        func install(_ payload: URL, into target: URL, checksumless: Bool) async throws -> InstallOutcome {
            try await SparkleBackend.installPayload(payload, fileExtension: "dmg", release: try release(payload, checksum: !checksumless), target: target, options: options())
        }
    }

    static func expectFailure(_ fragment: String, _ label: String, _ body: () async throws -> Void) async throws {
        do { try await body() } catch {
            try expect(error.localizedDescription.contains(fragment), "\(label): unexpected error \(error.localizedDescription)")
            return
        }
        throw Failure(description: "\(label): expected a failure")
    }

    static func app(in folder: URL, name: String = "Fixture", bundleID: String = DiskImageTests.bundleID, version: String, team: String,
                    signer: String = "Fixture Corp", extra: [String: Any] = [:]) throws -> URL {
        let fm = FileManager.default
        let app = folder.appendingPathComponent("\(name).app")
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version, "CFBundleVersion": version,
                                   "CFBundleExecutable": name, "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "14.0",
                                   "UWFixtureTeam": team, "UWFixtureSigner": signer]
        info.merge(extra) { _, new in new }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        // A real native executable so the lipo architecture check runs: this test binary.
        try fm.copyItem(atPath: Bundle.main.executablePath!, toPath: app.appendingPathComponent("Contents/MacOS/\(name)").path)
        return app
    }

    static func installed(in work: URL, _ name: String) throws -> URL {
        let folder = work.appendingPathComponent(name).appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try app(in: folder, version: "1.0", team: "TEAMA11111")
    }

    /// Everything in the app's folder except the app itself (hidden copies included).
    static func leftovers(beside app: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: app.deletingLastPathComponent().path)) ?? []).filter { $0 != app.lastPathComponent }
    }

    /// hdiutil-built UDZO image with the apps and an /Applications link; optionally a license agreement (udifrez).
    static func dmg(_ name: String, in work: URL, apps: [URL], license: Bool = false) throws -> URL {
        let fm = FileManager.default
        let stage = work.appendingPathComponent("stage-\(name)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        for app in Set(apps.map { $0.deletingLastPathComponent() }) {
            for item in try fm.contentsOfDirectory(atPath: app.path) where item.hasSuffix(".app") {
                try fm.copyItem(at: app.appendingPathComponent(item), to: stage.appendingPathComponent(item))
            }
        }
        try fm.createSymbolicLink(atPath: stage.appendingPathComponent("Applications").path, withDestinationPath: "/Applications")
        let output = work.appendingPathComponent("\(name).dmg")
        // hdiutil create occasionally fails transiently (busy device); retry before failing the suite.
        for attempt in 1...3 {
            do {
                try? FileManager.default.removeItem(at: output)
                try SyncCommand.run("/usr/bin/hdiutil", ["create", "-quiet", "-fs", "HFS+", "-volname", "Fixture \(name)", "-srcfolder", stage.path, "-format", "UDZO", output.path])
                break
            } catch where attempt < 3 { Thread.sleep(forTimeInterval: 1) }
        }
        if license {
            func pascal(_ text: String) -> Data { Data([UInt8(text.utf8.count)] + Array(text.utf8)) }
            var strings = Data([0, 6])
            for text in ["English", "Agree", "Disagree", "Print", "Save...", "If you agree, click Agree."] { strings.append(pascal(text)) }
            func item(_ data: Data, _ name: String) -> [String: Any] { ["Attributes": "0x0000", "Data": data, "ID": "5000", "Name": name] }
            let resources: [String: Any] = [
                "LPic": [item(Data([0, 0, 0, 1, 0, 0, 0, 0, 0, 0]), "")],
                "STR#": [item(strings, "English")],
                "TEXT": [item(Data("FIXTURE LICENSE\rYou agree to test things.\r".utf8), "English SLA")],
            ]
            let plist = work.appendingPathComponent("\(name)-sla.plist")
            try PropertyListSerialization.data(fromPropertyList: resources, format: .xml, options: 0).write(to: plist)
            try SyncCommand.run("/usr/bin/hdiutil", ["udifrez", "-xml", plist.path, "", "-quiet", output.path])
        }
        return output
    }
}

/// Passes every check except verifying the target path once the new version is in place.
struct PostSwapFailingVerifier: SignatureVerifier {
    let target: String
    func verify(_ app: URL) throws {
        if app.path == target, AppBundleInfo.read(app)["CFBundleShortVersionString"] as? String == "2.0" {
            throw SparkleBackend.Failure(message: "codesign failed after the swap")
        }
        try FixtureVerifier().verify(app)
    }
    func assess(_ app: URL) throws -> String { try FixtureVerifier().assess(app) }
    func identity(_ app: URL) throws -> SignerIdentity { try FixtureVerifier().identity(app) }
}
