import SwiftUI
import AppKit

struct ItemDetail: View {
    let item: UpdateItem
    @EnvironmentObject var model: WorkbenchModel
    @State private var feedOverride = ""
    @State private var adoptionToken = ""
    @State private var confirmAdoption = false
    @State private var githubRepository = ""
    @State private var securityReport: SecurityReport?
    @State private var inspectingSecurity = false
    @State private var pendingRepository = ""
    @State private var confirmRepository = false
    @State private var pendingAction: HomebrewAction?
    @State private var confirmAction = false
    @State private var confirmTrash = false
    @State private var showAdvanced = false

    var body: some View {
        let status = model.status(item)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                header(status)
                versionCard(status)
                if item.isOutdated { whatsNewCard }
                let hasSuggestions = !(item.repositorySuggestions ?? []).isEmpty || !(item.caskSuggestions ?? []).isEmpty
                if hasSuggestions && !item.canUpdateDirectly { suggestionsCard }
                aboutCard
                if let vendor = item.vendorUpdater { vendorCard(vendor) }
                if hasSuggestions && item.canUpdateDirectly { suggestionsCard }
                detailsCard
                if let path = item.path { securityCard(path) }
                if [.manual, .sparkle, .github, .electron, .vendor].contains(item.provider) { advancedCard }
                manageCard
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onAppear {
            githubRepository = item.githubRepository ?? ""
            feedOverride = item.feedURL?.absoluteString ?? ""
        }
        .confirmationDialog("Adopt \(item.name) with Homebrew?", isPresented: $confirmAdoption) {
            Button("Adopt") { model.adopt(adoptionToken) }
        } message: { Text("Runs brew install --cask --adopt \(adoptionToken). Homebrew will manage future updates of this app; it may download the cask and fails if the installed app does not match. Review the token before continuing.") }
        .confirmationDialog("Use GitHub Releases from \(pendingRepository)?", isPresented: $confirmRepository) {
            Button("Use Repository") { model.useRepository(pendingRepository, for: item) }
        } message: { Text("Update Workbench will check this public repository's latest stable release for \(item.name). Direct installation still requires a matching bundle ID and signing team.") }
        .confirmationDialog("\(pendingAction?.rawValue ?? "Change") \(item.name)?", isPresented: $confirmAction) {
            if let action = pendingAction {
                Button(action.rawValue, role: action == .uninstall ? .destructive : nil) { model.manage(action, item) }
            }
        } message: {
            Text("\(pendingAction?.confirmationMessage ?? "") Command: brew \(pendingAction.flatMap { try? HomebrewAction.arguments($0, for: item).joined(separator: " ") } ?? "")")
        }
        .confirmationDialog("Move \(item.name) to the Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) { model.moveToTrash(item) }
        } message: { Text("The app bundle is moved to the Trash, not deleted, and can be restored from there. Its settings and data are left in place. Quit the app first.") }
        .onAppear { model.loadNotes(item) }
    }

    private var whatsNewCard: some View {
        Card(title: "What's new in \(item.latestVersion ?? "the update")", symbol: "sparkles", tint: Theme.pink) {
            WhatsNewContent(item: item)
                .frame(maxHeight: 260, alignment: .top)
                .clipped()
            if model.notes(for: item).map({ $0.count > 600 }) == true {
                Button { model.pendingUpdate = item } label: { Label("Read all and update…", systemImage: "text.alignleft") }
                    .buttonStyle(.link).font(.callout).disabled(!item.canUpdateDirectly)
            }
        }
    }

    // MARK: Sections

    private func header(_ status: ItemStatus) -> some View {
        HStack(alignment: .center, spacing: 16) {
            AppIconView(item: item, size: 68)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.name).font(.title.weight(.bold)).textSelection(.enabled).lineLimit(2)
                HStack(spacing: 6) { SourceBadge(provider: item.provider); StatusBadge(status: status) }
                if let id = item.bundleID { Text(id).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle) }
            }
            Spacer(minLength: 0)
        }
    }

    private func versionCard(_ status: ItemStatus) -> some View {
        Card {
            HStack(spacing: 14) {
                versionBlock("Installed", item.installedVersion, color: .primary)
                Image(systemName: "arrow.right").font(.title3.weight(.semibold))
                    .foregroundStyle(item.isOutdated ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(.tertiary))
                    .accessibilityHidden(true)
                versionBlock("Available", item.latestVersion ?? "Unknown", color: item.isOutdated ? Theme.accent : .secondary)
                Spacer(minLength: 0)
            }
            if let failure = model.failures[item.id] {
                Label { Text("Last update failed: \(failure)").fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                    .font(.callout).foregroundStyle(.red)
            }
            HStack(spacing: 8) {
                primaryAction
                if let path = item.path {
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
                        .help("Open \(item.name)")
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: { Label("Show in Finder", systemImage: "folder") }
                        .help("Reveal the app in Finder")
                }
                Spacer(minLength: 0)
                laterMenu
            }
            .controlSize(.large)
            if let until = model.snoozed[item.id], until > Date().timeIntervalSince1970 {
                Label("Snoozed until \(Date(timeIntervalSince1970: until).formatted(date: .abbreviated, time: .shortened))", systemImage: "moon.zzz.fill").font(.caption).foregroundStyle(.purple)
            }
            if status == .heldBack {
                HStack(spacing: 8) {
                    Label("\(item.latestVersion ?? "This version") is a pre-release. Your rules hold back betas.", systemImage: "flask.fill").font(.callout).foregroundStyle(.orange)
                    Spacer(minLength: 0)
                    Button("Allow Betas for This App") { model.setPrereleaseRule(.allow, for: item.id) }.controlSize(.small)
                }
            }
            if let approval = model.approvals.first(where: { $0.bundleID == item.bundleID }) {
                Label("You approved team \(approval.teamID) (\(approval.signerName)) for this app on \(approval.approvedAt.formatted(date: .abbreviated, time: .omitted)).", systemImage: "person.badge.shield.checkmark.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            if item.provider == .appStore { appStoreHelp }
            if item.isOutdated && !item.canUpdateDirectly {
                Text(item.vendorUpdater != nil ? "This app updates through its own updater. Open it to install the new version." : "No verified direct update route is available for this item, so it can't be installed here.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// mas status and the next step for App Store apps.
    @ViewBuilder private var appStoreHelp: some View {
        if !model.masInstalled {
            VStack(alignment: .leading, spacing: 6) {
                Label("App Store apps are checked with mas, the Mac App Store command-line tool, which isn't installed.", systemImage: "bag.badge.questionmark")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button { model.confirmInstallMas = true } label: { Label("Install mas…", systemImage: "arrow.down.app") }.disabled(model.busy)
                    Button { NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!) } label: { Label("Open App Store Updates", systemImage: "bag") }
                }
            }
        } else if let failure = model.failures[item.id], AppStoreCLI.classify(failure) == .needsAdministrator {
            VStack(alignment: .leading, spacing: 6) {
                Label("mas needs your administrator password to install App Store updates, which it can only ask for in Terminal.", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button { model.finishInTerminal(item) } label: { Label("Finish in Terminal", systemImage: "terminal") }
                        .help("Opens Terminal and runs mas update for this app; enter your password there")
                    Button { NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!) } label: { Label("Open App Store Updates", systemImage: "bag") }
                }
            }
        } else if item.isOutdated {
            Label("Updated with mas update\(item.token.map { " " + $0 } ?? ""). It may ask for your administrator password; if so, finish in Terminal or the App Store.", systemImage: "bag")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var primaryAction: some View {
        if item.canUpdateDirectly && item.isOutdated {
            Button { model.pendingUpdate = item } label: { Label("Update to \(item.latestVersion ?? "Latest")", systemImage: "arrow.down.circle.fill") }
                .buttonStyle(.borderedProminent).disabled(model.busy)
                .help("Download and install the new version after confirmation")
        } else if let vendor = item.vendorUpdater {
            Button { model.openVendorUpdater(item) } label: { Label(vendor.launchPath != nil ? "Open \(vendor.name)" : "Open App to Update", systemImage: "arrow.up.forward.app.fill") }
                .buttonStyle(.borderedProminent)
        } else if item.provider == .appStore {
            Button { NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!) } label: { Label("Open App Store Updates", systemImage: "bag.fill") }
                .buttonStyle(.borderedProminent)
        } else if model.status(item) == .upToDate {
            Label("Up to date", systemImage: "checkmark.seal.fill").font(.callout.weight(.semibold)).foregroundStyle(.green)
        }
    }

    private var laterMenu: some View {
        Menu {
            if item.latestVersion != nil {
                Button(model.skipped[item.id] == item.latestVersion ? "Stop Skipping This Version" : "Skip This Version") { model.skip(item) }
            }
            Button("Snooze for 2 Days") { model.snooze(item, days: 2) }
            Button("Snooze for 4 Days") { model.snooze(item, days: 4) }
            if model.snoozed[item.id] != nil { Button("Clear Snooze") { model.snooze(item, days: 0) } }
            Divider()
            Picker("Pre-releases and Betas", selection: Binding(get: { model.prereleaseRules[item.id] ?? .followGlobal }, set: { model.setPrereleaseRule($0, for: item.id) })) {
                Text("Use Global Setting (\(model.holdPrereleases ? "Hold Back" : "Allow"))").tag(PrereleaseRule.followGlobal)
                Text("Always Hold Back").tag(PrereleaseRule.hold)
                Text("Allow for This App").tag(PrereleaseRule.allow)
            }
            Divider()
            Button(model.ignored.contains(item.id) ? "Stop Ignoring This App" : "Ignore This App") { model.ignore(item) }
        } label: { Label("Later", systemImage: "clock") }
            .fixedSize()
            .help("Skip this version, snooze it or ignore the app")
    }

    private func versionBlock(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .monospaced).weight(.semibold)).foregroundStyle(color)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private var aboutCard: some View {
        Card(title: "Update source", symbol: item.provider.symbol, tint: item.provider.tint) {
            Text(item.provider.explanation).font(.callout)
            if !item.detail.isEmpty { Text(item.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if item.isPinned == true { Label("Pinned in Homebrew; excluded from upgrades until unpinned.", systemImage: "pin.fill").font(.callout).foregroundStyle(.orange) }
            if let repository = item.githubRepository { InfoRow(label: "GitHub", value: repository) }
            if let electron = item.electronUpdate { InfoRow(label: "Electron feed", value: electron.summary) }
            let links = linkList
            if !links.isEmpty {
                HStack(spacing: 14) { ForEach(links, id: \.0) { link in Link(destination: link.1) { Label(link.0, systemImage: "arrow.up.right.square") } } }
                    .font(.callout)
            }
        }
    }

    private var linkList: [(String, URL)] {
        var links: [(String, URL)] = []
        if let notes = item.sparkleRelease?.releaseNotesURL { links.append(("Release notes", notes)) }
        if let release = item.githubRelease { links.append(("GitHub release", release.releasePageURL)) }
        if let homepage = item.homepage { links.append(("Website", homepage)) }
        return links
    }

    private func vendorCard(_ vendor: VendorUpdater) -> some View {
        Card(title: "Vendor updater", symbol: "building.2.fill", tint: UpdateProvider.vendor.tint) {
            Text(vendor.name).font(.callout.weight(.semibold))
            Text(vendor.instructions).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Use the Open button above. Update Workbench only opens the vendor's own updater; it does not drive private vendor update protocols.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var suggestionsCard: some View {
        Card(title: "Suggestions", symbol: "lightbulb.fill", tint: SidebarSection.suggestions.tint) {
            ForEach(item.repositorySuggestions ?? [], id: \.self) { suggestion in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: UpdateProvider.github.symbol).foregroundStyle(UpdateProvider.github.tint).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(suggestion.repository).font(.callout.weight(.semibold)).textSelection(.enabled)
                        Text(suggestion.evidence).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if item.githubRepository != suggestion.repository {
                        Button("Use…") { pendingRepository = suggestion.repository; confirmRepository = true }.disabled(model.busy)
                            .help("Check this repository's releases for updates (asks first)")
                    } else { Pill(text: "In use", symbol: "checkmark", tint: .green) }
                }
            }
            ForEach(item.caskSuggestions ?? [], id: \.self) { suggestion in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: UpdateProvider.homebrewCask.symbol).foregroundStyle(UpdateProvider.homebrewCask.tint).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Homebrew cask \(suggestion.token)\(suggestion.version.map { " \($0)" } ?? "")").font(.callout.weight(.semibold)).textSelection(.enabled)
                            Pill(text: "\(suggestion.confidence.rawValue) confidence", symbol: suggestion.confidence == .high ? "checkmark.seal.fill" : "questionmark.diamond.fill",
                                 tint: suggestion.confidence == .high ? .green : .orange)
                        }
                        Text(suggestion.evidence).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Adopt…") { adoptionToken = suggestion.token; confirmAdoption = true }.disabled(model.busy)
                        .help("Let Homebrew manage this app (shows the exact command first)")
                }
            }
            Text("Suggestions come from the app's own metadata and public Homebrew data. Nothing changes until you confirm.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var detailsCard: some View {
        Card(title: "Details", symbol: "info.circle.fill", tint: Theme.indigo) {
            if let id = item.bundleID { InfoRow(label: "Bundle ID", value: id, monospaced: true) }
            if let path = item.path { InfoRow(label: "Location", value: abbreviatedPath(path)) }
            if let token = item.token { InfoRow(label: "Homebrew", value: token, monospaced: true) }
            if let feed = item.feedURL { InfoRow(label: "Feed", value: feed.absoluteString) }
            InfoRow(label: "Source", value: item.provider.rawValue)
        }
    }

    private func securityCard(_ path: String) -> some View {
        Card(title: "App security", symbol: "checkmark.shield.fill", tint: Theme.mint) {
            Text("Checks the installed copy's code signature and Gatekeeper assessment. Read-only.").font(.caption).foregroundStyle(.secondary)
            Button {
                inspectingSecurity = true
                Task { securityReport = await SecurityBackend.inspect(path: path); inspectingSecurity = false }
            } label: { Label(inspectingSecurity ? "Inspecting…" : "Inspect Signature and Gatekeeper", systemImage: "magnifyingglass") }
                .disabled(inspectingSecurity)
            if let securityReport {
                Text(securityReport.summary).font(.callout.weight(.semibold))
                Text(securityReport.details).font(.system(.caption, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var advancedCard: some View {
        Card {
            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Sparkle appcast").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    HStack {
                        TextField("https://example.com/appcast.xml", text: $feedOverride).textFieldStyle(.roundedBorder)
                        Button("Save and Check") {
                            guard let url = URL(string: feedOverride), url.scheme == "https", url.host != nil else { model.append("Enter a valid HTTPS appcast URL."); return }
                            var feeds = UserDefaults.standard.dictionary(forKey: "feedOverrides") as? [String: String] ?? [:]
                            feeds[item.bundleID ?? item.id] = url.absoluteString
                            UserDefaults.standard.set(feeds, forKey: "feedOverrides")
                            var repositories = UserDefaults.standard.dictionary(forKey: "githubOverrides") as? [String: String] ?? [:]
                            repositories.removeValue(forKey: item.bundleID ?? item.id); repositories.removeValue(forKey: item.id)
                            UserDefaults.standard.set(repositories, forKey: "githubOverrides"); model.scan()
                        }.disabled(model.busy)
                    }
                    Text("GitHub repository").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    HStack {
                        TextField("owner/repository", text: $githubRepository).textFieldStyle(.roundedBorder)
                        Button("Use Releases") {
                            guard GitHubBackend.validRepository(githubRepository) else { model.append("Enter a GitHub repository as owner/repository."); return }
                            var repositories = UserDefaults.standard.dictionary(forKey: "githubOverrides") as? [String: String] ?? [:]
                            repositories[item.bundleID ?? item.id] = githubRepository
                            UserDefaults.standard.set(repositories, forKey: "githubOverrides"); model.scan()
                        }.disabled(model.busy)
                    }
                    Text("GitHub repositories must be chosen explicitly. Ambiguous or unsupported release downloads open the release page for manual installation.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("Homebrew cask").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    HStack {
                        TextField("cask token, for example firefox", text: $adoptionToken).textFieldStyle(.roundedBorder)
                        Button("Adopt…") { confirmAdoption = true }.disabled(model.busy || adoptionToken.isEmpty)
                    }
                    Text("Adoption asks Homebrew to manage this app. The installed app must match the cask; Homebrew validates adoption.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Reset Custom Sources") {
                        for key in ["feedOverrides", "githubOverrides"] {
                            var overrides = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
                            overrides.removeValue(forKey: item.bundleID ?? item.id)
                            overrides.removeValue(forKey: item.id)
                            UserDefaults.standard.set(overrides, forKey: key)
                        }
                        model.scan()
                    }.disabled(model.busy)
                }
                .padding(.top, 8)
            } label: {
                Label { Text("Custom update source").font(.headline) } icon: { Image(systemName: "slider.horizontal.3").foregroundStyle(Theme.violet) }
            }
        }
    }

    @ViewBuilder private var manageCard: some View {
        let homebrew = (item.provider == .homebrewCask || item.provider == .homebrewFormula) && item.token != nil
        let trashable = !homebrew && item.path.map { !$0.hasPrefix("/System/") } == true
        if homebrew || trashable {
            Card(title: "Manage", symbol: "wrench.and.screwdriver.fill", tint: .red) {
                HStack(spacing: 8) {
                    if homebrew {
                        Button { pendingAction = .reinstall; confirmAction = true } label: { Label("Repair…", systemImage: "arrow.triangle.2.circlepath") }
                            .help("Download and reinstall to repair a damaged copy (asks first)")
                        if item.provider == .homebrewFormula && item.isPinned == true {
                            Button { pendingAction = .unpin; confirmAction = true } label: { Label("Unpin…", systemImage: "pin.slash") }
                        }
                        Button(role: .destructive) { pendingAction = .uninstall; confirmAction = true } label: { Label("Uninstall…", systemImage: "trash").foregroundStyle(.red) }
                            .tint(.red).help("Remove with Homebrew; user data is kept (asks first)")
                    } else {
                        Button(role: .destructive) { confirmTrash = true } label: { Label("Move to Trash…", systemImage: "trash").foregroundStyle(.red) }
                            .tint(.red).help("Move the app bundle to the Trash; it can be restored (asks first)")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(model.busy)
                Text("Every action here asks for confirmation and shows exactly what will happen.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
