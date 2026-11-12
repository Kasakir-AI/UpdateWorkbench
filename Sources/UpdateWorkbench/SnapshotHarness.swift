import SwiftUI
import AppKit

/// Renders every screen with fake data into PNGs (dark and light) for visual review and README screenshots.
/// Invoked with `UpdateWorkbench --render-snapshots <folder>`. Uses volatile defaults so no real settings,
/// paths or personal data are read or written, and never scans, installs or probes the system.
@MainActor
enum SnapshotHarness {
    static func run(outputFolder: String) {
        let defaults: [String: Any] = [
            "customRoots": ["/Volumes/Apps"], "interval": 14400.0, "ignored": [String](), "skipped": [String: String](),
            "snoozed": [String: Double](), "notificationsEnabled": true, AppearanceMode.defaultsKey: AppearanceMode.dark.rawValue,
            CheckSchedule.defaultsKey: CheckSchedule.daily.rawValue,
            SelfUpdateFeed.defaultsKey: "", ProxySettings.defaultsKey: (try? JSONEncoder().encode(ProxySettings())) ?? Data(),
        ]
        UserDefaults.standard.setVolatileDomain(defaults, forName: UserDefaults.argumentDomain)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let folder = URL(fileURLWithPath: outputFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var written: [String] = []
        for dark in [true, false] {
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let suffix = dark ? "dark" : "light"
            for scenario in Scenario.allCases {
                let model = makeModel(scenario)
                let view = ContentView().environmentObject(model).tint(Theme.accent)
                if let path = render(view, size: CGSize(width: 1280, height: 800), dark: dark, name: "main-\(scenario.rawValue)-\(suffix)", folder: folder) { written.append(path) }
            }
            let model = makeModel(.updates)
            let tabs: [(String, AnyView)] = [
                ("general", AnyView(GeneralSettingsView())), ("rules", AnyView(RulesSettingsView())), ("trust", AnyView(TrustSettingsView())),
                ("appearance", AnyView(AppearanceSettingsView())), ("network", AnyView(ProxySettingsView())), ("updates", AnyView(SelfUpdateSettingsView())),
            ]
            for (name, tab) in tabs {
                let view = tab.environmentObject(model).tint(Theme.accent).frame(width: 640, height: 540)
                if let path = render(view, size: CGSize(width: 640, height: 540), dark: dark, name: "settings-\(name)-\(suffix)", folder: folder, toolbar: false) { written.append(path) }
            }
            // Sheets and the menu bar panel, rendered on their own at their natural width.
            let aurora = model.items.first { $0.id == "aurora" }!
            let sheets: [(String, CGSize, AnyView)] = [
                ("sheet-signer-approval", CGSize(width: 660, height: 790), AnyView(SignerApprovalSheet(change: FakeData.signerChange))),
                ("sheet-update-notes", CGSize(width: 580, height: 560), AnyView(UpdateConfirmSheet(item: aurora))),
                ("sheet-license", CGSize(width: 560, height: 480), AnyView(LicenseSheet(prompt: FakeData.license))),
                ("menubar-panel", CGSize(width: 340, height: 440), AnyView(MenuBarPanel())),
            ]
            for (name, size, sheet) in sheets {
                let view = sheet.environmentObject(model).tint(Theme.accent).frame(width: size.width, height: size.height, alignment: .top)
                    .background(Color(nsColor: .windowBackgroundColor))
                if let path = render(view, size: size, dark: dark, name: "\(name)-\(suffix)", folder: folder, toolbar: false) { written.append(path) }
            }
        }
        print(written.joined(separator: "\n"))
        print("Rendered \(written.count) snapshots to \(folder.path)")
    }

    enum Scenario: String, CaseIterable {
        case firstRun = "first-run"
        case scanning
        case updates
        case updatesDetail = "updates-detail"
        case vendorDetail = "vendor-detail"
        case suggestions
        case homebrewDetail = "homebrew-detail"
        case upToDate = "up-to-date"
        case ignored
        case noMatches = "no-matches"
        case console
        case permissions
        case history
    }

    static func makeModel(_ scenario: Scenario) -> WorkbenchModel {
        let model = WorkbenchModel(preview: true)
        model.permissions = PermissionsBackend.checks(.init(fullDiskAccess: nil, notifications: true, isAdmin: true,
                                                            destinations: [("/Applications", true), ("/Volumes/Apps", false)],
                                                            launchAtLogin: "Not registered", proxyPasswordStored: false))
        switch scenario {
        case .firstRun: return model
        case .scanning: model.busy = true; model.operation = "Checking update sources…"; return model
        default: break
        }
        model.items = FakeData.items
        model.lastCheck = Date().addingTimeInterval(-180)
        model.snoozed = ["canvas": Date().addingTimeInterval(2 * 86400).timeIntervalSince1970]
        model.ignored = ["retro"]
        model.skipped = ["tidy": "1.0.0"]
        model.prereleaseRules = ["orbit": .allow, "pixelforge": .hold]
        model.history = FakeData.history
        model.approvals = FakeData.approvals
        model.lastScheduledCheck = Date().addingTimeInterval(-3 * 3600)
        switch scenario {
        case .updates: model.section = .updates
        case .updatesDetail: model.section = .updates; model.selected = "aurora"
        case .vendorDetail: model.section = .applications; model.selected = "lumen"
        case .suggestions: model.section = .suggestions; model.selected = "quill"
        case .homebrewDetail: model.section = .packages; model.selected = "node"
        case .upToDate: model.items = FakeData.items.map { var item = $0; if item.isOutdated { item.installedVersion = item.latestVersion ?? item.installedVersion; item.isOutdated = false }; return item }
            model.ignored = []; model.snoozed = [:]
        case .ignored: model.section = .ignored; model.selected = "canvas"
        case .noMatches: model.section = .applications; model.search = "zebra"
        case .console:
            model.section = .updates; model.selected = "pixelforge"; model.showConsole = true
            model.failures = ["pixelforge": "Quit PixelForge before updating it."]
            model.log = "Ready. Check for updates to scan installed applications.\n[10:41:02] Checking installed apps and update sources…\n[10:41:09] Found 14 apps and packages; 7 available updates.\n[10:42:15] Updating PixelForge…\n[10:42:16] PixelForge: Quit PixelForge before updating it."
        case .permissions: model.section = .permissions
        case .history: model.section = .history; model.selectedHistory = model.history.first?.id
        default: break
        }
        return model
    }

    /// Renders inside an offscreen titled window so the toolbar, sidebar and lists lay out as in the app.
    static func render<V: View>(_ view: V, size: CGSize, dark: Bool, name: String, folder: URL, toolbar: Bool = true) -> String? {
        let controller = NSHostingController(rootView: view.environment(\.colorScheme, dark ? .dark : .light).environment(\.controlActiveState, .key))
        controller.sizingOptions = [.minSize]
        if toolbar { controller.sceneBridgingOptions = [.toolbars, .title] }
        let window = OffscreenWindow(contentRect: CGRect(origin: CGPoint(x: -6000, y: -6000), size: size),
                                     styleMask: toolbar ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.titled, .closable],
                                     backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(size)
        if toolbar { window.toolbarStyle = .unified; window.title = "Update Workbench" }
        window.setFrameOrigin(CGPoint(x: -6000, y: -6000))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        let target: NSView = window.contentView?.superview ?? window.contentView!
        target.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let minimum = window.contentMinSize
        if minimum.height > size.height + 1 || minimum.width > size.width + 1 {
            print("LAYOUT WARNING: \(name) needs at least \(Int(minimum.width))×\(Int(minimum.height)) pt, rendered at \(Int(size.width))×\(Int(size.height))")
        }
        window.setContentSize(size)
        target.layoutSubtreeIfNeeded()
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return nil }
        target.cacheDisplay(in: target.bounds, to: rep)
        window.orderOut(nil)
        window.close()
        let url = folder.appendingPathComponent("\(name).png")
        guard let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: url)) != nil else { return nil }
        return url.path
    }
}

final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    /// Draw controls in their active (key window) style without activating the app or stealing focus.
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

/// Fictional apps used only for snapshots and screenshots.
enum FakeData {
    static let release: SparkleRelease = {
        var release = SparkleRelease(version: "2.4.0", downloadURL: URL(string: "https://downloads.example.com/aurora-2.4.0.zip")!, releaseNotesURL: URL(string: "https://example.com/aurora/notes")!)
        release.notes = ReleaseNotes.sanitize("""
        <h2>Aurora Notes 2.4</h2><p>A faster editor and <b>offline sync</b> that finally keeps up with large notebooks.</p>
        <ul><li>New outline sidebar with drag and drop</li><li>Search is up to 3× faster on big libraries</li>
        <li>Fixed a crash when pasting tables from <a href="https://example.com/aurora/help">spreadsheets</a></li></ul>
        <hr><p>Thanks to everyone who sent feedback.</p><script>trackInstall()</script>
        """)
        return release
    }()

    static let signerChange = SignerChange(appName: "Orbit Chat", bundleID: "com.example.orbit", version: "1.8.5",
        installed: SignerIdentity(teamID: "ORBIT12345", authorities: ["Developer ID Application: Orbit Labs, Inc (ORBIT12345)", "Developer ID Certification Authority", "Apple Root CA"],
                                  identifier: "com.example.orbit", signedTime: "Sep 3, 2026 at 14:12:09", leafSHA256: "3F9A 51C2 77E0 9B14 C8D3 0A6E 52F1 B7C9 4E28 61AD 0C93 FE57 2B8D 14A6 E0C7 59F3",
                                  leafExpires: Date(timeIntervalSince1970: 1_893_456_000), gatekeeper: "Notarized Developer ID"),
        candidate: SignerIdentity(teamID: "NEWTEAM678", authorities: ["Developer ID Application: Example Developer (NEWTEAM678)", "Developer ID Certification Authority", "Apple Root CA"],
                                  identifier: "com.example.orbit", signedTime: "Nov 9, 2026 at 09:41:55", leafSHA256: "A41C 0E77 9D25 6B83 F1C4 27E9 5A0D 8C36 B9F2 1E74 C05A 93D8 6F21 4BE7 0A39 D5C8",
                                  leafExpires: Date(timeIntervalSince1970: 1_956_528_000), gatekeeper: "Notarized Developer ID"))

    static let license = LicenseAgreementRequired(appName: "Aurora Notes", version: "2.4.0",
        text: "AURORA NOTES SOFTWARE LICENSE\n\nThis fictional agreement is shown before the disk image is opened. By clicking Agree you accept these terms for the sample app.\n\n1. You may use the software on any Mac you own.\n2. The software is provided as is, without warranty of any kind.")

    static var history: [HistoryEntry] {
        let now = Date()
        return [
            HistoryEntry(date: now.addingTimeInterval(-1_800), itemID: "aurora", appName: "Aurora Notes", bundleID: "com.example.aurora-notes", appPath: "/Applications/Aurora Notes.app",
                         fromVersion: "2.3.0", toVersion: "2.3.1", source: "Sparkle", result: .installed, message: "Installed 2.3.1. The previous version was removed after the new one passed its checks."),
            HistoryEntry(date: now.addingTimeInterval(-26 * 3600), itemID: "pixelforge", appName: "PixelForge", bundleID: "com.example.pixelforge", appPath: "/Applications/PixelForge.app",
                         fromVersion: "5.1.0", toVersion: "5.2.0", source: "Homebrew", result: .failed, message: "Quit PixelForge before updating it."),
            HistoryEntry(date: now.addingTimeInterval(-3 * 86400), itemID: "orbit", appName: "Orbit Chat", bundleID: "com.example.orbit", appPath: "/Applications/Orbit Chat.app",
                         fromVersion: "1.8.0", toVersion: "1.8.1", source: "Electron (DMG)", result: .installed, message: "Installed Orbit Chat 1.8.1."),
            HistoryEntry(date: now.addingTimeInterval(-4 * 86400), itemID: "tidy", appName: "Tidy Terminal", bundleID: "com.example.tidy", appPath: "/Applications/Tidy Terminal.app",
                         fromVersion: "0.9.3", toVersion: "1.0.0", source: "GitHub", result: .installed, message: "Installed 1.0.0. The previous version was removed after the new one passed its checks."),
            HistoryEntry(date: now.addingTimeInterval(-9 * 86400), itemID: "harbor", appName: "Harbor VPN", fromVersion: "2.9", toVersion: "3.0", source: "App Store",
                         result: .installed, message: "Updated through the Mac App Store."),
        ]
    }

    static var approvals: [TrustedSignerApproval] {
        [TrustedSignerApproval(bundleID: "com.example.tidy", appName: "Tidy Terminal", teamID: "TIDYNEW001", signerName: "Tidy Software GmbH",
                               previousTeamID: "TIDYOLD999", previousSignerName: "Example Developer", certificateSHA256: "5C1E 9A04 77B2 0D6F",
                               approvedAt: Date().addingTimeInterval(-6 * 86400))]
    }
    static var items: [UpdateItem] {
        [
            UpdateItem(id: "aurora", name: "Aurora Notes", bundleID: "com.example.aurora-notes", path: "/Applications/Aurora Notes.app", installedVersion: "2.3.1", latestVersion: "2.4.0", provider: .sparkle,
                       feedURL: URL(string: "https://example.com/aurora/appcast.xml"), homepage: URL(string: "https://example.com/aurora"), isOutdated: true,
                       detail: "Sparkle feed declared by the app. Archive signatures are verified before installing.", sparkleRelease: release),
            UpdateItem(id: "pixelforge", name: "PixelForge", bundleID: "com.example.pixelforge", path: "/Applications/PixelForge.app", installedVersion: "5.1.0", latestVersion: "5.2.0", provider: .homebrewCask, token: "pixelforge", isOutdated: true, detail: "Homebrew cask pixelforge."),
            UpdateItem(id: "harbor", name: "Harbor VPN", bundleID: "com.example.harbor", path: "/Applications/Harbor VPN.app", installedVersion: "3.0", latestVersion: "3.1", provider: .appStore, token: "1234567890", isOutdated: true, detail: "Mac App Store app."),
            UpdateItem(id: "orbit", name: "Orbit Chat", bundleID: "com.example.orbit", path: "/Applications/Orbit Chat.app", installedVersion: "1.8.1", latestVersion: "1.8.5", provider: .electron, isOutdated: true,
                       detail: "electron-updater feed with a published SHA-512.", sparkleRelease: SparkleRelease(version: "1.8.5", downloadURL: URL(string: "https://downloads.example.com/orbit-1.8.5-arm64.zip")!, releaseNotesURL: nil, sha512: "abc"),
                       electronUpdate: ElectronUpdateConfig(provider: .github, owner: "example", repo: "orbit-chat")),
            UpdateItem(id: "tidy", name: "Tidy Terminal", bundleID: "com.example.tidy", path: "/Applications/Tidy Terminal.app", installedVersion: "0.9.3", latestVersion: "1.0.0", provider: .github, isOutdated: true,
                       detail: "Latest stable release on GitHub.", githubRepository: "example/tidy-terminal",
                       githubRelease: GitHubRelease(version: "1.0.0", releasePageURL: URL(string: "https://github.com/example/tidy-terminal/releases/tag/v1.0.0")!, downloadURL: URL(string: "https://github.com/example/tidy-terminal/releases/download/v1.0.0/Tidy.zip")!)),
            UpdateItem(id: "sketch", name: "Sketchbook Studio", bundleID: "com.example.sketchbook", path: "/Applications/Sketchbook Studio.app", installedVersion: "4.2", latestVersion: "4.3", provider: .github, isOutdated: true,
                       detail: "The release has several macOS downloads, so it can't be chosen automatically. Open the release page to install it.", githubRepository: "example/sketchbook",
                       githubRelease: GitHubRelease(version: "4.3", releasePageURL: URL(string: "https://github.com/example/sketchbook/releases/tag/4.3")!, downloadURL: nil)),
            UpdateItem(id: "ffmpeg", name: "ffmpeg", installedVersion: "7.0.2", latestVersion: "7.1", provider: .homebrewFormula, token: "ffmpeg", isOutdated: true, detail: "Homebrew formula."),
            UpdateItem(id: "node", name: "node", installedVersion: "22.11.0", latestVersion: "22.11.0", provider: .homebrewFormula, token: "node", detail: "Homebrew formula. Pinned by you.", isPinned: true),
            UpdateItem(id: "wget", name: "wget", installedVersion: "1.25.0", latestVersion: "1.25.0", provider: .homebrewFormula, token: "wget", detail: "Homebrew formula."),
            UpdateItem(id: "lumen", name: "Lumen Browser", bundleID: "com.example.lumen", path: "/Applications/Lumen Browser.app", installedVersion: "131.0.2", provider: .vendor, detail: "Updated by the browser's built-in updater.",
                       vendorUpdater: VendorUpdater(name: "Lumen Update", instructions: "Open Lumen Browser and choose Lumen Browser → About to download and install updates.", launchPath: nil)),
            UpdateItem(id: "quill", name: "Quill Writer", bundleID: "com.example.quill", path: "/Applications/Quill Writer.app", installedVersion: "3.4", provider: .manual, detail: "No update feed was found in the app.",
                       repositorySuggestions: [RepositorySuggestion(repository: "example/quill-writer", evidence: "Found in the app's Info.plist (website URL).")],
                       caskSuggestions: [CaskSuggestion(token: "quill-writer", name: "Quill Writer", version: "3.5", confidence: .high, evidence: "App name and bundle ID match the cask.", homepage: URL(string: "https://example.com/quill"))]),
            UpdateItem(id: "drift", name: "Driftwood", bundleID: "com.example.driftwood", path: "/Applications/Driftwood.app", installedVersion: "1.2.0", provider: .manual, detail: "No update feed was found in the app.",
                       caskSuggestions: [CaskSuggestion(token: "driftwood", name: "Driftwood", version: "1.3.0", confidence: .medium, evidence: "App name matches the cask's app artifact.", homepage: nil)]),
            UpdateItem(id: "canvas", name: "Canvas Studio", bundleID: "com.example.canvas", path: "/Applications/Canvas Studio.app", installedVersion: "8.0", latestVersion: "8.1", provider: .homebrewCask, token: "canvas-studio", isOutdated: true, detail: "Homebrew cask canvas-studio."),
            UpdateItem(id: "retro", name: "Retro Player", bundleID: "com.example.retro", path: "/Applications/Retro Player.app", installedVersion: "2.0", latestVersion: "2.1", provider: .sparkle, isOutdated: true, detail: "Sparkle feed declared by the app.", sparkleRelease: release),
        ]
    }
}
