import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var model: WorkbenchModel
    @State private var maintenanceConfirmation = false
    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } content: {
            Group {
                if model.section == .permissions { PermissionsView() }
                else if model.section == .history { HistoryListColumn() }
                else { ItemListColumn() }
            }
            .navigationTitle(model.section.rawValue)
            .navigationSplitViewColumnWidth(min: 380, ideal: 460, max: 640)
        } detail: {
            if model.section == .history {
                if let entry = model.history.first(where: { $0.id == model.selectedHistory }) {
                    HistoryDetail(entry: entry).id(entry.id)
                } else {
                    ContentUnavailableView {
                        Label("Select an update", systemImage: "clock.arrow.circlepath")
                    } description: { Text("Pick an entry to see what changed and how it went.") }
                }
            } else if model.section != .permissions, let item = model.chosen {
                ItemDetail(item: item).id(item.id)
            } else if model.section == .permissions {
                PermissionsHelpView()
            } else {
                ContentUnavailableView {
                    Label("Select an app", systemImage: "cursorarrow.click.2")
                } description: {
                    Text("Pick an item in the list to see its versions, where updates come from and what you can do with it.")
                }
            }
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: "Search apps and packages")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.scan() } label: { Label("Check for Updates", systemImage: "arrow.clockwise") }
                    .help("Check for updates (⌘R)")
                    .disabled(model.busy)
                Button { model.section = .updates; model.confirmUpdateAll = true } label: { Label("Update All", systemImage: "arrow.down.circle") }
                    .help("Install every update that can be installed here (⇧⌘U)")
                    .disabled(model.busy || model.directUpdates.isEmpty)
                Menu {
                    Button("Find Homebrew Matches") { model.section = .suggestions; model.findHomebrewMatches() }.disabled(model.items.isEmpty)
                    Button("Refresh Homebrew Catalog") { model.refreshCatalog() }
                    Button("Diagnose Homebrew") { model.showConsole = true; model.maintain("doctor") }
                    Divider()
                    Button("Clean Old Downloads…") { maintenanceConfirmation = true }
                } label: { Label("Homebrew", systemImage: "mug") }
                    .help("Homebrew tools")
                    .disabled(model.busy)
                Button { model.showConsole.toggle() } label: { Label("Console", systemImage: model.showConsole ? "terminal.fill" : "terminal") }
                    .help(model.showConsole ? "Hide the activity console (⌥⌘L)" : "Show the activity console (⌥⌘L)")
                Button { model.exportInventory() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .help("Export the app inventory as JSON (⇧⌘E)")
            }
        }
        .confirmationDialog("Clean Homebrew caches and old versions?", isPresented: $maintenanceConfirmation) {
            Button("Run Cleanup") { model.showConsole = true; model.maintain("cleanup") }
        } message: { Text("Runs brew cleanup. Installed apps and packages are not removed.") }
        .sheet(item: $model.pendingUpdate) { item in UpdateConfirmSheet(item: item).environmentObject(model) }
        .sheet(item: $model.signerChange) { change in SignerApprovalSheet(change: change).environmentObject(model) }
        .sheet(item: $model.licensePrompt) { prompt in LicenseSheet(prompt: prompt).environmentObject(model) }
        .confirmationDialog("Install mas with Homebrew?", isPresented: $model.confirmInstallMas) {
            Button("Install mas") { model.showConsole = true; model.installMas() }
        } message: { Text("Runs brew install mas. mas is the open-source Mac App Store command-line tool; Update Workbench uses it to check App Store apps (mas outdated) and, when you choose Update, to install them (mas update). You stay signed in to the App Store app as usual.") }
        .confirmationDialog("Update \(model.directUpdates.count) apps and packages?", isPresented: $model.confirmUpdateAll) {
            Button("Update All") { model.update(model.updates) }
        } message: { Text("Downloads and installations run directly. Close apps before updating them. Items requiring administrator access may fail and report the reason in Console. Apps that update through their own updater are not included.") }
    }
}

struct SidebarView: View {
    @EnvironmentObject var model: WorkbenchModel
    var body: some View {
        List(selection: $model.section) {
            Section("Library") {
                ForEach([SidebarSection.updates, .applications, .packages, .suggestions, .ignored, .history]) { row($0) }
            }
            Section("Mac") { row(.permissions) }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) { AppBadgeHeader().padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 2) }
        .safeAreaInset(edge: .bottom) { StatusFooter().padding(10) }
    }
    @ViewBuilder private func row(_ section: SidebarSection) -> some View {
        let count = model.count(section)
        Label { Text(section.rawValue) } icon: { Image(systemName: section.symbol).foregroundStyle(section.tint) }
            .badge([.updates, .suggestions, .ignored, .permissions, .history].contains(section) ? count : 0)
            .help(section.subtitle)
            .tag(section)
            .accessibilityLabel(count > 0 ? "\(section.rawValue), \(count)" : section.rawValue)
    }
}

/// App icon, name and version at the top of the sidebar.
struct AppBadgeHeader: View {
    @EnvironmentObject var model: WorkbenchModel
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: Bundle.main.image(forResource: "AppIcon") ?? NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 34, height: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Update Workbench").font(.headline).lineLimit(1)
                Text("Version \(model.appVersion)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct StatusFooter: View {
    @EnvironmentObject var model: WorkbenchModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if model.busy { ProgressView().controlSize(.small) }
                else if !model.scanned { Image(systemName: "clock").foregroundStyle(.secondary) }
                else { Image(systemName: model.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(model.failures.isEmpty ? .green : .orange) }
                Text(model.busy ? model.operation : (model.scanned ? "Last check \(model.lastCheck!.formatted(.relative(presentation: .named)))" : "Not checked yet"))
                    .font(.caption.weight(.medium)).lineLimit(2)
            }
            Text("Nothing installs until you choose Update.").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.5)))
        .accessibilityElement(children: .combine)
    }
}

struct ItemListColumn: View {
    @EnvironmentObject var model: WorkbenchModel
    var body: some View {
        VStack(spacing: 0) {
            Group {
                if model.section == .updates { UpdatesHero() } else { SectionHeader(section: model.section) }
            }
            .padding([.horizontal, .top], 14)
            if !model.items.isEmpty {
                FilterBar().padding(.horizontal, 14).padding(.vertical, 10)
                Divider()
            } else { Spacer().frame(height: 10) }
            if model.visible.isEmpty { EmptyStateView().frame(maxHeight: .infinity) }
            else {
                List(model.visible, selection: $model.selected) { item in
                    ItemRow(item: item).tag(item.id)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
            if model.showConsole { ConsolePanel() }
        }
    }
}

struct UpdatesHero: View {
    @EnvironmentObject var model: WorkbenchModel
    var body: some View {
        let count = model.updates.count
        let direct = model.directUpdates.count
        VStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(HeroSummary.title(updates: count, scanned: model.scanned))
                        .font(.title2.weight(.bold)).foregroundStyle(.white)
                    Text(model.busy ? model.operation : HeroSummary.subtitle(updates: count, direct: direct, scanned: model.scanned, total: model.items.count))
                        .font(.callout).foregroundStyle(.white.opacity(0.85)).lineLimit(3)
                }
                Spacer(minLength: 8)
                Image(systemName: !model.scanned ? "sparkle.magnifyingglass" : (count == 0 ? "checkmark.seal.fill" : "arrow.down.circle.fill"))
                    .font(.system(size: 34, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                    .accessibilityHidden(true)
            }
            HStack(spacing: 8) {
                if model.scanned && direct > 0 {
                    Button { model.confirmUpdateAll = true } label: { Label(direct == 1 ? "Update 1 Item" : "Update All \(direct)", systemImage: "arrow.down.circle.fill") }
                        .buttonStyle(HeroButtonStyle()).disabled(model.busy)
                        .help("Install every update that can be installed here (⇧⌘U)")
                    Button { model.scan() } label: { Label("Check Again", systemImage: "arrow.clockwise") }
                        .buttonStyle(HeroButtonStyle(filled: false)).disabled(model.busy)
                } else {
                    Button { model.scan() } label: { Label(model.scanned ? "Check Again" : "Check for Updates", systemImage: "arrow.clockwise") }
                        .buttonStyle(HeroButtonStyle()).disabled(model.busy)
                        .help("Check for updates (⌘R)")
                }
                if model.busy { ProgressView().controlSize(.small).tint(.white).padding(.leading, 4) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(!model.scanned ? Theme.idleGradient : (count == 0 ? Theme.successGradient : Theme.accentGradient)))
        .overlay(alignment: .topTrailing) {
            Circle().fill(.white.opacity(0.08)).frame(width: 120, height: 120).offset(x: 40, y: -50).allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Theme.violet.opacity(0.25), radius: 10, y: 4)
        if model.scanned {
            HStack(spacing: 8) {
                StatTile(value: count, label: "Updates", symbol: "arrow.down.circle.fill", tint: Theme.indigo)
                StatTile(value: direct, label: "Install here", symbol: "bolt.fill", tint: Theme.mint)
                StatTile(value: model.items.count, label: "Installed", symbol: "square.grid.2x2.fill", tint: Theme.violet)
                StatTile(value: model.suggestions.count, label: "Suggestions", symbol: "lightbulb.fill", tint: SidebarSection.suggestions.tint)
            }
        }
        }
    }
}

struct SectionHeader: View {
    let section: SidebarSection
    @EnvironmentObject var model: WorkbenchModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: section.symbol).font(.title2).foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(LinearGradient(colors: [section.tint, section.tint.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(section.rawValue).font(.title3.weight(.semibold))
                Text(section.subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        if section == .suggestions {
            HStack(spacing: 8) {
                Button { model.findHomebrewMatches() } label: { Label("Find Homebrew Matches", systemImage: "magnifyingglass") }
                    .disabled(model.busy || model.items.isEmpty)
                    .help("Match apps without an update source to Homebrew casks (read-only)")
                Text("Read-only. Nothing is adopted until you confirm.").font(.caption).foregroundStyle(.secondary)
            }
        }
        }
    }
}

struct FilterBar: View {
    @EnvironmentObject var model: WorkbenchModel
    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("Source", selection: $model.sourceFilter) {
                    Label("All sources", systemImage: "line.3.horizontal.decrease.circle").tag("All sources")
                    Divider()
                    ForEach(UpdateProvider.allCases, id: \.rawValue) { Label($0.rawValue, systemImage: $0.symbol).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(model.sourceFilter, systemImage: model.sourceFilter == "All sources" ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Show only one update source")
            Spacer()
            Text(model.visible.count == 1 ? "1 item" : "\(model.visible.count) items").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if model.sourceFilter != "All sources" || !model.search.isEmpty {
                Button("Clear") { model.sourceFilter = "All sources"; model.search = "" }.buttonStyle(.link).font(.caption)
            }
        }
    }
}

struct ItemRow: View {
    let item: UpdateItem
    @EnvironmentObject var model: WorkbenchModel
    var body: some View {
        let status = model.status(item)
        HStack(spacing: 12) {
            AppIconView(item: item, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.headline).lineLimit(1).truncationMode(.tail)
                HStack(spacing: 6) {
                    SourceBadge(provider: item.provider)
                    if model.section == .suggestions {
                        let count = (item.repositorySuggestions ?? []).count + (item.caskSuggestions ?? []).count
                        Pill(text: count == 1 ? "1 suggestion" : "\(count) suggestions", symbol: "lightbulb.fill", tint: SidebarSection.suggestions.tint)
                    } else if !(model.section == .updates && status == .ready) && status != .unknown { StatusBadge(status: status) }
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            VersionColumn(item: item)
            if model.section == .updates && item.canUpdateDirectly {
                Button("Update") { model.pendingUpdate = item }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(model.busy)
                    .help("Update \(item.name) to \(item.latestVersion ?? "the latest version")")
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), \(item.provider.rawValue), \(status.rawValue), installed \(item.installedVersion)\(item.isOutdated ? ", available \(item.latestVersion ?? "")" : "")")
    }
}

struct VersionColumn: View {
    let item: UpdateItem
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if item.isOutdated, let latest = item.latestVersion {
                Text(latest).font(.system(.callout, design: .monospaced).weight(.semibold)).foregroundStyle(Theme.accent)
                    .lineLimit(1)
                Text("from \(item.installedVersion)").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text(item.installedVersion).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: 110, alignment: .trailing)
        .truncationMode(.middle)
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var model: WorkbenchModel
    var body: some View {
        if model.busy && model.items.isEmpty {
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Checking your apps…").font(.headline)
                Text(model.operation).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !model.scanned && model.items.isEmpty && model.section == .updates {
            ContentUnavailableView {
                Label("Nothing to show yet", systemImage: "sparkle.magnifyingglass")
            } description: {
                Text("Choose Check for Updates above (⌘R). Update Workbench looks at your app folders, Homebrew and update feeds. Nothing is installed until you choose Update.")
            }
        } else if !model.scanned && model.items.isEmpty {
            ContentUnavailableView {
                Label("No scan yet", systemImage: "sparkle.magnifyingglass")
            } description: {
                Text("Update Workbench looks at your app folders, Homebrew and update feeds to find newer versions. Nothing is installed until you choose Update.")
            } actions: {
                Button("Check for Updates") { model.scan() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        } else if model.sourceFilter != "All sources" || !model.search.isEmpty {
            ContentUnavailableView {
                Label("No matches", systemImage: "magnifyingglass")
            } description: {
                Text(model.search.isEmpty ? "Nothing in this section uses \(model.sourceFilter)." : "Nothing matches “\(model.search)” here.")
            } actions: {
                Button("Clear Search and Filter") { model.sourceFilter = "All sources"; model.search = "" }
            }
        } else {
            switch model.section {
            case .updates:
                ContentUnavailableView {
                    Label("You're all set", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } description: { Text("Every app and package with a known update source is up to date.") }
                actions: { Button("Check Again") { model.scan() }.disabled(model.busy) }
            case .suggestions:
                ContentUnavailableView {
                    Label("No suggestions yet", systemImage: "lightbulb")
                } description: { Text("Find Homebrew matches for apps that have no update source. It only reads public Homebrew data.") }
                actions: { Button("Find Homebrew Matches") { model.findHomebrewMatches() }.disabled(model.busy || model.items.isEmpty) }
            case .ignored:
                ContentUnavailableView("Nothing ignored", systemImage: "eye", description: Text("Use Later in an app's details to skip a version, snooze it, ignore the app or hold back betas. Manage rules in Settings → Rules."))
            case .packages:
                ContentUnavailableView("No Homebrew packages", systemImage: "shippingbox", description: Text("Command-line packages installed with Homebrew appear here."))
            default:
                ContentUnavailableView("Nothing here", systemImage: "tray", description: Text("Check for updates to fill this list."))
            }
        }
    }
}

struct ConsolePanel: View {
    @EnvironmentObject var model: WorkbenchModel
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Label("Console", systemImage: "terminal.fill").font(.caption.weight(.semibold)).foregroundStyle(Theme.mint)
                Spacer()
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.log, forType: .string) }
                Button("Clear") { model.log = "Console cleared." }
                Button { model.showConsole = false } label: { Image(systemName: "xmark") }.help("Hide console").accessibilityLabel("Hide console")
            }
            .buttonStyle(.borderless).font(.caption)
            .padding(.horizontal, 12).padding(.vertical, 6)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.log).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 8)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: model.log) { proxy.scrollTo("end") }
            }
        }
        .frame(height: 190)
        .background(.black.opacity(0.25))
    }
}
