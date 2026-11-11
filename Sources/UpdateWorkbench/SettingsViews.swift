import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var model: WorkbenchModel
    var body: some View {
        TabView {
            GeneralSettingsView().tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettingsView().tabItem { Label("Appearance", systemImage: "paintpalette") }
            ProxySettingsView().tabItem { Label("Network", systemImage: "network") }
            SelfUpdateSettingsView().tabItem { Label("Updates", systemImage: "arrow.down.app") }
        }
        .frame(width: 600, height: 500)
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject var model: WorkbenchModel
    @State private var customRoots = (UserDefaults.standard.stringArray(forKey: "customRoots") ?? []).joined(separator: "\n")
    @State private var confirmClear = false
    var body: some View {
        Form {
            Section {
                Picker("Check automatically", selection: $model.interval) {
                    Text("Manually").tag(0.0); Text("Hourly").tag(3600.0); Text("Every 4 hours").tag(14400.0); Text("Daily").tag(86400.0)
                }.onChange(of: model.interval) { model.schedule() }
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLogin($0) }))
                Toggle("Notify about new updates and update results", isOn: Binding(get: { model.notificationsEnabled }, set: { model.setNotifications($0) }))
            } header: { Text("Checking") } footer: {
                Text("Scheduled checks run while Update Workbench is open. Each available version is announced once. Installation always needs an explicit Update.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
            }
            Section {
                TextEditor(text: $customRoots).frame(height: 64).font(.system(.callout, design: .monospaced))
                    .accessibilityLabel("Additional application folders")
                HStack { Spacer(); Button("Save Folders") {
                    let paths = customRoots.split(separator: "\n").map(String.init).filter { $0.hasPrefix("/") }
                    UserDefaults.standard.set(paths, forKey: "customRoots"); model.scan()
                } }
            } header: { Text("Additional application folders") } footer: {
                Text("One absolute path per line. /Applications and ~/Applications are always included.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
            }
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ignored apps, skipped versions and snoozes")
                        Text("\(model.ignored.count) ignored · \(model.skipped.count) skipped · \(model.snoozed.count) snoozed").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reset…") { confirmClear = true }.disabled(model.ignored.isEmpty && model.skipped.isEmpty && model.snoozed.isEmpty)
                }
            } header: { Text("Hidden updates") } footer: {
                Text("Sources: Homebrew casks and formulae, optional mas CLI, Sparkle feeds, declared Electron update feeds and GitHub repositories you choose. Apps with vendor updaters open their own updater.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Show all ignored, skipped and snoozed updates again?", isPresented: $confirmClear) {
            Button("Reset") { model.ignored = []; model.skipped = [:]; model.snoozed = [:]; for key in ["ignored", "skipped", "snoozed"] { UserDefaults.standard.removeObject(forKey: key) } }
        }
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
        } message: { Text("The current copy is kept as a hidden backup beside the app. Relaunch afterwards to use the new version.") }
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
