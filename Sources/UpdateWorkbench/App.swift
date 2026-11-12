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
    @Published var ignored: Set<String> = UpdateRules.load().ignored { didSet { saveRules() } }
    @Published var skipped: [String: String] = UpdateRules.load().skipped { didSet { saveRules() } }
    @Published var holdPrereleases: Bool = UpdateRules.load().holdPrereleases { didSet { saveRules() } }
    @Published var prereleaseRules: [String: PrereleaseRule] = UpdateRules.load().prereleaseRules { didSet { saveRules() } }
    @Published var snoozed: [String: Double] = UserDefaults.standard.dictionary(forKey: "snoozed") as? [String: Double] ?? [:]
    @Published var schedule: CheckSchedule = CheckSchedule.stored() {
        didSet { if !isPreview { UserDefaults.standard.set(schedule.rawValue, forKey: CheckSchedule.defaultsKey); self.scheduleChecks() } }
    }
    /// Not `@Published`: SwiftUI's MenuBarExtra writes its `isInserted` binding back on every scene update.
    /// Publishing those same-value writes re-rendered every scene, which wrote the binding again: an endless
    /// main-thread loop (the 0.4.0 launch hang). Only real changes are published and saved.
    private var storedShowMenuBarIcon: Bool = UserDefaults.standard.object(forKey: "showMenuBarIcon") as? Bool ?? true
    var showMenuBarIcon: Bool {
        get { storedShowMenuBarIcon }
        set {
            guard StateWrites.assignIfChanged(&storedShowMenuBarIcon, newValue, willChange: { objectWillChange.send() }) else { return }
            if !isPreview { UserDefaults.standard.set(newValue, forKey: "showMenuBarIcon") }
        }
    }
    /// Whether the mas command-line tool was found at the last check.
    @Published var masInstalled = AppStoreCLI.locate() != nil
    @Published var confirmInstallMas = false
    @Published var lastScheduledCheck: Date? = UserDefaults.standard.object(forKey: CheckSchedule.lastCheckKey) as? Date
    @Published var history: [HistoryEntry] = []
    @Published var selectedHistory: UUID?
    @Published var approvals: [TrustedSignerApproval] = []
    /// Item whose update confirmation (with release notes) is showing.
    @Published var pendingUpdate: UpdateItem?
    /// Signer change waiting for the user's decision in the approval sheet.
    @Published var signerChange: SignerChange?
    @Published var licensePrompt: LicenseAgreementRequired?
    @Published var notesCache: [String: String] = [:]
    @Published var notesLoading: Set<String> = []
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
    private var signerQueue: [SignerChange] = []
    private var licenseQueue: [LicenseAgreementRequired] = []
    private var acceptedLicenses: Set<String> = []
    let historyStore: HistoryStore?
    let signerStore: TrustedSignerStore?
    init(preview: Bool = false) {
        isPreview = preview
        historyStore = preview ? nil : .standard
        signerStore = preview ? nil : .standard
        if !preview {
            history = historyStore?.load() ?? []
            approvals = signerStore?.load() ?? []
            Notifier.configure(); scheduleChecks()
        }
    }
    var rules: UpdateRules { UpdateRules(ignored: ignored, skipped: skipped, holdPrereleases: holdPrereleases, prereleaseRules: prereleaseRules) }
    private func saveRules() { if !isPreview { rules.save() } }
    func decision(_ item: UpdateItem) -> UpdateRules.Decision { rules.decision(id: item.id, latestVersion: item.latestVersion, isOutdated: item.isOutdated) }
    func isSnoozed(_ item: UpdateItem) -> Bool { (snoozed[item.id] ?? 0) > Date().timeIntervalSince1970 }
    func applyAppearance() { NSApp?.appearance = appearance.nsAppearance }
    var scanned: Bool { lastCheck != nil }
    var directUpdates: [UpdateItem] { updates.filter(\.canUpdateDirectly) }
    func status(_ item: UpdateItem) -> ItemStatus {
        ItemStatus.classify(item, ignored: ignored.contains(item.id), skippedVersion: skipped[item.id], snoozedUntil: snoozed[item.id],
                            failure: failures[item.id], heldPrerelease: decision(item) == .heldPrerelease)
    }
    func count(_ section: SidebarSection) -> Int {
        switch section {
        case .updates: updates.count
        case .suggestions: suggestions.count
        case .ignored: ignoredItems.count
        case .history: history.filter { $0.result == .failed || $0.result == .restoreFailed }.isEmpty ? 0 : history.filter { $0.result == .failed || $0.result == .restoreFailed }.count
        case .packages: items.filter { $0.provider == .homebrewFormula }.count
        case .applications: items.filter { $0.provider != .homebrewFormula }.count
        case .permissions: permissions.filter { $0.state == .denied }.count
        }
    }
    var ignoredItems: [UpdateItem] { items.filter { decision($0) != .show || isSnoozed($0) } }
    var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? AppIdentity.version }
    var suggestions: [UpdateItem] {
        items.filter { item in
            (item.provider == .manual || item.provider == .vendor || (item.provider == .electron && !item.canUpdateDirectly))
                && (!(item.repositorySuggestions ?? []).isEmpty || !(item.caskSuggestions ?? []).isEmpty)
        }
    }
    var updates: [UpdateItem] {
        let rules = self.rules, now = Date().timeIntervalSince1970
        return items.filter { $0.isOutdated && rules.decision(id: $0.id, latestVersion: $0.latestVersion, isOutdated: true) == .show && (snoozed[$0.id] ?? 0) <= now }
    }
    var visible: [UpdateItem] {
        let base: [UpdateItem]
        switch section {
        case .updates: base = updates
        case .suggestions: base = suggestions
        case .ignored: base = ignoredItems
        case .packages: base = items.filter { $0.provider == .homebrewFormula }
        case .applications: base = items.filter { $0.provider != .homebrewFormula }
        case .permissions, .history: base = []
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
        let rules = self.rules
        Task {
            var scanned = await engine.scan(rules: rules)
            for index in scanned.indices { if let cached = caskSuggestionCache[scanned[index].id] { scanned[index].caskSuggestions = cached } }
            items = scanned; lastCheck = Date()
            for line in await engine.lastDiagnostics() { append(line) }
            append("Found \(items.count) apps and packages; \(updates.count) available updates.")
            masInstalled = AppStoreCLI.locate() != nil
            busy = false; operation = "Check complete"; failures = failures.filter { id, _ in items.contains { $0.id == id && $0.isOutdated } }
            lastScheduledCheck = Date(); UserDefaults.standard.set(lastScheduledCheck, forKey: CheckSchedule.lastCheckKey)
            updateBadge()
            notifyAvailableUpdates()
        }
    }
    func updateBadge() {
        guard !isPreview else { return }
        NSApp?.dockTile.badgeLabel = updates.isEmpty ? nil : "\(updates.count)"
    }
    func update(_ targets: [UpdateItem]) {
        guard !busy, !isPreview else { return }; busy = true
        Task {
            let actionable = targets.filter(\.canUpdateDirectly)
            var succeeded: [String] = [], failed: [String] = []
            for (index, item) in actionable.enumerated() {
                operation = "Updating \(index + 1) of \(actionable.count): \(item.name)"
                append("Updating \(item.name)…")
                var options = InstallOptions()
                options.trustedSigners = signerStore
                options.acceptLicense = acceptedLicenses.contains(licenseKey(item))
                do {
                    let outcome = try await engine.update(item, options: options)
                    append(outcome.message); succeeded.append(item.name); failures.removeValue(forKey: item.id)
                    record(item, result: .installed, message: outcome.message, toVersion: outcome.installedVersion)
                    markInstalled(item, version: outcome.installedVersion)
                } catch let change as SignerChange {
                    append("\(item.name): \(change.localizedDescription)"); failed.append(item.name)
                    failures[item.id] = "Signed by a new developer team. Review it to continue."
                    record(item, result: .failed, message: change.localizedDescription)
                    signerQueue.append(change)
                } catch let license as LicenseAgreementRequired {
                    append("\(item.name): \(license.localizedDescription)")
                    failures[item.id] = "Waiting for the disk image's license agreement."
                    licenseQueue.append(license); failed.append(item.name)
                } catch {
                    append("\(item.name): \(error.localizedDescription)"); failed.append(item.name); failures[item.id] = error.localizedDescription
                    record(item, result: .failed, message: error.localizedDescription)
                }
            }
            if notificationsEnabled, let message = UpdateNotificationPolicy.resultMessage(succeeded: succeeded, failed: failed) {
                Notifier.post(title: message.title, body: message.body, identifier: "result-\(UUID().uuidString)")
            }
            busy = false; operation = failed.isEmpty ? "Updates finished" : "\(failed.count) update(s) need attention. See Console."
            if !failed.isEmpty && signerQueue.isEmpty && licenseQueue.isEmpty { showConsole = true }
            presentNextPrompt()
            scan()
        }
    }
    private func licenseKey(_ item: UpdateItem) -> String { "\(item.id)|\(item.latestVersion ?? "")" }
    private func presentNextPrompt() {
        guard signerChange == nil, licensePrompt == nil else { return }
        if !licenseQueue.isEmpty { licensePrompt = licenseQueue.removeFirst() }
        else if !signerQueue.isEmpty { signerChange = signerQueue.removeFirst() }
    }
    /// Removes a just-installed update from the list right away instead of waiting for the next check.
    private func markInstalled(_ item: UpdateItem, version: String?) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].installedVersion = version ?? item.latestVersion ?? item.installedVersion
        items[index].isOutdated = false
        updateBadge()
    }
    private func record(_ item: UpdateItem, result: HistoryEntry.Result, message: String, toVersion: String? = nil) {
        let entry = HistoryEntry(date: Date(), itemID: item.id, appName: item.name, bundleID: item.bundleID, appPath: item.path,
                                 fromVersion: item.installedVersion, toVersion: toVersion ?? item.latestVersion ?? "?",
                                 source: item.provider.rawValue, result: result, message: String(message.prefix(4000)))
        history.insert(entry, at: 0)
        if let historyStore { do { try historyStore.save(history) } catch { append("History: \(error.localizedDescription)") } }
    }
    /// The user approved the new signer in the confirmation sheet: store it for this app and retry the update.
    func approveSigner(_ change: SignerChange) {
        signerChange = nil
        guard let signerStore else { presentNextPrompt(); return }
        do {
            try signerStore.approve(change)
            approvals = signerStore.load()
            append("Approved team \(change.candidate.teamID) (\(change.candidate.signerName)) for \(change.appName). Revoke it in Settings → Trust.")
            if let item = items.first(where: { $0.bundleID == change.bundleID && $0.canUpdateDirectly }) { update([item]) }
        } catch { append("Could not save the approval: \(error.localizedDescription)") }
        presentNextPrompt()
    }
    func declineSigner(_ change: SignerChange) {
        signerChange = nil
        append("Kept \(change.appName) as installed. The update signed by \(change.candidate.signerName) (\(change.candidate.teamID)) was not approved.")
        presentNextPrompt()
    }
    func revokeApproval(_ approval: TrustedSignerApproval) {
        guard let signerStore else { approvals.removeAll { $0.id == approval.id }; return }
        do { try signerStore.revoke(approval.id); approvals = signerStore.load(); append("Revoked team \(approval.teamID) for \(approval.appName).") }
        catch { append(error.localizedDescription) }
    }
    func acceptLicense(_ prompt: LicenseAgreementRequired) {
        licensePrompt = nil
        if let item = items.first(where: { $0.name == prompt.appName && $0.latestVersion == prompt.version }) {
            acceptedLicenses.insert(licenseKey(item)); failures.removeValue(forKey: item.id)
            append("Accepted the license agreement of \(prompt.appName) \(prompt.version).")
            update([item])
        }
        presentNextPrompt()
    }
    func declineLicense(_ prompt: LicenseAgreementRequired) {
        licensePrompt = nil
        append("Declined the license agreement of \(prompt.appName) \(prompt.version); nothing was installed.")
        presentNextPrompt()
    }
    /// Installs mas with Homebrew after the user confirmed `brew install mas`.
    func installMas() {
        guard !busy, !isPreview else { return }; busy = true; operation = "Installing mas…"
        append("Installing mas with Homebrew (brew install mas)…")
        Task {
            do { append(try await engine.installMas()) } catch { append("mas: \(error.localizedDescription)"); showConsole = true }
            masInstalled = AppStoreCLI.locate() != nil
            busy = false; operation = masInstalled ? "mas installed" : "mas wasn't installed"
            if masInstalled { scan() }
        }
    }
    /// Opens Terminal with `mas update <id>`, where macOS can ask for the administrator password mas needs.
    func finishInTerminal(_ item: UpdateItem) {
        guard !isPreview, let mas = AppStoreCLI.locate(), let id = item.token,
              let script = AppStoreCLI.terminalScript(mas: mas, adamID: id, name: item.name) else {
            append("\(item.name): mas or the App Store ID is unavailable."); return
        }
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateWorkbench-mas-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = folder.appendingPathComponent("mas-update-\(id).command")
            try Data(script.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
            append("Opened Terminal to run mas update \(id) for \(item.name). Check for updates again when it finishes.")
        } catch { append("\(item.name): \(error.localizedDescription)") }
    }
    func loadNotes(_ item: UpdateItem) {
        guard !isPreview, item.releaseNotes == nil, let url = item.releaseNotesLink, notesCache[url.absoluteString] == nil,
              !notesLoading.contains(url.absoluteString) else { return }
        notesLoading.insert(url.absoluteString)
        Task {
            do { notesCache[url.absoluteString] = try await ReleaseNotes.fetch(url) }
            catch { notesCache[url.absoluteString] = "Release notes couldn't be loaded: \(error.localizedDescription)" }
            notesLoading.remove(url.absoluteString)
        }
    }
    func notes(for item: UpdateItem) -> String? {
        item.releaseNotes ?? item.releaseNotesLink.flatMap { notesCache[$0.absoluteString] }
    }
    func setPrereleaseRule(_ rule: PrereleaseRule, for id: String) {
        if rule == .followGlobal { prereleaseRules.removeValue(forKey: id) } else { prereleaseRules[id] = rule }
    }
    func removeRules(for id: String) {
        ignored.remove(id); skipped.removeValue(forKey: id); prereleaseRules.removeValue(forKey: id)
        snoozed.removeValue(forKey: id); UserDefaults.standard.set(snoozed, forKey: "snoozed")
    }
    func ruleName(_ id: String) -> String { items.first { $0.id == id }?.name ?? UpdateRules.displayName(for: id) }
    func ignore(_ item: UpdateItem) {
        if ignored.contains(item.id) { ignored.remove(item.id) } else { ignored.insert(item.id) }
    }
    func skip(_ item: UpdateItem) {
        if skipped[item.id] == item.latestVersion { skipped.removeValue(forKey: item.id) }
        else { skipped[item.id] = item.latestVersion }
    }
    func snooze(_ item: UpdateItem, days: Int) {
        if days == 0 { snoozed.removeValue(forKey: item.id) }
        else { snoozed[item.id] = Date().addingTimeInterval(Double(days) * 86400).timeIntervalSince1970 }
        UserDefaults.standard.set(snoozed, forKey: "snoozed")
    }
    /// Background checks: a 30-minute timer asks whether a daily or weekly check is due. Checks never install anything.
    func scheduleChecks() {
        timer?.invalidate(); timer = nil
        guard !isPreview, schedule != .off else { return }
        let timer = Timer(timeInterval: 1800, repeats: true) { [weak self] _ in Task { @MainActor in self?.runScheduledCheckIfDue() } }
        timer.tolerance = 300
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Task { try? await Task.sleep(for: .seconds(8)); runScheduledCheckIfDue() }
    }
    func runScheduledCheckIfDue() {
        guard !busy, schedule.isDue(lastCheck: lastScheduledCheck) else { return }
        append("Scheduled \(schedule.rawValue.lowercased()) check (looks for updates only; nothing installs automatically).")
        scan()
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
                var options = InstallOptions(); options.trustedSigners = nil
                let message = try await SparkleBackend.install(release: release, target: Bundle.main.bundleURL, replacingRunningSelf: true, options: options).message
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
        MenuBarExtra(isInserted: Binding(get: { model.showMenuBarIcon }, set: { model.showMenuBarIcon = $0 })) {
            MenuBarPanel().environmentObject(model)
                .preferredColorScheme(model.appearance.colorScheme)
                .tint(Theme.accent)
        } label: {
            MenuBarLabel(count: model.updates.count)
        }
        .menuBarExtraStyle(.window)
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
            Divider()
            Button(model.masInstalled ? "mas Is Installed" : "Install mas…") { model.confirmInstallMas = true }.disabled(model.busy || model.masInstalled)
        }
    }
}
