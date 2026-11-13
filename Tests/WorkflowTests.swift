import Combine
import Foundation
@testable import UpdateWorkbench

/// Folder for fixture apps and disk images, always a `.noindex` folder so Spotlight and Launch Services
/// never list test apps. test.sh sets UW_TEST_TMP; a plain `swift test` uses one under the temporary directory.
enum TestTemp {
    static let root: URL = {
        if let path = ProcessInfo.processInfo.environment["UW_TEST_TMP"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateWorkbenchTests.noindex", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()
}

/// 0.4.0 logic: ignore/skip/pre-release rules, schedules, release-note sanitizing, trusted signers and history.
enum WorkflowTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if !(try condition()) { throw Failure(description: message) }
    }
    static func rejects(_ fragment: String = "", _ body: () throws -> Void) -> Bool {
        do { try body(); return false } catch { return fragment.isEmpty || error.localizedDescription.contains(fragment) }
    }

    static func run() throws {
        try testRules()
        try testSchedule()
        try testReleaseNotes()
        try testFeedNotesAndPrereleases()
        try testSigners()
        try testHistory()
        try testScanner()
        try testAppStoreCLI()
        try testWriteBackDoesNotPublish()
        print("PASS: rules (ignore, skip, pre-release hold), schedules, release notes sanitizing, feed notes, trusted signers, history log, scanner (fresh versions, no hidden or backup copies), mas parsing and errors, write-back loop guard")
    }

    /// Regression for the 0.4.0 launch hang: a control that writes its binding back with the same value
    /// (MenuBarExtra's isInserted) must not publish a change, or every scene re-renders and writes it again.
    final class WriteBackModel: ObservableObject {
        private var stored = true
        var isInserted: Bool {
            get { stored }
            set { StateWrites.assignIfChanged(&stored, newValue, willChange: { objectWillChange.send() }) }
        }
    }

    static func testWriteBackDoesNotPublish() throws {
        let model = WriteBackModel()
        var published = 0
        let subscription = model.objectWillChange.sink { published += 1 }
        // Simulate the controller writing back on each of many render passes; each write would trigger another pass.
        var passes = 0
        var pending = true
        while pending && passes < 1000 {
            passes += 1
            let before = published
            model.isInserted = model.isInserted
            pending = published != before
        }
        try expect(published == 0 && passes == 1, "Same-value write-backs publish nothing, so the render loop settles after one pass")
        model.isInserted = false
        model.isInserted = false
        try expect(published == 1 && model.isInserted == false, "A real change publishes once")
        var value = 3
        try expect(!StateWrites.assignIfChanged(&value, 3, willChange: {}) && StateWrites.assignIfChanged(&value, 4, willChange: {}) && value == 4, "assignIfChanged reports changes")
        try expect(UpdateRules.isPrerelease("2.0-beta.1") && UpdateRules.isPrerelease("3.1b2") && !UpdateRules.isPrerelease("2.4.0"), "Precompiled pre-release patterns")
        subscription.cancel()
    }

    static func temporaryFolder(_ name: String) throws -> URL {
        let url = TestTemp.root.appendingPathComponent("uw-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func testRules() throws {
        for version in ["2.0.0-beta.1", "3.1b2", "4.0rc1", "1.2-alpha", "5.0 Preview", "2026.1-nightly", "v1.0.0-rc.2", "8.0 Beta 3", "2.0a1"] {
            try expect(UpdateRules.isPrerelease(version), "\(version) must count as a pre-release")
        }
        for version in ["2.0.0", "1.8.5", "131.0.2", "2024.10", "7.1", "3.4 (1234)", "10.0.19045", "1.0.0+build.5"] {
            try expect(!UpdateRules.isPrerelease(version), "\(version) must count as stable")
        }
        var rules = UpdateRules()
        try expect(rules.holdPrereleases, "Pre-releases are held back by default")
        try expect(rules.decision(id: "a", latestVersion: "2.0", isOutdated: true) == .show, "Stable updates show")
        try expect(rules.decision(id: "a", latestVersion: "2.0-beta.1", isOutdated: true) == .heldPrerelease, "Betas are held by default")
        try expect(rules.decision(id: "a", latestVersion: "2.0-beta.1", isOutdated: false) == .show, "Up-to-date items are never held")
        rules.prereleaseRules["a"] = .allow
        try expect(rules.decision(id: "a", latestVersion: "2.0-beta.1", isOutdated: true) == .show, "A per-app allow overrides the global hold")
        try expect(rules.decision(id: "b", latestVersion: "2.0-beta.1", isOutdated: true) == .heldPrerelease, "Other apps keep the global hold")
        rules.holdPrereleases = false
        try expect(rules.allowsPrereleases(for: "b"), "Global allow applies to apps without a rule")
        rules.prereleaseRules["b"] = .hold
        try expect(!rules.allowsPrereleases(for: "b") && rules.decision(id: "b", latestVersion: "3.0rc1", isOutdated: true) == .heldPrerelease, "A per-app hold overrides global allow")
        rules.skipped["c"] = "2.0"
        try expect(rules.decision(id: "c", latestVersion: "2.0", isOutdated: true) == .skipped("2.0"), "Skipped version is hidden")
        try expect(rules.decision(id: "c", latestVersion: "2.1", isOutdated: true) == .show, "A newer version than the skipped one shows again")
        rules.ignored.insert("c")
        try expect(rules.decision(id: "c", latestVersion: "2.1", isOutdated: true) == .ignored && rules.decision(id: "c", latestVersion: nil, isOutdated: false) == .ignored, "Ignore wins over everything")
        try expect(rules.ruleIDs == ["a", "b", "c"], "Rule list contains every app with a rule")
        rules.removeRules(for: "c")
        try expect(!rules.ruleIDs.contains("c"), "Removing rules clears ignore and skip")

        let suite = "uw-rules-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try expect(UpdateRules.load(defaults) == UpdateRules(), "Empty defaults load the default rules")
        rules.ignored = ["x"]; rules.skipped = ["y": "1.2"]
        rules.save(defaults)
        try expect(UpdateRules.load(defaults) == rules, "Rules round-trip through UserDefaults")
        defaults.set(["z": "bogus"], forKey: UpdateRules.prereleaseKey)
        try expect(UpdateRules.load(defaults).prereleaseRules.isEmpty, "Unknown stored rule values are dropped")
        try expect(UpdateRules.displayName(for: "/Applications/Orbit Chat.app") == "Orbit Chat" && UpdateRules.displayName(for: "cask:firefox") == "firefox", "Rule names")

        let beta = UpdateItem(id: "a", name: "A", installedVersion: "1", latestVersion: "2-beta", provider: .sparkle, isOutdated: true)
        try expect(ItemStatus.classify(beta, ignored: false, skippedVersion: nil, snoozedUntil: nil, failure: nil, heldPrerelease: true) == .heldBack, "Held betas get their own status")
        try expect(ItemStatus.classify(beta, ignored: true, skippedVersion: nil, snoozedUntil: nil, failure: nil, heldPrerelease: true) == .ignored, "Ignore outranks the beta hold")
    }

    static func testSchedule() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        try expect(!CheckSchedule.off.isDue(lastCheck: nil, now: now), "Off never runs")
        try expect(CheckSchedule.daily.isDue(lastCheck: nil, now: now), "Never checked is due")
        try expect(!CheckSchedule.daily.isDue(lastCheck: now.addingTimeInterval(-3600), now: now), "Daily is not due after an hour")
        try expect(CheckSchedule.daily.isDue(lastCheck: now.addingTimeInterval(-86_400), now: now), "Daily is due after a day")
        try expect(!CheckSchedule.weekly.isDue(lastCheck: now.addingTimeInterval(-3 * 86_400), now: now), "Weekly is not due after three days")
        try expect(CheckSchedule.weekly.isDue(lastCheck: now.addingTimeInterval(-8 * 86_400), now: now), "Weekly is due after eight days")
        try expect(CheckSchedule.daily.isDue(lastCheck: now.addingTimeInterval(3600), now: now), "A last check in the future (clock change) is due")
        try expect(CheckSchedule.daily.nextCheck(after: now.addingTimeInterval(-3600), now: now) == now.addingTimeInterval(82_800), "Next daily check time")
        try expect(CheckSchedule.off.nextCheck(after: now, now: now) == nil, "Off has no next check")
        let suite = "uw-schedule-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try expect(CheckSchedule.stored(defaults) == .off, "Default schedule is off")
        defaults.set(14_400.0, forKey: "interval")
        try expect(CheckSchedule.stored(defaults) == .daily, "0.3 sub-daily intervals migrate to daily")
        defaults.set(604_800.0, forKey: "interval")
        try expect(CheckSchedule.stored(defaults) == .weekly, "Longer 0.3 intervals migrate to weekly")
        defaults.set("Daily", forKey: CheckSchedule.defaultsKey)
        try expect(CheckSchedule.stored(defaults) == .daily, "The new setting wins over the legacy value")
    }

    static func testReleaseNotes() throws {
        let html = """
        <html><head><title>x</title><script>alert('x')</script></head><body>
        <h2>What&rsquo;s new</h2><p>Faster <b>sync</b> &amp; fixes.<br>Second line</p>
        <ul><li onclick="steal()">Item <a href="https://example.com/a?x=1&amp;y=2">one</a></li>
        <li><a href="javascript:alert(1)">two</a></li><li><a href="http://insecure.example.com">three</a></li></ul>
        <style>body{color:red}</style><iframe src="https://evil.example"></iframe><img src="https://tracker.example/p.gif">
        <p>Unclosed <script>evil()
        """
        let text = ReleaseNotes.sanitize(html)
        try expect(!text.contains("alert") && !text.contains("evil") && !text.contains("color:red") && !text.contains("steal"), "Scripts, styles, frames and handlers are removed: \(text)")
        try expect(!text.contains("<") && !text.contains("tracker"), "No tags or remote images remain")
        try expect(text.contains("## What’s new"), "Headings become Markdown headings")
        try expect(text.contains("**sync** & fixes.\nSecond line"), "Bold, entities and line breaks are kept")
        try expect(text.contains("- Item [one](https://example.com/a?x=1&y=2)"), "HTTPS links survive as Markdown links")
        try expect(text.contains("- two") && !text.contains("javascript"), "javascript: links keep only their text")
        try expect(text.contains("- three") && !text.contains("http://"), "Plain HTTP links keep only their text")
        let blocks = ReleaseNotes.blocks(text)
        try expect(blocks.first == .heading(level: 2, text: "What’s new"), "First block is the heading")
        try expect(blocks.filter { if case .bullet = $0 { return true }; return false }.count == 3, "Three bullets")

        let markdown = "# 2.4.0\n\n* Added [docs](https://example.com/docs)\n* Fixed [bug](javascript:alert(1)) and ![img](https://x.example/i.png)\n<details>hidden <b>html</b></details>\n\n---\nThanks"
        let cleaned = ReleaseNotes.sanitize(markdown)
        try expect(!cleaned.contains("<details>") && !cleaned.contains("x.example") && cleaned.contains("img"), "Markdown keeps text, drops inline HTML and image URLs")
        let fixed = ReleaseNotes.inline("Fixed [bug](javascript:alert(1)) and [docs](https://example.com/docs)")
        let links = fixed.runs.compactMap(\.link)
        try expect(links == [URL(string: "https://example.com/docs")!], "Only HTTPS links stay clickable")
        try expect(String(fixed.characters).contains("bug"), "Removed links keep their text")
        try expect(ReleaseNotes.blocks(cleaned).contains(.rule), "Horizontal rules")
        try expect(ReleaseNotes.decodeEntities("&#x41;&#66;&lt;&unknown;&#0;") == "AB<&unknown;&#0;", "Entity decoding is strict")
        let long = ReleaseNotes.sanitize(String(repeating: "a", count: 50_000))
        try expect(long.count <= ReleaseNotes.maximumCharacters + 3, "Notes are capped")
    }

    static func testFeedNotesAndPrereleases() throws {
        let yaml = """
        version: 1.8.5
        files:
          - url: App-1.8.5-arm64.dmg
            sha512: \(String(repeating: "B", count: 86))==
            size: 1200
        path: App-1.8.5-arm64.dmg
        releaseNotes: |
          <h3>Fixes</h3>
          <ul><li>Launcher no longer hangs</li></ul>
        releaseDate: '2026-10-10T16:09:03.272Z'
        """
        let metadata = try ElectronBackend.parseMetadata(yaml)
        try expect(metadata.releaseNotes?.contains("### Fixes") == true && metadata.releaseNotes?.contains("- Launcher no longer hangs") == true, "Electron block releaseNotes are parsed and sanitized")
        let selected = ElectronBackend.select(metadata, baseURL: URL(string: "https://downloads.example.com/")!, installedVersion: "1.8.1", architecture: "arm64")
        try expect(selected?.release?.notes == metadata.releaseNotes, "Selected Electron payload carries its notes")
        try expect(ElectronBackend.releaseNotesValue("version: 1\nreleaseNotes: 'It''s faster'\n") == "It's faster", "Single-quoted notes")
        try expect(ElectronBackend.releaseNotesValue("releaseNotes: \"Line\\nNext\"\n") == "Line\nNext", "Double-quoted notes with escapes")
        try expect(ElectronBackend.releaseNotesValue("releaseNotes:\n  - version: 1.2\n    note: First\n  - version: 1.1\n    note: 'Second'\n") == "First\n\nSecond", "Note lists")
        var beta = metadata; beta.version = "1.9.0-beta.1"
        try expect(ElectronBackend.select(beta, baseURL: URL(string: "https://d.example.com/")!, installedVersion: "1.8.1", architecture: "arm64") == nil, "Electron betas are held by default")
        try expect(ElectronBackend.select(beta, baseURL: URL(string: "https://d.example.com/")!, installedVersion: "1.8.1", architecture: "arm64", allowPrerelease: true)?.version == "1.9.0-beta.1", "Electron betas show when allowed")

        let appcast = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        <item><title>2.1</title><sparkle:version>2.1</sparkle:version><description><![CDATA[<ul><li>Stable fix</li></ul><script>x()</script>]]></description>
        <enclosure url="https://example.com/2.1.zip" sparkle:edSignature="sig" length="1"/></item>
        <item><title>2.2 beta</title><sparkle:version>2.2b1</sparkle:version><sparkle:channel>beta</sparkle:channel>
        <enclosure url="https://example.com/2.2b1.zip" length="1"/></item>
        </channel></rss>
        """
        let stable = try SparkleBackend.parseAppcast(Data(appcast.utf8), installedVersion: "2.0")
        try expect(stable?.version == "2.1" && stable?.notes == "- Stable fix", "Sparkle description becomes sanitized notes: \(stable?.notes ?? "nil")")
        let betaRelease = try SparkleBackend.parseAppcast(Data(appcast.utf8), installedVersion: "2.0", allowPrerelease: true)
        try expect(betaRelease?.version == "2.2b1", "Sparkle beta channel items show when allowed")

        func release(_ tag: String, prerelease: Bool, draft: Bool = false) -> String {
            ###"{"tag_name":"\###(tag)","html_url":"https://github.com/o/r/releases/tag/\###(tag)","draft":\###(draft),"prerelease":\###(prerelease),"body":"## Changes\n- Faster <script>x</script>","assets":[{"name":"App-macos-arm64.dmg","browser_download_url":"https://github.com/o/r/releases/download/\###(tag)/App-macos-arm64.dmg","state":"uploaded"}]}"###
        }
        let latest = try GitHubBackend.parseRelease(Data(release("v2.0", prerelease: false).utf8), repository: "o/r", installedVersion: "1.0", architecture: "arm64")
        try expect(latest?.notes == "## Changes\n- Faster", "GitHub body becomes sanitized notes")
        let list = Data("[\(release("v2.0", prerelease: false, draft: true)),\(release("v3.0.0-beta.2", prerelease: true)),\(release("v2.0", prerelease: false))]".utf8)
        let newest = try GitHubBackend.parseReleaseList(list, repository: "o/r", installedVersion: "1.0", architecture: "arm64")
        try expect(newest?.version == "3.0.0-beta.2" && newest?.isPrerelease == true, "Allowed pre-releases pick the newest non-draft release")
        try expect(try GitHubBackend.parseRelease(Data(release("v3.0.0-beta.2", prerelease: true).utf8), repository: "o/r", installedVersion: "1.0", architecture: "arm64") == nil, "Pre-releases are skipped without permission")
    }

    static func testSigners() throws {
        let output = """
        Executable=/Applications/Demo.app/Contents/MacOS/Demo
        Identifier=com.example.demo
        Authority=Developer ID Application: Example Software Inc (ABCDE12345)
        Authority=Developer ID Certification Authority
        Authority=Apple Root CA
        Timestamp=10 Oct 2026 at 16:09:03
        TeamIdentifier=ABCDE12345
        """
        let identity = SignerIdentity.parse(codesignOutput: output)
        try expect(identity?.teamID == "ABCDE12345" && identity?.signerName == "Example Software Inc" && identity?.certificateKind == "Developer ID Application", "codesign output parses")
        try expect(identity?.authorities.count == 3 && identity?.signedTime == "10 Oct 2026 at 16:09:03" && identity?.identifier == "com.example.demo", "Chain, time and identifier")
        try expect(SignerIdentity.parse(codesignOutput: "Identifier=x\nSignature=adhoc\nTeamIdentifier=not set\n") == nil, "Ad-hoc signatures have no identity")

        let folder = try temporaryFolder("signers")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = TrustedSignerStore(fileURL: folder.appendingPathComponent("nested/trusted-signers.json"))
        try expect(store.load().isEmpty && !store.isApproved(bundleID: "com.example.demo", teamID: "NEWTEAM123"), "Nothing is approved by default")
        let installed = SignerIdentity(teamID: "OLDTEAM123", authorities: ["Developer ID Application: Old Corp (OLDTEAM123)"])
        let candidate = SignerIdentity(teamID: "NEWTEAM123", authorities: ["Developer ID Application: New Corp (NEWTEAM123)"], leafSHA256: "AA:BB")
        let change = SignerChange(appName: "Demo", bundleID: "com.example.demo", version: "2.0", installed: installed, candidate: candidate)
        try expect(change.localizedDescription.contains("NEWTEAM123") && change.localizedDescription.contains("OLDTEAM123"), "The error names both teams")
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let approval = try store.approve(change, now: when)
        let reopened = TrustedSignerStore(fileURL: store.fileURL)
        try expect(reopened.isApproved(bundleID: "com.example.demo", teamID: "NEWTEAM123"), "Approvals persist")
        try expect(!reopened.isApproved(bundleID: "com.example.other", teamID: "NEWTEAM123") && !reopened.isApproved(bundleID: "com.example.demo", teamID: "THIRD12345"), "Approvals cover one app and one team only")
        let stored = reopened.load().first
        try expect(stored?.approvedAt == when && stored?.previousTeamID == "OLDTEAM123" && stored?.signerName == "New Corp" && stored?.certificateSHA256 == "AA:BB", "Approval keeps timestamp and details")
        let mode = (try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber)?.intValue
        try expect(mode == 0o600, "Approval file is owner-only")
        try store.approve(change, now: when.addingTimeInterval(10))
        try expect(store.load().count == 1, "Approving the same team again replaces the entry")
        try store.revoke(store.load()[0].id)
        try expect(!store.isApproved(bundleID: "com.example.demo", teamID: "NEWTEAM123") && store.load().isEmpty, "Revoked approvals are gone")
        _ = approval
    }

    static func makeApp(_ folder: URL, name: String, bundleID: String, version: String) throws -> URL {
        let app = folder.appendingPathComponent("\(name).app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version, "CFBundleExecutable": name, "UWFixtureTeam": "TEAMA11111"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data("x".utf8).write(to: app.appendingPathComponent("Contents/MacOS/\(name)"))
        return app
    }

    static func testHistory() throws {
        let folder = try temporaryFolder("history")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(fileURL: folder.appendingPathComponent("history.json"))
        try expect(store.load().isEmpty, "Empty history")
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func entry(_ minutes: Double, _ result: HistoryEntry.Result, app: String = "/tmp/A.app") -> HistoryEntry {
            HistoryEntry(date: base.addingTimeInterval(minutes * 60), itemID: app, appName: "A", bundleID: "com.example.a", appPath: app,
                         fromVersion: "1", toVersion: "2", source: "Sparkle", result: result, message: "m")
        }
        try store.append(entry(1, .failed))
        try store.append(entry(3, .installed))
        try store.append(entry(2, .installed))
        let loaded = HistoryStore(fileURL: store.fileURL).load()
        try expect(loaded.count == 3 && loaded.map(\.date) == loaded.map(\.date).sorted(by: >), "History persists newest first")
        try expect(loaded[0].result == .installed && loaded[2].result == .failed && loaded[0].source == "Sparkle", "Fields round-trip")
        let updated = try store.update(loaded[2].id) { $0.message = "changed" }
        try expect(updated.first { $0.id == loaded[2].id }?.message == "changed", "Entries can be updated")
        try store.save((0..<520).map { entry(Double($0), .failed) })
        try expect(store.load().count == HistoryStore.maximumEntries, "History is capped at 500 entries")

        // Older history files with backup fields still load.
        let legacy = #"[{"id":"\#(UUID().uuidString)","date":"2026-11-12T19:55:26Z","itemID":"x","appName":"Old","fromVersion":"1","toVersion":"2","source":"Electron","result":"Restored","message":"m","backupPath":"/Applications/.Old-backup-1.app","backupNote":"n"}]"#
        try Data(legacy.utf8).write(to: store.fileURL)
        try expect(store.load().first?.result == .restored && store.load().count == 1, "Earlier history entries still decode")
    }

    /// The scanner reads versions fresh from disk and never lists hidden or backup copies.
    static func testScanner() throws {
        let folder = try temporaryFolder("scanner")
        defer { try? FileManager.default.removeItem(at: folder) }
        let apps = folder.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        let current = try makeApp(apps, name: "Invoke Demo", bundleID: "com.example.invoke", version: "1.8.1")
        // Leftover copies from earlier builds: hidden, visible *-backup-*, and a hidden staging folder.
        let hidden = try makeApp(folder.appendingPathComponent("tmp1"), name: "Invoke Demo", bundleID: "com.example.invoke", version: "1.8.0")
        try FileManager.default.moveItem(at: hidden, to: apps.appendingPathComponent(".Invoke Demo-backup-\(UUID().uuidString).app"))
        let visible = try makeApp(folder.appendingPathComponent("tmp2"), name: "Invoke Demo", bundleID: "com.example.invoke", version: "1.7.0")
        try FileManager.default.moveItem(at: visible, to: apps.appendingPathComponent("Invoke Demo-backup-2026.app"))
        let staging = try makeApp(folder.appendingPathComponent("tmp3"), name: "Stage", bundleID: "com.example.invoke", version: "1.8.5")
        try FileManager.default.moveItem(at: staging, to: apps.appendingPathComponent(".UpdateWorkbench-stage-1.app"))
        try expect(AppBundleInfo.isHiddenOrBackupCopy(URL(fileURLWithPath: "/Applications/.Invoke-backup-ED50.app"))
                   && AppBundleInfo.isHiddenOrBackupCopy(URL(fileURLWithPath: "/Applications/Invoke-Backup-old.app"))
                   && !AppBundleInfo.isHiddenOrBackupCopy(URL(fileURLWithPath: "/Applications/Backup Pro.app")), "Hidden and *-backup-* copies are recognised")

        var scanned = Engine.installedApps(roots: [apps])
        try expect(scanned.count == 1 && scanned[0].path.map { URL(fileURLWithPath: $0).lastPathComponent } == current.lastPathComponent && scanned[0].installedVersion == "1.8.1", "Only the real app is scanned: \(scanned.map(\.path))")
        // Prime Bundle's cache the way 0.4.0 did, then replace the app in place as an update does.
        _ = Bundle(url: current)?.infoDictionary
        let updated = try makeApp(folder.appendingPathComponent("tmp4"), name: "Invoke Demo", bundleID: "com.example.invoke", version: "1.8.5")
        try FileManager.default.removeItem(at: current)
        try FileManager.default.moveItem(at: updated, to: current)
        scanned = Engine.installedApps(roots: [apps])
        try expect(scanned.count == 1 && scanned[0].installedVersion == "1.8.5", "A rescan in the same process sees the new version: \(scanned.map(\.installedVersion))")
        try expect(AppBundleInfo.read(current)["CFBundleShortVersionString"] as? String == "1.8.5", "Info.plist is read from disk")
        let updateFeed = SparkleRelease(version: "1.8.5", downloadURL: URL(string: "https://example.com/a.dmg")!, releaseNotesURL: nil)
        try expect(!SparkleBackend.isNewer(updateFeed.version, than: scanned[0].installedVersion), "1.8.5 is no longer offered over 1.8.5")
    }

    /// mas output parsing, matching, error wording and the Terminal hand-off script.
    static func testAppStoreCLI() throws {
        let json = """
        {"adamID":497799835,"bundleID":"com.apple.dt.Xcode","name":"Xcode","newVersion":"27.1","path":"/Applications/Xcode.app","version":"27.0"}
        {"adamID":"1586435171","bundleID":"com.example.actions","displayName":"Actions","newVersion":"4.3","version":"4.2.1"}
        {"adamID":0,"name":"Broken","newVersion":"1"}
        not json
        """
        let parsed = AppStoreCLI.parseOutdated(json)
        try expect(parsed.count == 2 && parsed[0] == AppStoreCLI.OutdatedApp(adamID: "497799835", name: "Xcode", bundleID: "com.apple.dt.Xcode", path: "/Applications/Xcode.app", installedVersion: "27.0", latestVersion: "27.1"), "JSON lines parse: \(parsed)")
        try expect(parsed[1].adamID == "1586435171" && parsed[1].name == "Actions" && parsed[1].path == nil, "String IDs and display names parse")
        let legacy = AppStoreCLI.parseOutdated(" 571213070  DaVinci Resolve   (21.2.0  -> 21.3.0)\n1470584107  Dato  (5.8.4 → 5.9)")
        try expect(legacy.map(\.adamID) == ["571213070", "1470584107"] && legacy[0].name == "DaVinci Resolve" && legacy[0].installedVersion == "21.2.0" && legacy[1].latestVersion == "5.9", "Text output parses: \(legacy)")
        try expect(AppStoreCLI.parseOutdated("").isEmpty, "No updates means an empty list")

        let items = [
            UpdateItem(id: "/Applications/Xcode.app", name: "Xcode", bundleID: "com.apple.dt.Xcode", path: "/Applications/Xcode.app", installedVersion: "27.0", provider: .appStore, detail: ""),
            UpdateItem(id: "/Applications/Actions.app", name: "Actions", bundleID: "com.example.actions", path: "/Applications/Actions.app", installedVersion: "4.2.1", provider: .manual, detail: ""),
            UpdateItem(id: "/Applications/DaVinci Resolve.app", name: "DaVinci Resolve", path: "/Applications/DaVinci Resolve.app", installedVersion: "21.2.0", provider: .appStore, detail: ""),
        ]
        try expect(AppStoreCLI.match(parsed[0], in: items) == 0 && AppStoreCLI.match(parsed[1], in: items) == 1 && AppStoreCLI.match(legacy[0], in: items) == 2, "Matched by path, bundle ID, then name")
        try expect(AppStoreCLI.match(AppStoreCLI.OutdatedApp(adamID: "1", name: "Nope", installedVersion: "1", latestVersion: "2"), in: items) == nil, "Unknown apps don't match")

        try expect(AppStoreCLI.classify("sudo: a terminal is required to read the password; either use the -S option") == .needsAdministrator, "sudo without a terminal needs an administrator")
        try expect(AppStoreCLI.classify("Error: Not signed in to the App Store") == .notSignedIn, "Not signed in")
        try expect(AppStoreCLI.classify("Error Domain=NSURLErrorDomain Code=-1001 \"The request timed out.\"") == .network, "Network timeouts")
        try expect(AppStoreCLI.message(for: "Error: Not signed in", action: "update Xcode").contains("sign in"), "Not-signed-in help")
        try expect(AppStoreCLI.message(for: "sudo: a password is required", action: "update Xcode").contains("Finish in Terminal"), "Administrator help")
        try expect(AppStoreCLI.message(for: "Error: something odd\nmore", action: "update Xcode") == "mas couldn't update Xcode: Error: something odd more", "Other errors keep the output")

        try expect(AppStoreCLI.validID("497799835") && !AppStoreCLI.validID("12; rm -rf /") && !AppStoreCLI.validID("") && !AppStoreCLI.validID(nil) && !AppStoreCLI.validID("１２"), "Only ASCII digit IDs")
        let script = AppStoreCLI.terminalScript(mas: "/opt/homebrew/bin/mas", adamID: "497799835", name: "Xcode $(evil)")
        try expect(script?.contains("'/opt/homebrew/bin/mas' update 497799835") == true && script?.contains("$(evil)") == false, "Terminal script runs only mas update <id>")
        try expect(AppStoreCLI.terminalScript(mas: "/tmp/mas", adamID: "1", name: "X") == nil && AppStoreCLI.terminalScript(mas: "/opt/homebrew/bin/mas", adamID: "1;x", name: "X") == nil, "Unknown mas paths and bad IDs are refused")
    }
}

/// Models Developer ID signing through Info.plist keys so fixture apps can have "teams" without real certificates.
struct FixtureVerifier: SignatureVerifier {
    func info(_ app: URL) -> [String: Any] { AppBundleInfo.read(app) }
    func verify(_ app: URL) throws {
        if info(app)["UWFixtureBroken"] as? Bool == true { throw SparkleBackend.Failure(message: "codesign failed: a sealed resource is missing or invalid") }
    }
    func assess(_ app: URL) throws -> String {
        if info(app)["UWFixtureRejected"] as? Bool == true { throw SparkleBackend.Failure(message: "spctl failed: rejected") }
        return "Notarized Developer ID"
    }
    func identity(_ app: URL) throws -> SignerIdentity {
        guard let team = info(app)["UWFixtureTeam"] as? String else { throw SparkleBackend.Failure(message: "Ad-hoc or unsigned apps cannot be replaced directly.") }
        let signer = info(app)["UWFixtureSigner"] as? String ?? "Fixture Corp"
        return SignerIdentity(teamID: team, authorities: ["Developer ID Application: \(signer) (\(team))", "Developer ID Certification Authority", "Apple Root CA"],
                              identifier: info(app)["CFBundleIdentifier"] as? String, signedTime: "12 Nov 2026 at 10:00:00", leafSHA256: "12:34:56:78", leafExpires: nil)
    }
}
