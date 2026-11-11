import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class WorkbenchModel: ObservableObject {
    @Published var items: [UpdateItem] = []
    @Published var busy = false
    @Published var log = "Ready. Check for updates to scan installed applications."
    @Published var selected: String?
    @Published var search = ""
    @Published var section: SidebarSection = .updates
    @Published var sourceFilter = "All sources"
    @Published var lastCheck: Date?
    @Published var operation = "Ready"
    @Published var ignored: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "ignored") ?? [])
    @Published var skipped: [String: String] = UserDefaults.standard.dictionary(forKey: "skipped") as? [String: String] ?? [:]
    @Published var snoozed: [String: Double] = UserDefaults.standard.dictionary(forKey: "snoozed") as? [String: Double] ?? [:]
    @Published var interval: Double = UserDefaults.standard.double(forKey: "interval")
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var notificationsEnabled = UserDefaults.standard.bool(forKey: "notificationsEnabled")
    @Published var permissions: [PermissionCheck] = []
    @Published var selfUpdateRelease: SparkleRelease?
    @Published var selfUpdateMessage = ""
    @Published var selfUpdateInstalled = false
    @Published var failures: [String: String] = [:]
    @Published var showConsole = false
    @Published var confirmUpdateAll = false
    @Published var appearance = AppearanceMode.stored(UserDefaults.standard.string(forKey: AppearanceMode.defaultsKey)) {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: AppearanceMode.defaultsKey); applyAppearance() }
    }
    /// Snapshot/preview mode: fake data, no timers, notifications, scans or system probes.
    let isPreview: Bool
    private var caskSuggestionCache: [String: [CaskSuggestion]] = [:]
    private let engine = Engine()
    private var timer: Timer?
    init(preview: Bool = false) {
        isPreview = preview
        if !preview { Notifier.configure(); schedule() }
    }
    func applyAppearance() { NSApp?.appearance = appearance.nsAppearance }
    var scanned: Bool { lastCheck != nil }
    var directUpdates: [UpdateItem] { updates.filter(\.canUpdateDirectly) }
    func status(_ item: UpdateItem) -> ItemStatus {
        ItemStatus.classify(item, ignored: ignored.contains(item.id), skippedVersion: skipped[item.id], snoozedUntil: snoozed[item.id], failure: failures[item.id])
    }
    func count(_ section: SidebarSection) -> Int {
        switch section {
        case .updates: updates.count
        case .suggestions: suggestions.count
        case .ignored: ignoredItems.count
        case .packages: items.filter { $0.provider == .homebrewFormula }.count
        case .applications: items.filter { $0.provider != .homebrewFormula }.count
        case .permissions: permissions.filter { $0.state == .denied }.count
        }
    }
    var ignoredItems: [UpdateItem] { items.filter { ignored.contains($0.id) || (skipped[$0.id] != nil && skipped[$0.id] == $0.latestVersion) || (snoozed[$0.id] ?? 0) > Date().timeIntervalSince1970 } }
    var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? AppIdentity.version }
    var suggestions: [UpdateItem] {
        items.filter { item in
            (item.provider == .manual || item.provider == .vendor || (item.provider == .electron && !item.canUpdateDirectly))
                && (!(item.repositorySuggestions ?? []).isEmpty || !(item.caskSuggestions ?? []).isEmpty)
        }
    }
    var updates: [UpdateItem] { items.filter { $0.isOutdated && !ignored.contains($0.id) && skipped[$0.id] != $0.latestVersion && (snoozed[$0.id] ?? 0) <= Date().timeIntervalSince1970 } }
    var visible: [UpdateItem] {
        let base: [UpdateItem]
        switch section {
        case .updates: base = updates
        case .suggestions: base = suggestions
        case .ignored: base = ignoredItems
        case .packages: base = items.filter { $0.provider == .homebrewFormula }
        case .applications: base = items.filter { $0.provider != .homebrewFormula }
        case .permissions: base = []
        }
        return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }.filter { (sourceFilter == "All sources" || $0.provider.rawValue == sourceFilter) && (search.isEmpty || "\($0.name) \($0.bundleID ?? "") \($0.provider.rawValue)".localizedCaseInsensitiveContains(search)) }
    }
    var chosen: UpdateItem? { items.first { $0.id == selected } }
    func append(_ text: String) {
        log += "\n[\(Date().formatted(date: .omitted, time: .standard))] \(text)"
        if log.count > 200_000 { log = "[Earlier console output omitted]\n" + String(log.suffix(160_000)) }
    }
    func scan() {
        guard !busy, !isPreview else { return }; busy = true; operation = "Checking update sources…"; append("Checking installed apps and update sources…")
        Task {
            var scanned = await engine.scan()
            for index in scanned.indices { if let cached = caskSuggestionCache[scanned[index].id] { scanned[index].caskSuggestions = cached } }
            items = scanned; lastCheck = Date()
            for line in await engine.lastDiagnostics() { append(line) }
            append("Found \(items.count) apps and packages; \(updates.count) available updates.")
            busy = false; operation = "Check complete"; failures = failures.filter { id, _ in items.contains { $0.id == id && $0.isOutdated } }
            notifyAvailableUpdates()
        }
    }
    func update(_ targets: [UpdateItem]) {
        guard !busy else { return }; busy = true
        Task {
            let actionable = targets.filter(\.canUpdateDirectly)
            var succeeded: [String] = [], failed: [String] = []
            for (index, item) in actionable.enumerated() {
                operation = "Updating \(index + 1) of \(actionable.count): \(item.name)"
                append("Updating \(item.name)…")
                do { append(try await engine.update(item)); succeeded.append(item.name); failures.removeValue(forKey: item.id) }
                catch { append("\(item.name): \(error.localizedDescription)"); failed.append(item.name); failures[item.id] = error.localizedDescription }
            }
            if notificationsEnabled, let message = UpdateNotificationPolicy.resultMessage(succeeded: succeeded, failed: failed) {
                Notifier.post(title: message.title, body: message.body, identifier: "result-\(UUID().uuidString)")
            }
            busy = false; operation = failed.isEmpty ? "Updates finished" : "\(failed.count) update(s) failed. See Console."; if !failed.isEmpty { showConsole = true }; scan()
        }
    }
    func ignore(_ item: UpdateItem) {
        if ignored.contains(item.id) { ignored.remove(item.id) } else { ignored.insert(item.id) }
        UserDefaults.standard.set(Array(ignored), forKey: "ignored")
    }
    func skip(_ item: UpdateItem) {
        if skipped[item.id] == item.latestVersion { skipped.removeValue(forKey: item.id) }
        else { skipped[item.id] = item.latestVersion }
        UserDefaults.standard.set(skipped, forKey: "skipped")
    }
    func snooze(_ item: UpdateItem, days: Int) {
        if days == 0 { snoozed.removeValue(forKey: item.id) }
        else { snoozed[item.id] = Date().addingTimeInterval(Double(days) * 86400).timeIntervalSince1970 }
        UserDefaults.standard.set(snoozed, forKey: "snoozed")
    }
    func schedule() {
        timer?.invalidate(); UserDefaults.standard.set(interval, forKey: "interval")
        if interval > 0 { timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in Task { @MainActor in self?.scan() } } }
    }
    func setLogin(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; launchAtLogin = enabled }
        catch { append("Login setting: \(error.localizedDescription)") }
    }
    func refreshCatalog() {
        guard !busy else { return }; busy = true
        Task {
            do { append(try await engine.refreshHomebrewCatalog()) } catch { append(error.localizedDescription) }
            busy = false; scan()
        }
    }
    func maintain(_ action: String) {
        guard !busy else { return }; busy = true
        Task {
            do { append(try await engine.maintenance(action)) } catch { append(error.localizedDescription) }
            busy = false
        }
    }
    func adopt(_ token: String) {
        guard !busy else { return }; busy = true
        Task {
            do { append(try await engine.adoptCask(token: token)) } catch { append(error.localizedDescription) }
            busy = false; scan()
        }
    }
    func notifyAvailableUpdates() {
        guard notificationsEnabled else { return }
        let candidates = updates.map { UpdateNotificationPolicy.Candidate(id: $0.id, name: $0.name, version: $0.latestVersion ?? "") }
        let notified = UserDefaults.standard.dictionary(forKey: "notifiedUpdates") as? [String: String] ?? [:]
        let fresh = UpdateNotificationPolicy.newlyAvailable(candidates, alreadyNotified: notified)
        UserDefaults.standard.set(UpdateNotificationPolicy.record(fresh, current: candidates, into: notified), forKey: "notifiedUpdates")
        if let message = UpdateNotificationPolicy.availableMessage(fresh) {
            Notifier.post(title: message.title, body: message.body, identifier: "available-\(UUID().uuidString)")
        }
    }
    func setNotifications(_ enabled: Bool) {
        notificationsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "notificationsEnabled")
        guard enabled else { return }
        Task {
            if !(await Notifier.requestAuthorization()) {
                append("macOS has not allowed notifications for Update Workbench. Allow them in System Settings → Notifications.")
            }
        }
    }
    func findHomebrewMatches() {
        guard !busy else { return }; busy = true; operation = "Matching apps to Homebrew casks…"
        append("Matching installed apps to Homebrew casks (read-only; no brew update)…")
        Task {
            do {
                let result = try await engine.caskSuggestions(for: items)
                caskSuggestionCache = result
                for index in items.indices { items[index].caskSuggestions = result[items[index].id] }
                for line in await engine.lastDiagnostics() { append(line) }
                append("Found Homebrew cask suggestions for \(result.count) apps. Adoption runs only after you confirm it.")
            } catch { append(error.localizedDescription) }
            busy = false; operation = "Matching complete"
        }
    }
    func useRepository(_ repository: String, for item: UpdateItem) {
        guard GitHubBackend.validRepository(repository) else { append("Invalid GitHub repository \(repository)."); return }
        var repositories = UserDefaults.standard.dictionary(forKey: "githubOverrides") as? [String: String] ?? [:]
        repositories[item.bundleID ?? item.id] = repository
        UserDefaults.standard.set(repositories, forKey: "githubOverrides")
        append("Using GitHub Releases from \(repository) for \(item.name).")
        scan()
    }
    func manage(_ action: HomebrewAction, _ item: UpdateItem) {
        guard !busy else { return }; busy = true; operation = "\(action.rawValue): \(item.name)"
        Task {
            append("\(action.rawValue) \(item.name)…")
            do { append(try await engine.manage(action, item: item)) } catch { append("\(item.name): \(error.localizedDescription)") }
            busy = false; scan()
        }
    }
    func moveToTrash(_ item: UpdateItem) {
        guard !busy else { return }; busy = true
        Task {
            do { append(try await engine.moveToTrash(item)) } catch { append("\(item.name): \(error.localizedDescription)") }
            busy = false; scan()
        }
    }
    func openVendorUpdater(_ item: UpdateItem) {
        guard let path = item.vendorUpdater?.launchPath ?? item.path else { return }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { Task { @MainActor in self.append("Could not open updater: \(error.localizedDescription)") } }
        }
    }
    func refreshPermissions() {
        guard !isPreview else { return }
        Task {
            let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
            let roots = ["/Applications"] + (FileManager.default.fileExists(atPath: home) ? [home] : [])
                + (UserDefaults.standard.stringArray(forKey: "customRoots") ?? []).map { ($0 as NSString).expandingTildeInPath }
            let login: String
            switch SMAppService.mainApp.status {
            case .enabled: login = "Enabled"
            case .requiresApproval: login = "Requires approval"
            case .notRegistered: login = "Not registered"
            case .notFound: login = "Not found"
            @unknown default: login = "Unknown"
            }
            let probes = PermissionsBackend.Probes(fullDiskAccess: PermissionsBackend.probeFullDiskAccess(),
                                                   notifications: await Notifier.isAuthorized(),
                                                   isAdmin: PermissionsBackend.isAdminUser(),
                                                   destinations: PermissionsBackend.writable(roots), launchAtLogin: login,
                                                   proxyPasswordStored: ProxySettings.load().storedPassword() != nil)
            permissions = PermissionsBackend.checks(probes)
        }
    }
    func checkSelfUpdate() {
        selfUpdateRelease = nil; selfUpdateInstalled = false
        let feed: SelfUpdateFeed
        do { feed = try SelfUpdateFeed.parse(UserDefaults.standard.string(forKey: SelfUpdateFeed.defaultsKey) ?? "") }
        catch { selfUpdateMessage = error.localizedDescription; return }
        guard feed != .disabled else { selfUpdateMessage = "Self-update is disabled. No release feed is configured."; return }
        selfUpdateMessage = "Checking \(feed.description)…"
        Task {
            do {
                selfUpdateRelease = try await SelfUpdate.check(feed, installedVersion: appVersion)
                selfUpdateMessage = selfUpdateRelease.map { "Update Workbench \($0.version) is available." } ?? "Update Workbench is up to date."
            } catch { selfUpdateMessage = error.localizedDescription }
        }
    }
    func installSelfUpdate() {
        guard let release = selfUpdateRelease, !busy else { return }
        busy = true; selfUpdateMessage = "Installing \(release.version)…"
        Task {
            do {
                let message = try await SparkleBackend.install(release: release, target: Bundle.main.bundleURL, replacingRunningSelf: true)
                append(message); selfUpdateMessage = message; selfUpdateInstalled = true
            } catch { selfUpdateMessage = error.localizedDescription; append("Self-update: \(error.localizedDescription)") }
            busy = false
        }
    }
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
    func exportInventory() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "app-inventory.json"
        if panel.runModal() == .OK, let url = panel.url {
            do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(items).write(to: url) }
            catch { append(error.localizedDescription) }
        }
    }
}

/// Entry point. `--render-snapshots <folder>` renders every screen with fake data to PNGs and exits.
@main
enum Entry {
    static func main() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--render-snapshots") {
            let folder = index + 1 < arguments.count ? arguments[index + 1] : FileManager.default.temporaryDirectory.appendingPathComponent("UpdateWorkbenchSnapshots").path
            MainActor.assumeIsolated { SnapshotHarness.run(outputFolder: folder) }
            return
        }
        UpdateWorkbenchApp.main()
    }
}

struct UpdateWorkbenchApp: App {
    @StateObject private var model = WorkbenchModel()
    var body: some Scene {
        WindowGroup("Update Workbench", id: "main") {
            ContentView().environmentObject(model)
                .frame(minWidth: 1040, minHeight: 680)
                .preferredColorScheme(model.appearance.colorScheme)
                .tint(Theme.accent)
                .onAppear { model.applyAppearance() }
        }
        .commands { WorkbenchCommands(model: model) }
        Settings {
            SettingsView().environmentObject(model)
                .preferredColorScheme(model.appearance.colorScheme)
                .tint(Theme.accent)
        }
        MenuBarExtra("Update Workbench", systemImage: "arrow.triangle.2.circlepath") {
            WorkbenchMenu().environmentObject(model)
        }
    }
}

struct WorkbenchCommands: Commands {
    @ObservedObject var model: WorkbenchModel
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Check for Updates") { model.scan() }.keyboardShortcut("r", modifiers: .command).disabled(model.busy)
            Button("Update All…") { model.section = .updates; model.confirmUpdateAll = true }
                .keyboardShortcut("u", modifiers: [.command, .shift]).disabled(model.busy || model.directUpdates.isEmpty)
            Divider()
            Button("Export Inventory…") { model.exportInventory() }.keyboardShortcut("e", modifiers: [.command, .shift])
        }
        CommandMenu("Go") {
            ForEach(Array(SidebarSection.allCases.enumerated()), id: \.element) { index, section in
                Button(section.rawValue) { model.section = section }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Divider()
            Button(model.showConsole ? "Hide Console" : "Show Console") { model.showConsole.toggle() }.keyboardShortcut("l", modifiers: [.command, .option])
        }
        CommandMenu("Homebrew") {
            Button("Find Homebrew Matches") { model.section = .suggestions; model.findHomebrewMatches() }.disabled(model.busy || model.items.isEmpty)
            Button("Refresh Catalog") { model.refreshCatalog() }.disabled(model.busy)
            Button("Diagnose Homebrew") { model.showConsole = true; model.maintain("doctor") }.disabled(model.busy)
        }
    }
}

struct WorkbenchMenu: View {
    @EnvironmentObject var model: WorkbenchModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(HeroSummary.title(updates: model.updates.count, scanned: model.scanned))
        Button("Check for Updates") { model.scan() }.disabled(model.busy)
        Button("Open Update Workbench") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
    }
}
