import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var model: WorkbenchModel
    var body: some View {
        TabView {
            GeneralSettingsView().tabItem { Label("General", systemImage: "gearshape") }
            RulesSettingsView().tabItem { Label("Rules", systemImage: "line.3.horizontal.decrease.circle") }
            TrustSettingsView().tabItem { Label("Trust", systemImage: "checkmark.shield") }
            AppearanceSettingsView().tabItem { Label("Appearance", systemImage: "paintpalette") }
            ProxySettingsView().tabItem { Label("Network", systemImage: "network") }
            SelfUpdateSettingsView().tabItem { Label("Updates", systemImage: "arrow.down.app") }
        }
        .frame(width: 640, height: 540)
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject var model: WorkbenchModel
    @State private var customRoots = (UserDefaults.standard.stringArray(forKey: "customRoots") ?? []).joined(separator: "\n")
    var body: some View {
        Form {
            Section {
                Picker("Check for updates", selection: $model.schedule) {
                    ForEach(CheckSchedule.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Notify me about new updates and results", isOn: Binding(get: { model.notificationsEnabled }, set: { model.setNotifications($0) }))
                Toggle("Show Update Workbench in the menu bar", isOn: $model.showMenuBarIcon)
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLogin($0) }))
            } header: { Text("Background checks") } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let next = model.schedule.nextCheck(after: model.lastScheduledCheck) {
                        Label("Next check \(next <= Date() ? "within a few minutes" : next.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock").foregroundStyle(Theme.accent)
                    }
                    Text("Checks only look for updates and run while Update Workbench is open (it keeps running in the menu bar). Nothing is installed automatically: every update waits for your confirmation.")
                }
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
            }
            Section {
                TextEditor(text: $customRoots).frame(height: 64).font(.system(.callout, design: .monospaced))
                    .accessibilityLabel("Additional application folders")
                HStack { Spacer(); Button("Save Folders") {
                    let paths = customRoots.split(separator: "\n").map(String.init).filter { $0.hasPrefix("/") }
                    UserDefaults.standard.set(paths, forKey: "customRoots"); model.scan()
                } }
            } header: { Text("Additional application folders") } footer: {
                Text("One absolute path per line. /Applications and ~/Applications are always included. Sources: Homebrew casks and formulae, optional mas CLI, Sparkle feeds, declared Electron update feeds and GitHub repositories you choose.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
            }
        }
        .formStyle(.grouped)
    }
}

struct RulesSettingsView: View {
    @EnvironmentObject var model: WorkbenchModel
    @State private var confirmReset = false
    @State private var newRuleApp = ""
    var body: some View {
        Form {
            Section {
                Toggle("Hold back pre-releases and betas", isOn: $model.holdPrereleases)
            } header: { Text("Pre-releases") } footer: {
                Text("Recommended. Versions like 2.0-beta.1, 3.1b2, 4.0rc1, alpha, preview or nightly are hidden unless an app has its own rule below. Allowing betas also lets Sparkle beta channels and GitHub pre-releases through.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
            }
            Section {
                let ids = Array(Set(model.rules.ruleIDs).union(model.snoozed.filter { $0.value > Date().timeIntervalSince1970 }.keys)).sorted { model.ruleName($0).localizedCaseInsensitiveCompare(model.ruleName($1)) == .orderedAscending }
                if ids.isEmpty {
                    Text("No app rules yet. Use Later in an app's details, or add one below.").foregroundStyle(.secondary)
                }
                ForEach(ids, id: \.self) { id in RuleRow(id: id) }
                HStack {
                    Picker("Add a rule for", selection: $newRuleApp) {
                        Text("Choose an app…").tag("")
                        ForEach(model.items.filter { !ids.contains($0.id) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { Text($0.name).tag($0.id) }
                    }
                    Menu("Add") {
                        Button("Ignore App") { model.ignored.insert(newRuleApp); newRuleApp = "" }
                        if let item = model.items.first(where: { $0.id == newRuleApp }), item.isOutdated, let latest = item.latestVersion {
                            Button("Skip Version \(latest)") { model.skipped[newRuleApp] = latest; newRuleApp = "" }
                        }
                        Button("Allow Betas") { model.setPrereleaseRule(.allow, for: newRuleApp); newRuleApp = "" }
                        Button("Always Hold Back Betas") { model.setPrereleaseRule(.hold, for: newRuleApp); newRuleApp = "" }
                    }
                    .fixedSize().disabled(newRuleApp.isEmpty)
                }
            } header: { Text("App rules") } footer: {
                HStack {
                    Text("Skipped versions come back automatically when a newer version is released.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset All…", role: .destructive) { confirmReset = true }.disabled(model.rules.ruleIDs.isEmpty && model.snoozed.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove every ignore, skip, snooze and beta rule?", isPresented: $confirmReset) {
            Button("Reset Rules", role: .destructive) {
                model.ignored = []; model.skipped = [:]; model.prereleaseRules = [:]; model.snoozed = [:]
                UserDefaults.standard.removeObject(forKey: "snoozed")
            }
        } message: { Text("The global pre-release setting is kept.") }
    }
}

struct RuleRow: View {
    let id: String
    @EnvironmentObject var model: WorkbenchModel
    var body: some View {
        HStack(spacing: 10) {
            if let item = model.items.first(where: { $0.id == id }) { AppIconView(item: item, size: 26) }
            else { Image(systemName: "app.dashed").font(.title3).foregroundStyle(.secondary).frame(width: 26) }
            VStack(alignment: .leading, spacing: 4) {
                Text(model.ruleName(id)).font(.callout.weight(.semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    if model.ignored.contains(id) { Pill(text: "Ignored", symbol: "eye.slash.fill", tint: .gray) }
                    if let version = model.skipped[id] { Pill(text: "Skipping \(version)", symbol: "forward.end.fill", tint: Theme.indigo) }
                    if let rule = model.prereleaseRules[id], rule != .followGlobal {
                        Pill(text: rule == .allow ? "Betas allowed" : "Betas held", symbol: "flask.fill", tint: rule == .allow ? Theme.mint : .orange)
                    }
                    if let until = model.snoozed[id], until > Date().timeIntervalSince1970 {
                        Pill(text: "Snoozed to \(Date(timeIntervalSince1970: until).formatted(date: .abbreviated, time: .omitted))", symbol: "moon.zzz.fill", tint: .purple)
                    }
                }
            }
            Spacer()
            Menu {
                Button(model.ignored.contains(id) ? "Stop Ignoring" : "Ignore App") { if model.ignored.contains(id) { model.ignored.remove(id) } else { model.ignored.insert(id) } }
                if model.skipped[id] != nil { Button("Stop Skipping \(model.skipped[id] ?? "")") { model.skipped.removeValue(forKey: id) } }
                Divider()
                Picker("Betas", selection: Binding(get: { model.prereleaseRules[id] ?? .followGlobal }, set: { model.setPrereleaseRule($0, for: id) })) {
                    ForEach(PrereleaseRule.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: { Image(systemName: "slider.horizontal.3") }
                .menuStyle(.borderlessButton).fixedSize().help("Change this app's rules")
            Button(role: .destructive) { model.removeRules(for: id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Remove all rules for this app").accessibilityLabel("Remove rules for \(model.ruleName(id))")
        }
    }
}

struct TrustSettingsView: View {
    @EnvironmentObject var model: WorkbenchModel
    @State private var pendingRevoke: TrustedSignerApproval?
    var body: some View {
        Form {
            Section {
                if model.approvals.isEmpty {
                    Label("No signer changes approved. If an update is signed by a different developer team, Update Workbench stops and asks you.", systemImage: "checkmark.shield")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.approvals) { approval in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "person.badge.shield.checkmark.fill").font(.title3).foregroundStyle(.orange).frame(width: 26)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(approval.appName).font(.callout.weight(.semibold))
                            Text("\(approval.previousSignerName) (\(approval.previousTeamID)) → \(approval.signerName) (\(approval.teamID))").font(.caption).textSelection(.enabled)
                            Text("\(approval.bundleID) · approved \(approval.approvedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Revoke…", role: .destructive) { pendingRevoke = approval }
                    }
                }
            } header: { Text("Approved signer changes") } footer: {
                Text("Each approval covers one app and one new Developer ID team. Code signing and Gatekeeper are still required. Revoking means the next update from that team asks again.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
            }
            Section {
                Label("No copies of previous versions are kept", systemImage: "trash.slash")
            } header: { Text("Previous versions") } footer: {
                Text("Direct installs stage the new app in a private temporary folder, swap it in, verify it, and only then delete the previous version. If anything fails, the previous version is put back. Nothing is left beside your apps.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Revoke the approval for \(pendingRevoke?.appName ?? "")?", isPresented: Binding(get: { pendingRevoke != nil }, set: { if !$0 { pendingRevoke = nil } })) {
            Button("Revoke", role: .destructive) { if let approval = pendingRevoke { model.revokeApproval(approval) }; pendingRevoke = nil }
        } message: { Text("Updates signed by team \(pendingRevoke?.teamID ?? "") will need your approval again.") }
    }
}

struct AppearanceSettingsView: View {
    @EnvironmentObject var model: WorkbenchModel
    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Button { model.appearance = mode } label: { AppearanceSwatch(mode: mode, selected: model.appearance == mode) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(mode.rawValue) appearance")
                            .accessibilityAddTraits(model.appearance == mode ? .isSelected : [])
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                Picker("Theme", selection: $model.appearance) {
                    ForEach(AppearanceMode.allCases) { Label($0 == .dark ? "Dark (default)" : $0.rawValue, systemImage: $0.symbol).tag($0) }
                }
            } header: { Text("Appearance") } footer: {
                Text("Dark is the default. System follows the appearance chosen in macOS System Settings.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
            }
        }
        .formStyle(.grouped)
    }
}

struct AppearanceSwatch: View {
    let mode: AppearanceMode
    let selected: Bool
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                switch mode {
                case .dark: swatch(background: Color(white: 0.12), panel: Color(white: 0.2))
                case .light: swatch(background: Color(white: 0.96), panel: .white)
                case .system:
                    HStack(spacing: 0) {
                        swatch(background: Color(white: 0.96), panel: .white)
                        swatch(background: Color(white: 0.12), panel: Color(white: 0.2))
                    }
                    .frame(width: 120)
                    .clipped()
                }
            }
            .frame(width: 120, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Theme.accent : Color.secondary.opacity(0.3), lineWidth: selected ? 3 : 1))
            Label(mode == .dark ? "Dark (default)" : mode.rawValue, systemImage: mode.symbol)
                .font(.callout.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.accent : .primary)
        }
        .contentShape(Rectangle())
    }
    private func swatch(background: Color, panel: Color) -> some View {
        ZStack(alignment: .topLeading) {
            background
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 4).fill(Theme.accentGradient).frame(height: 18)
                RoundedRectangle(cornerRadius: 3).fill(panel).frame(height: 10)
                RoundedRectangle(cornerRadius: 3).fill(panel).frame(width: 50, height: 10)
            }
            .padding(10)
        }
    }
}

struct ProxySettingsView: View {
    @EnvironmentObject var model: WorkbenchModel
    @State private var settings = ProxySettings.load()
    @State private var password = ""
    @State private var status = ""
    @State private var passwordStored = ProxySettings.load().storedPassword() != nil
    var body: some View {
        Form {
            Section {
                Picker("Proxy", selection: $settings.mode) { ForEach(ProxyMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                if settings.mode == .manual {
                    Picker("Type", selection: $settings.kind) { ForEach(ProxyKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    TextField("Server", text: $settings.host, prompt: Text("proxy.example.com"))
                    TextField("Port", value: $settings.port, format: .number.grouping(.never))
                    Toggle("Proxy requires authentication", isOn: $settings.authenticated)
                    if settings.authenticated {
                        TextField("User name", text: $settings.username)
                        SecureField("Password", text: $password, prompt: Text(passwordStored ? "Saved in Keychain — leave empty to keep" : "Password"))
                    }
                }
            } header: { Text("Proxy") } footer: {
                Text("Applies to Update Workbench's own feed checks and downloads. The password is stored only in your login Keychain. Homebrew and mas receive the proxy server and port, never the password.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
            }
            Section {
                HStack {
                    if !status.isEmpty { Label(status, systemImage: status.hasPrefix("Saved") ? "checkmark.circle.fill" : "exclamationmark.circle.fill").font(.callout).foregroundStyle(status.hasPrefix("Saved") ? .green : .orange) }
                    Spacer()
                    Button("Remove Saved Password", role: .destructive) { removePassword() }.disabled(!passwordStored)
                    Button("Save") { save() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
    }
    private func save() {
        if let problem = settings.validationError() { status = problem; return }
        let previous = ProxySettings.load()
        let store = KeychainStore(service: ProxySettings.keychainService)
        do {
            if !previous.username.isEmpty, previous.username != settings.username || !settings.authenticated || settings.mode != .manual {
                try store.delete(account: previous.username)
            }
            if settings.mode == .manual, settings.authenticated, !password.isEmpty { try store.save(password, account: settings.username) }
            try settings.save()
            password = ""; passwordStored = settings.storedPassword() != nil
            status = settings.mode == .manual && settings.authenticated && !passwordStored ? "Saved. Enter the proxy password to authenticate." : "Saved."
        } catch { status = error.localizedDescription }
    }
    private func removePassword() {
        do {
            try KeychainStore(service: ProxySettings.keychainService).delete(account: ProxySettings.load().username)
            passwordStored = false; status = "Saved password removed from the Keychain."
        } catch { status = error.localizedDescription }
    }
}

struct SelfUpdateSettingsView: View {
    @EnvironmentObject var model: WorkbenchModel
    @State private var feed = UserDefaults.standard.string(forKey: SelfUpdateFeed.defaultsKey) ?? ""
    @State private var feedStatus = ""
    @State private var confirmInstall = false
    var body: some View {
        Form {
            Section {
                LabeledContent("Installed version") { Text(model.appVersion).font(.system(.body, design: .monospaced)) }
                TextField("Release feed", text: $feed, prompt: Text("github:owner/repo or appcast URL"))
                HStack {
                    if !feedStatus.isEmpty { Text(feedStatus).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Save Feed") {
                        do {
                            let parsed = try SelfUpdateFeed.parse(feed)
                            UserDefaults.standard.set(feed.trimmingCharacters(in: .whitespacesAndNewlines), forKey: SelfUpdateFeed.defaultsKey)
                            feedStatus = "Saved: \(parsed.description)"
                        } catch { feedStatus = error.localizedDescription }
                    }
                    Button("Check Now") { model.checkSelfUpdate() }.disabled(model.busy)
                }
            } header: { Text("Update Workbench updates") } footer: {
                Text("Off by default: this build has no published releases. A new copy must have the same bundle ID, be signed by the same Developer ID team, pass Gatekeeper and be newer. Locally signed development builds can't update themselves.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
            }
            if !model.selfUpdateMessage.isEmpty || model.selfUpdateRelease != nil || model.selfUpdateInstalled {
                Section("Status") {
                    if !model.selfUpdateMessage.isEmpty { Text(model.selfUpdateMessage).font(.callout).textSelection(.enabled) }
                    if let release = model.selfUpdateRelease { Button("Install \(release.version)…") { confirmInstall = true }.buttonStyle(.borderedProminent).disabled(model.busy) }
                    if model.selfUpdateInstalled { Button("Relaunch Update Workbench") { model.relaunch() } }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Install Update Workbench \(model.selfUpdateRelease?.version ?? "")?", isPresented: $confirmInstall) {
            Button("Install") { model.installSelfUpdate() }
        } message: { Text("The new version replaces this copy after it passes the checks; the old copy is deleted. Relaunch afterwards to use the new version.") }
    }
}

struct PermissionsView: View {
    @EnvironmentObject var model: WorkbenchModel
    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(section: .permissions).padding(14)
            Divider()
            if model.permissions.isEmpty {
                VStack(spacing: 10) { ProgressView(); Text("Checking access…").foregroundStyle(.secondary) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(model.permissions) { check in PermissionRow(check: check) }
                        HStack {
                            Text("Read-only checks. Some states are estimates because macOS has no public way to ask about every privacy permission.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button { model.refreshPermissions() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        }
                        .padding(.top, 4)
                    }
                    .padding(14)
                }
            }
        }
        .onAppear { model.refreshPermissions() }
    }
}

struct PermissionRow: View {
    let check: PermissionCheck
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: check.state.symbol).font(.title2).foregroundStyle(check.state.tint).frame(width: 26).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(check.title.replacingOccurrences(of: NSHomeDirectory() + "/", with: "~/")).font(.headline)
                    Pill(text: check.state.rawValue, symbol: check.state.symbol, tint: check.state.tint)
                }
                Text(check.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let url = check.settingsURL {
                    Button { NSWorkspace.shared.open(url) } label: { Label("Open in System Settings", systemImage: "arrow.up.forward.square") }
                        .buttonStyle(.link).font(.callout)
                        .help("Open this page of System Settings")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(check.state == .denied ? Color.orange.opacity(0.5) : Color.secondary.opacity(0.15), lineWidth: check.state == .denied ? 1 : 0.5))
        .accessibilityElement(children: .contain)
    }
}

struct PermissionsHelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                Label("Why these permissions matter", systemImage: "lock.shield.fill").font(.title2.weight(.bold)).foregroundStyle(Theme.mint)
                Card(title: "App Management", symbol: "app.badge.checkmark", tint: Theme.indigo) {
                    Text("macOS may block replacing apps until you allow Update Workbench under Privacy & Security → App Management. If an update fails with “Operation not permitted”, allow it there and try again.").font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                Card(title: "Full Disk Access", symbol: "externaldrive.fill", tint: Theme.violet) {
                    Text("Not required for normal checks. It only helps when apps live in protected folders.").font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                Card(title: "Notifications", symbol: "bell.badge.fill", tint: Theme.pink) {
                    Text("Optional. Turn them on in Settings → General to hear about new updates and results.").font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                Text("Update Workbench never asks for your password and never changes these settings for you.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}
