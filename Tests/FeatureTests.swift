import CFNetwork
import CryptoKit
import Foundation
import Security

/// Offline fixtures for Electron feeds, discovery, cask matching, management flows, permissions,
/// notifications, proxy/Keychain and self-update. No network, brew, or real app changes.
enum FeatureTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if !(try condition()) { throw Failure(description: message) }
    }
    static func rejects(_ body: () throws -> Void) -> Bool {
        do { try body(); return false } catch { return true }
    }

    static func run() async throws {
        try testElectronConfig()
        try testElectronMetadata()
        try testSHA512()
        try testRepositoryDiscovery()
        try testCaskMatching()
        try testVendorUpdaters()
        try testHomebrewActions()
        try testAppRemoval()
        try testPermissions()
        try testNotifications()
        try testSelfUpdateFeed()
        try testProxy()
        try testKeychain()
        print("PASS: Electron feeds, SHA-512, GitHub discovery, cask matching, vendor updaters, Homebrew actions, Trash removal, permissions, notifications, self-update feed, proxy, Keychain")
    }

    static func testElectronConfig() throws {
        let github = ElectronBackend.parseUpdateConfig("owner: Fchat-Horizon\nrepo: Horizon\nprovider: github\nupdaterCacheDirName: horizon-electron-updater\n")
        try expect(github?.provider == .github && github?.repository == "Fchat-Horizon/Horizon", "GitHub provider must parse owner/repo")
        try expect(github?.metadataFileName == "latest-mac.yml", "Default channel uses latest-mac.yml")
        let generic = ElectronBackend.parseUpdateConfig("provider: generic\nurl: 'https://downloads.example.com/app/'\nchannel: beta\n")
        try expect(generic?.url?.absoluteString == "https://downloads.example.com/app/" && generic?.channel == "beta", "Generic provider must parse URL and channel")
        try expect(ElectronBackend.metadataURL(for: generic!)?.absoluteString == "https://downloads.example.com/app/beta-mac.yml", "Generic metadata URL")
        let s3 = ElectronBackend.parseUpdateConfig("provider: s3\nbucket: my-bucket\npath: /releases/mac\n")
        try expect(ElectronBackend.metadataURL(for: s3!)?.absoluteString == "https://my-bucket.s3.amazonaws.com/releases/mac/latest-mac.yml", "S3 virtual-host URL")
        let dotted = ElectronBackend.parseUpdateConfig("provider: s3\nbucket: my.bucket\nregion: eu-west-1\n")
        try expect(ElectronBackend.metadataURL(for: dotted!)?.absoluteString == "https://s3-eu-west-1.amazonaws.com/my.bucket/latest-mac.yml", "S3 dotted-bucket path-style URL")
        for unsupported in ["provider: github\nowner: o\nrepo: r\nprivate: true", "provider: github\nowner: o\nrepo: r\ntoken: abc",
                            "provider: generic\nurl: http://insecure.example/", "provider: generic\nurl: https://user:pw@example.com/",
                            "provider: keygen\naccount: x", "provider: github\nowner: ../x\nrepo: r", "provider: github\nowner: o\nrepo: r\nhost: ghe.corp.example",
                            "provider: generic\nurl: https://example.com/\nchannel: ../../x", "no provider here"] {
            try expect(ElectronBackend.parseUpdateConfig(unsupported) == nil, "Unsupported Electron config must be ignored: \(unsupported)")
        }
        let decoded = try JSONDecoder().decode(UpdateItem.self, from: JSONEncoder().encode(UpdateItem(id: "e", name: "E", installedVersion: "1", provider: .electron, electronUpdate: github)))
        try expect(decoded.electronUpdate == github && decoded.provider == .electron, "Electron fields must survive JSON roundtrip")
    }

    static func testElectronMetadata() throws {
        let yaml = """
        version: 2.4.0
        files:
          - url: Horizon-2.4.0-arm64-mac.zip
            sha512: \(String(repeating: "A", count: 86))==
            size: 1000
          - url: Horizon-2.4.0-arm64.dmg
            sha512: \(String(repeating: "B", count: 86))==
            size: 1200
          - url: Horizon-2.4.0-mac.zip
            sha512: \(String(repeating: "C", count: 86))==
            size: 1100
        path: Horizon-2.4.0-arm64-mac.zip
        sha512: \(String(repeating: "A", count: 86))==
        releaseDate: '2026-10-01T00:00:00.000Z'
        """
        let metadata = try ElectronBackend.parseMetadata(yaml)
        try expect(metadata.version == "2.4.0" && metadata.files.count == 3 && metadata.files[0].size == 1000, "latest-mac.yml must parse files")
        let base = URL(string: "https://github.com/o/r/releases/download/v2.4.0/")!
        let github: (URL) -> Bool = { GitHubBackend.validGitHubURL($0, repository: "o/r", pathPrefix: "releases/download/") }
        let arm = ElectronBackend.select(metadata, baseURL: base, installedVersion: "2.3.9", architecture: "arm64", allowURL: github)
        try expect(arm?.release?.downloadURL.lastPathComponent == "Horizon-2.4.0-arm64-mac.zip", "arm64 must prefer the native ZIP")
        try expect(arm?.release?.sha512?.hasPrefix("AAAA") == true, "Selected payload keeps its checksum")
        let intel = ElectronBackend.select(metadata, baseURL: base, installedVersion: "2.3.9", architecture: "x86_64", allowURL: github)
        try expect(intel?.release?.downloadURL.lastPathComponent == "Horizon-2.4.0-mac.zip", "Intel must select the unmarked x64 ZIP")
        try expect(ElectronBackend.select(metadata, baseURL: base, installedVersion: "2.4.0", architecture: "arm64") == nil, "Installed latest must not be offered")
        try expect(ElectronBackend.select(metadata, baseURL: base, installedVersion: "v2.3", architecture: "arm64")?.version == "2.4.0", "Leading v must be normalized")
        let foreign = ElectronBackend.select(metadata, baseURL: URL(string: "https://evil.example/")!, installedVersion: "1", architecture: "arm64", allowURL: github)
        try expect(foreign != nil && foreign?.release == nil, "Payloads outside the declared repository must not become direct downloads")
        var ambiguous = metadata; ambiguous.files.append(.init(url: "Horizon-2.4.0-universal-mac.zip", sha512: String(repeating: "D", count: 88), size: 1))
        try expect(ElectronBackend.select(ambiguous, baseURL: base, installedVersion: "1", architecture: "arm64")?.release == nil, "Multiple native ZIPs must stay a manual choice")
        var unsummed = metadata; unsummed.files = [.init(url: "App-arm64-mac.zip", sha512: nil, size: 1)]
        let noSum = ElectronBackend.select(unsummed, baseURL: base, installedVersion: "1", architecture: "arm64")
        try expect(noSum?.version == "2.4.0" && noSum?.release == nil, "A missing SHA-512 must disable direct installation")
        var pre = metadata; pre.version = "3.0.0-beta.1"
        try expect(ElectronBackend.select(pre, baseURL: base, installedVersion: "2.0.0", architecture: "arm64") == nil, "Prereleases are not offered to stable installs")
        try expect(rejects { _ = try ElectronBackend.parseMetadata("files:\n  - url: a.zip") }, "Metadata without version must fail")
        let legacy = try ElectronBackend.parseMetadata("version: 1.1.0\npath: Legacy-1.1.0-mac.zip\nsha512: \(String(repeating: "E", count: 86))==\n")
        try expect(legacy.files.first?.url == "Legacy-1.1.0-mac.zip", "Legacy path/sha512 metadata must be supported")
        let release = SparkleRelease(version: "2", downloadURL: URL(string: "https://example.com/a.zip")!, releaseNotesURL: nil)
        var item = UpdateItem(id: "x", name: "X", path: "/tmp/X.app", installedVersion: "1", latestVersion: "2", provider: .electron, isOutdated: true, sparkleRelease: release)
        try expect(!item.canUpdateDirectly, "Electron direct updates require a checksum")
        item.sparkleRelease = SparkleRelease(version: "2", downloadURL: release.downloadURL, releaseNotesURL: nil, sha512: "abc")
        try expect(item.canUpdateDirectly, "Checksummed Electron payloads use the verified direct pipeline")
        item.provider = .vendor
        try expect(!item.canUpdateDirectly, "Vendor-managed apps never update directly")
    }

    static func testSHA512() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UWSHA-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("payload.zip")
        let bytes = Data((0..<300_000).map { UInt8($0 % 251) })
        try bytes.write(to: file)
        let digest = Data(SHA512.hash(data: bytes))
        try SparkleBackend.verifySHA512(file, expected: digest.base64EncodedString())
        try SparkleBackend.verifySHA512(file, expected: digest.map { String(format: "%02X", $0) }.joined())
        try expect(rejects { try SparkleBackend.verifySHA512(file, expected: Data(SHA512.hash(data: Data("other".utf8))).base64EncodedString()) }, "Wrong checksum must fail")
        try expect(rejects { try SparkleBackend.verifySHA512(file, expected: "not-a-digest") }, "Malformed checksum must fail")
    }

    static func testRepositoryDiscovery() throws {
        let cases: [(String, String?)] = [
            ("https://github.com/owner/app/releases/latest", "owner/app"), ("https://github.com/owner/app.git", "owner/app"),
            ("https://raw.githubusercontent.com/owner/app/main/appcast.xml", "owner/app"), ("https://owner.github.io/app/appcast.xml", "owner/app"),
            ("https://api.github.com/repos/owner/app/releases", "owner/app"), ("https://github.com/sponsors/someone", nil),
            ("https://github.com/owner", nil), ("https://example.com/owner/app", nil), ("ftp://github.com/owner/app", nil),
            ("https://objects.githubusercontent.com/github-production-release-asset/1", nil)]
        for (url, expected) in cases { try expect(RepositoryDiscovery.repository(fromURL: url) == expected, "Repository extraction for \(url)") }
        let electron = ElectronUpdateConfig(provider: .github, owner: "Org", repo: "Tool")
        let info: [String: Any] = ["NSHumanReadableCopyright": "See https://github.com/org/tool for source", "SUFeedURL": "https://org.github.io/tool/appcast.xml",
                                   "Nested": ["Links": ["https://github.com/other/project/issues"]]]
        let found = RepositoryDiscovery.suggestions(info: info, sparkleFeed: URL(string: "https://org.github.io/tool/appcast.xml"), electron: electron)
        try expect(found.first?.repository == "Org/Tool" && found.first?.evidence.contains("Electron") == true, "Electron config is the strongest evidence")
        try expect(found.filter { $0.repository.lowercased() == "org/tool" }.count == 1, "Suggestions must be deduplicated case-insensitively")
        try expect(found.contains { $0.repository == "other/project" }, "Nested Info.plist URLs must be found")
        let cask = RepositoryDiscovery.suggestions(info: [:], sparkleFeed: nil, electron: nil, extra: [("https://github.com/maker/app", "Homebrew cask homepage")])
        try expect(cask == [RepositorySuggestion(repository: "maker/app", evidence: "Homebrew cask homepage")], "Cask homepage must produce a suggestion")
        try expect(RepositoryDiscovery.suggestions(info: ["CFBundleName": "Plain"], sparkleFeed: nil, electron: nil).isEmpty, "No GitHub evidence means no suggestion")
    }

    static func testCaskMatching() throws {
        try expect(CaskMatching.slug("Visual Studio Code") == "visual-studio-code" && CaskMatching.slug("  Foo++ App ") == "foo++-app", "Slugs follow cask token style")
        let known: Set<String> = ["firefox", "visual-studio-code", "visualstudiocode", "proton-mail", "discord", "notes"]
        try expect(CaskMatching.candidateTokens(appFileName: "Firefox.app", displayName: "Firefox", known: known) == ["firefox"], "Simple token")
        try expect(CaskMatching.candidateTokens(appFileName: "Visual Studio Code.app", displayName: "Code", known: known) == ["visual-studio-code", "visualstudiocode"], "Spaced names and collapsed forms")
        try expect(CaskMatching.candidateTokens(appFileName: "Unknown Thing.app", displayName: "Unknown", known: known).isEmpty, "Unknown tokens are never queried")
        let json = """
        {"formulae":[],"casks":[
          {"token":"firefox","name":["Mozilla Firefox"],"homepage":"https://www.mozilla.org/firefox/","url":"https://download.example/Firefox.dmg","version":"160.0","deprecated":false,"disabled":false,
           "artifacts":[{"uninstall":[{"quit":"org.mozilla.firefox"}]},{"app":["Firefox.app"],"target":"/Applications/Firefox.app"},{"zap":[{"trash":["~/Library/Caches/Firefox"]}]}]},
          {"token":"discord","name":["Discord"],"homepage":"https://discord.com/","version":"0.0.422,abc","deprecated":true,"disabled":false,
           "artifacts":[{"uninstall":[{"quit":["com.hnc.Discord","com.hnc.Discord.helper"]}]},{"app":["Discord.app"]}]},
          {"token":"oldtool","name":["Old Tool"],"version":"1","deprecated":false,"disabled":true,"artifacts":[{"app":["Firefox.app"]}]},
          {"token":"renamed","name":["Renamed"],"version":"1","artifacts":[{"app":["Source.app",{"target":"Proton Mail.app"}]}]}
        ]}
        """
        let casks = try CaskMatching.parseCasks(Data(json.utf8))
        try expect(casks.count == 4 && casks[0].bundleIDs == ["org.mozilla.firefox"] && casks[1].bundleIDs.count == 2, "Cask JSON must parse artifacts and quit IDs")
        try expect(casks[3].appNames.contains("Proton Mail.app"), "App artifact target overrides must be recognized")
        let firefox = CaskMatching.match(appFileName: "Firefox.app", bundleID: "org.mozilla.firefox", casks: casks)
        try expect(firefox.count == 1 && firefox[0].token == "firefox" && firefox[0].confidence == .high && firefox[0].version == "160.0", "Name + bundle ID is high confidence; disabled casks excluded")
        let medium = CaskMatching.match(appFileName: "firefox.app", bundleID: "org.example.fork", casks: casks)
        try expect(medium.first?.confidence == .medium, "Name-only matches are medium confidence")
        let discord = CaskMatching.match(appFileName: "Discord.app", bundleID: "com.hnc.Discord", casks: casks)
        try expect(discord.first?.evidence.contains("deprecated") == true && discord.first?.version == "0.0.422", "Deprecated casks are flagged; version strips build suffix")
        try expect(CaskMatching.match(appFileName: "Nothing.app", bundleID: nil, casks: casks).isEmpty, "No artifact match means no suggestion")
    }

    static func testVendorUpdaters() throws {
        let app = URL(fileURLWithPath: "/Applications/Fixture.app")
        let microsoft = VendorUpdaters.detect(bundleID: "com.microsoft.Word", info: [:], appURL: app) { $0 == VendorUpdaters.microsoftAutoUpdate }
        try expect(microsoft?.launchPath == VendorUpdaters.microsoftAutoUpdate, "Office apps open Microsoft AutoUpdate")
        try expect(VendorUpdaters.detect(bundleID: "com.microsoft.Word", info: [:], appURL: app) { _ in false } == nil, "Without MAU no Microsoft updater is claimed")
        try expect(VendorUpdaters.detect(bundleID: "com.microsoft.VSCode", info: [:], appURL: app) { _ in true }?.name != "Microsoft AutoUpdate", "VS Code is not a MAU app")
        let adobe = VendorUpdaters.detect(bundleID: "com.adobe.Photoshop", info: [:], appURL: app) { $0 == VendorUpdaters.adobeCreativeCloud[0] }
        try expect(adobe?.name == "Adobe Creative Cloud" && adobe?.launchPath == VendorUpdaters.adobeCreativeCloud[0], "Adobe apps open Creative Cloud")
        try expect(VendorUpdaters.detect(bundleID: "com.adobe.Reader", info: [:], appURL: app) { _ in false }?.launchPath == nil, "Acrobat uses its own Help menu")
        try expect(VendorUpdaters.detect(bundleID: "com.google.Chrome", info: ["KSProductID": "com.google.Chrome"], appURL: app) { _ in false }?.name == "Google Software Update", "Keystone apps are recognized")
        try expect(VendorUpdaters.detect(bundleID: "com.example.chat", info: [:], appURL: app) { $0.hasSuffix("Squirrel.framework") }?.name.contains("Squirrel") == true, "Squirrel.Mac apps are recognized")
        try expect(VendorUpdaters.detect(bundleID: "com.example.plain", info: [:], appURL: app) { _ in false } == nil, "Plain apps have no vendor updater")
    }

    static func testHomebrewActions() throws {
        let cask = UpdateItem(id: "c", name: "Cask", path: "/Applications/Cask.app", installedVersion: "1", provider: .homebrewCask, token: "cask-app")
        var formula = UpdateItem(id: "f", name: "tool", installedVersion: "1", provider: .homebrewFormula, token: "tool", isPinned: true)
        try expect(try HomebrewAction.arguments(.reinstall, for: cask) == ["reinstall", "--cask", "cask-app"], "Cask reinstall")
        try expect(try HomebrewAction.arguments(.uninstall, for: cask) == ["uninstall", "--cask", "cask-app"], "Cask uninstall keeps data (no --zap)")
        try expect(try HomebrewAction.arguments(.reinstall, for: formula) == ["reinstall", "--formula", "tool"], "Formula reinstall")
        try expect(try HomebrewAction.arguments(.uninstall, for: formula) == ["uninstall", "--formula", "tool"], "Formula uninstall")
        try expect(try HomebrewAction.arguments(.unpin, for: formula) == ["unpin", "tool"], "Pinned formula unpin")
        formula.isPinned = false
        try expect(rejects { _ = try HomebrewAction.arguments(.unpin, for: formula) }, "Unpinned formula cannot be unpinned")
        try expect(rejects { _ = try HomebrewAction.arguments(.unpin, for: cask) }, "Casks cannot be pinned")
        for token in ["--force", "x; rm -rf ~", "../evil.rb", ""] {
            var bad = cask; bad.token = token
            try expect(rejects { _ = try HomebrewAction.arguments(.uninstall, for: bad) }, "Unsafe token rejected: \(token)")
        }
        let manual = UpdateItem(id: "m", name: "M", installedVersion: "1", provider: .manual, token: "m")
        try expect(rejects { _ = try HomebrewAction.arguments(.reinstall, for: manual) }, "Non-Homebrew items are rejected")
    }

    static func testAppRemoval() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("UWTrash-\(UUID().uuidString)")
        let apps = root.appendingPathComponent("Apps"), trash = root.appendingPathComponent("FakeTrash")
        try fm.createDirectory(at: apps.appendingPathComponent("Fixture.app/Contents"), withIntermediateDirectories: true)
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let app = apps.appendingPathComponent("Fixture.app")
        let link = apps.appendingPathComponent("Link.app")
        try fm.createSymbolicLink(at: link, withDestinationURL: app)
        let valid = try AppRemoval.validate(path: app.path, runningBundlePaths: [], selfPath: "/Applications/UpdateWorkbench.app")
        try expect(valid.lastPathComponent == "Fixture.app", "A normal app validates")
        try expect(rejects { _ = try AppRemoval.validate(path: "Fixture.app", runningBundlePaths: [], selfPath: "/x.app") }, "Relative paths rejected")
        try expect(rejects { _ = try AppRemoval.validate(path: root.path, runningBundlePaths: [], selfPath: "/x.app") }, "Non-app folders rejected")
        try expect(rejects { _ = try AppRemoval.validate(path: app.path, runningBundlePaths: [app.path], selfPath: "/x.app") }, "Running apps rejected")
        try expect(rejects { _ = try AppRemoval.validate(path: app.path, runningBundlePaths: [], selfPath: app.path) }, "Self removal rejected")
        try expect(rejects { _ = try AppRemoval.validate(path: link.path, runningBundlePaths: [], selfPath: "/x.app") }, "Symlinked bundles rejected")
        if fm.fileExists(atPath: "/System/Applications/Calculator.app") {
            try expect(rejects { _ = try AppRemoval.validate(path: "/System/Applications/Calculator.app", runningBundlePaths: [], selfPath: "/x.app") }, "System apps rejected")
        }
        let message = try AppRemoval.moveToTrash(valid) { url in
            let destination = trash.appendingPathComponent(url.lastPathComponent)
            try fm.moveItem(at: url, to: destination)
            return destination
        }
        try expect(!fm.fileExists(atPath: app.path) && fm.fileExists(atPath: trash.appendingPathComponent("Fixture.app/Contents").path), "Trash moves, never deletes")
        try expect(message.contains("Trash"), "Result explains where the app went")
    }

    static func testPermissions() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("UWHome-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let candidates = [home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path, home.appendingPathComponent("Library/Safari").path]
        try expect(PermissionsBackend.probeFullDiskAccess(candidates: candidates) == nil, "Missing probe locations are unknown, not denied")
        let tcc = home.appendingPathComponent("Library/Application Support/com.apple.TCC")
        try FileManager.default.createDirectory(at: tcc, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: tcc.appendingPathComponent("TCC.db"))
        try expect(PermissionsBackend.probeFullDiskAccess(candidates: candidates) == true, "Readable probe file reports access")
        try FileManager.default.removeItem(at: tcc.appendingPathComponent("TCC.db"))
        try FileManager.default.createDirectory(atPath: candidates[1], withIntermediateDirectories: true)
        try expect(PermissionsBackend.probeFullDiskAccess(candidates: candidates) == true, "Readable probe folder reports access")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: candidates[1])
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: candidates[1]) }
        try expect(PermissionsBackend.probeFullDiskAccess(candidates: candidates) == false, "A blocked protected location reports no access")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: candidates[1])
        let probes = PermissionsBackend.Probes(fullDiskAccess: false, notifications: nil, isAdmin: false,
                                               destinations: [("/Applications", true), ("/Volumes/Apps", false)], launchAtLogin: "Not registered", proxyPasswordStored: false)
        let checks = PermissionsBackend.checks(probes)
        func state(_ title: String) -> PermissionState? { checks.first { $0.title == title }?.state }
        try expect(state("Full Disk Access") == .denied && state("App Management") == .unknown && state("Automation (Apple Events)") == .notNeeded, "Privacy states")
        try expect(state("Notifications") == .unknown && state("Administrator account") == .denied, "Notification and admin states")
        try expect(state("Write access: /Applications") == .granted && state("Write access: /Volumes/Apps") == .denied, "Destination write states")
        try expect(checks.first { $0.title == "Full Disk Access" }?.settingsURL?.absoluteString.contains("Privacy_AllFiles") == true, "Settings deep links")
        try expect(PermissionsBackend.writable([NSTemporaryDirectory()]).first?.writable == true, "Temporary directory is writable")
    }

    static func testNotifications() throws {
        typealias C = UpdateNotificationPolicy.Candidate
        let a = C(id: "a", name: "Alpha", version: "2"), b = C(id: "b", name: "Beta", version: "5")
        try expect(UpdateNotificationPolicy.newlyAvailable([a, b], alreadyNotified: ["a": "2"]) == [b], "Already announced versions are skipped")
        try expect(UpdateNotificationPolicy.newlyAvailable([a], alreadyNotified: ["a": "1"]) == [a], "A newer version is announced again")
        let recorded = UpdateNotificationPolicy.record([b], current: [a, b], into: ["a": "2", "gone": "1"])
        try expect(recorded == ["a": "2", "b": "5"], "Records prune items that are no longer outdated")
        try expect(UpdateNotificationPolicy.availableMessage([]) == nil, "No updates, no notification")
        try expect(UpdateNotificationPolicy.availableMessage([a])?.body == "Alpha 2 is available.", "Single update text")
        let many = (1...5).map { C(id: "\($0)", name: "App\($0)", version: "1") }
        try expect(UpdateNotificationPolicy.availableMessage(many)?.title == "5 updates available" && UpdateNotificationPolicy.availableMessage(many)!.body.contains("and 2 more"), "Summary text")
        try expect(UpdateNotificationPolicy.resultMessage(succeeded: [], failed: []) == nil, "No result, no notification")
        try expect(UpdateNotificationPolicy.resultMessage(succeeded: ["A"], failed: [])?.title == "Updates complete", "Success text")
        try expect(UpdateNotificationPolicy.resultMessage(succeeded: [], failed: ["B"])?.title == "Update failed", "Failure text")
        try expect(UpdateNotificationPolicy.resultMessage(succeeded: ["A"], failed: ["B"])?.title == "Updates finished with errors", "Mixed text")
    }

    static func testSelfUpdateFeed() throws {
        try expect(try SelfUpdateFeed.parse("  ") == .disabled, "Empty feed disables self-update")
        try expect(try SelfUpdateFeed.parse("github:kasakir-ai/update-workbench") == .github("kasakir-ai/update-workbench"), "github: shorthand")
        try expect(try SelfUpdateFeed.parse("https://github.com/owner/repo") == .github("owner/repo"), "Repository URL")
        try expect(try SelfUpdateFeed.parse("https://updates.example.com/appcast.xml") == .appcast(URL(string: "https://updates.example.com/appcast.xml")!), "Appcast URL")
        for bad in ["http://updates.example.com/appcast.xml", "github:bad", "https://user:pw@example.com/a.xml", "https://github.com/owner/repo/releases", "nonsense"] {
            try expect(rejects { _ = try SelfUpdateFeed.parse(bad) }, "Invalid self-update feed rejected: \(bad)")
        }
    }

    final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    static func testProxy() throws {
        var settings = ProxySettings()
        try expect(settings.connectionProxyDictionary() == nil && settings.commandEnvironment().isEmpty, "System mode leaves configuration untouched")
        settings.mode = .none
        try expect(settings.connectionProxyDictionary()?.isEmpty == true, "No-proxy mode disables proxies")
        settings.mode = .manual
        try expect(settings.validationError() != nil, "Manual mode needs a host")
        for host in ["http://proxy", "user@proxy", "proxy/path", "pro xy"] {
            settings.host = host
            try expect(settings.validationError() != nil, "Invalid proxy host rejected: \(host)")
        }
        settings.host = "proxy.corp.example"; settings.port = 0
        try expect(settings.validationError() != nil, "Port must be valid")
        settings.port = 3128; settings.authenticated = true; settings.username = ""
        try expect(settings.validationError() != nil, "Authentication needs a user")
        settings.username = "builder"
        try expect(settings.validationError() == nil, "Valid manual proxy")
        let http = settings.connectionProxyDictionary(password: "secret")!
        try expect(http[kCFNetworkProxiesHTTPSProxy as String] as? String == "proxy.corp.example" && http[kCFNetworkProxiesHTTPSPort as String] as? Int == 3128
                   && http[kCFNetworkProxiesHTTPEnable as String] as? Int == 1, "HTTP proxy dictionary covers HTTP and HTTPS")
        try expect(!http.values.contains { ($0 as? String) == "secret" }, "HTTP proxy passwords are answered by challenge, not placed in the dictionary")
        let environment = settings.commandEnvironment()
        try expect(environment["https_proxy"] == "http://proxy.corp.example:3128" && !environment.values.contains { $0.contains("builder") || $0.contains("secret") }, "Subprocess environment never contains credentials")
        settings.kind = .socks
        let socks = settings.connectionProxyDictionary(password: "secret")!
        try expect(socks[kCFNetworkProxiesSOCKSProxy as String] as? String == "proxy.corp.example" && socks[kCFStreamPropertySOCKSUser as String] as? String == "builder", "SOCKS dictionary")
        try expect(settings.commandEnvironment()["all_proxy"] == "socks5://proxy.corp.example:3128", "SOCKS environment")
        let suite = "local.updateworkbench.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try settings.save(defaults)
        try expect(ProxySettings.load(defaults) == settings, "Proxy settings persist without the password")
        try expect(!(String(data: defaults.data(forKey: ProxySettings.defaultsKey) ?? Data(), encoding: .utf8) ?? "").contains("secret"), "Password never stored in defaults")
        settings.kind = .http
        let space = URLProtectionSpace(proxyHost: "proxy.corp.example", port: 3128, type: NSURLProtectionSpaceHTTPSProxy, realm: nil, authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let sender = ChallengeSender()
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0, failureResponse: nil, error: nil, sender: sender)
        let answer = ProxySettings.respond(to: challenge, settings: settings) { _ in "secret" }
        try expect(answer.0 == .useCredential && answer.1?.user == "builder" && answer.1?.password == "secret", "Proxy challenges receive Keychain credentials")
        let retry = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 1, failureResponse: nil, error: nil, sender: sender)
        try expect(ProxySettings.respond(to: retry, settings: settings) { _ in "secret" }.0 == .performDefaultHandling, "Rejected credentials are not retried in a loop")
        let server = URLAuthenticationChallenge(protectionSpace: URLProtectionSpace(host: "example.com", port: 443, protocol: "https", realm: nil, authenticationMethod: NSURLAuthenticationMethodHTTPBasic),
                                                proposedCredential: nil, previousFailureCount: 0, failureResponse: nil, error: nil, sender: sender)
        try expect(ProxySettings.respond(to: server, settings: settings) { _ in "secret" }.0 == .performDefaultHandling, "Server challenges never receive proxy credentials")
    }

    static func testKeychain() throws {
        let store = KeychainStore(service: "local.updateworkbench.tests.\(UUID().uuidString)")
        do {
            try expect(try store.read(account: "fixture") == nil, "Missing item reads as nil")
            try store.save("first", account: "fixture")
            defer { try? store.delete(account: "fixture") }
            try expect(try store.read(account: "fixture") == "first", "Saved secret reads back")
            try store.save("second", account: "fixture")
            try expect(try store.read(account: "fixture") == "second", "Saving again updates in place")
            try store.delete(account: "fixture")
            try expect(try store.read(account: "fixture") == nil, "Deleted secret is gone")
            try store.delete(account: "fixture")
            print("PASS: Keychain round trip (test-only service, item removed)")
        } catch let error as KeychainError where [errSecInteractionNotAllowed, errSecNotAvailable, errSecNoSuchKeychain, errSecAuthFailed].contains(error.status) {
            print("SKIP: Keychain unavailable in this session (\(error.localizedDescription))")
        }
    }
}
