import SwiftUI
import AppKit

// MARK: Release notes

/// Sanitized notes rendered with native Text only: no web view, no scripts, no remote images.
struct ReleaseNotesView: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(ReleaseNotes.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let value):
                    Text(ReleaseNotes.inline(value)).font(level <= 2 ? .headline : .subheadline.weight(.semibold)).padding(.top, 2)
                case .bullet(let value):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(Theme.accentGradient).frame(width: 6, height: 6).offset(y: -2).accessibilityHidden(true)
                        Text(ReleaseNotes.inline(value)).fixedSize(horizontal: false, vertical: true)
                    }
                case .paragraph(let value):
                    Text(ReleaseNotes.inline(value)).fixedSize(horizontal: false, vertical: true)
                case .rule:
                    Divider()
                }
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "What's new" content for an item: feed notes, notes loaded on demand, or a pointer to the release page.
struct WhatsNewContent: View {
    let item: UpdateItem
    @EnvironmentObject var model: WorkbenchModel
    var body: some View {
        if let notes = model.notes(for: item) {
            ReleaseNotesView(text: notes)
        } else if let link = item.releaseNotesLink, model.notesLoading.contains(link.absoluteString) {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading release notes…").foregroundStyle(.secondary) }.font(.callout)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("The developer didn't publish release notes with this update.").font(.callout).foregroundStyle(.secondary)
                if let page = item.githubRelease?.releasePageURL ?? item.homepage {
                    Link(destination: page) { Label("Open the release page", systemImage: "arrow.up.right.square") }.font(.callout)
                }
            }
        }
    }
}

// MARK: Update confirmation

struct UpdateConfirmSheet: View {
    let item: UpdateItem
    @EnvironmentObject var model: WorkbenchModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                AppIconView(item: item, size: 54)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Update \(item.name)").font(.title2.weight(.bold)).foregroundStyle(.white)
                    HStack(spacing: 8) {
                        Text(item.installedVersion).foregroundStyle(.white.opacity(0.8))
                        Image(systemName: "arrow.right").foregroundStyle(.white.opacity(0.8))
                        Text(item.latestVersion ?? "Latest").foregroundStyle(.white)
                    }
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                }
                Spacer()
                Pill(text: item.provider.shortName, symbol: item.provider.symbol, tint: .white.opacity(0.25), prominent: true)
            }
            .padding(18)
            .background(Theme.accentGradient)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Card(title: "What's new in \(item.latestVersion ?? "this version")", symbol: "sparkles", tint: Theme.pink) {
                        WhatsNewContent(item: item)
                    }
                    Card(title: "Before it's installed", symbol: "checkmark.shield.fill", tint: Theme.mint) {
                        ForEach(SafetyChecklist.lines(for: item), id: \.self) { line in
                            Label { Text(line).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.mint) }
                                .font(.callout)
                        }
                    }
                }
                .padding(18)
            }
            .frame(maxHeight: 420)
            Divider()
            HStack {
                Label("Quit \(item.name) first.", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { model.pendingUpdate = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Button { model.pendingUpdate = nil; dismiss(); model.update([item]) } label: { Label("Update to \(item.latestVersion ?? "Latest")", systemImage: "arrow.down.circle.fill") }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.busy)
            }
            .padding(14)
        }
        .frame(width: 580)
        .onAppear { model.loadNotes(item) }
    }
}

enum SafetyChecklist {
    static func lines(for item: UpdateItem) -> [String] {
        switch item.provider {
        case .homebrewCask, .homebrewFormula: return ["Installed by Homebrew with its own checksum verification.", "The result is logged in History."]
        case .appStore: return ["Installed by the Mac App Store through mas.", "Apple may ask you to sign in."]
        default:
            var lines: [String] = []
            if item.sparkleRelease?.sha512 != nil { lines.append("The download must match the SHA-512 published in the feed.") }
            if item.requiresSparkleSignature == true { lines.append("The archive must carry a valid Sparkle Ed25519 signature.") }
            lines += ["The app must have the same bundle ID and developer team (or a team you approved).",
                      "Code signature (codesign --deep --strict), Gatekeeper, version and CPU are checked.",
                      "The previous version is removed only after the new one is in place and verified; if anything fails it is put back."]
            return lines
        }
    }
}

// MARK: Signer approval

struct SignerApprovalSheet: View {
    let change: SignerChange
    @EnvironmentObject var model: WorkbenchModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmed = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "person.badge.shield.checkmark.fill").font(.system(size: 34, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 54, height: 54).background(Circle().fill(.white.opacity(0.18)))
                VStack(alignment: .leading, spacing: 4) {
                    Text("New developer signature").font(.title2.weight(.bold)).foregroundStyle(.white)
                    Text("\(change.appName) \(change.version) is signed by a different Developer ID team than the copy you have installed.")
                        .font(.callout).foregroundStyle(.white.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            .background(LinearGradient(colors: [Color(red: 0.95, green: 0.45, blue: 0.20), Theme.pink, Theme.violet], startPoint: .topLeading, endPoint: .bottomTrailing))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        SignerCard(title: "Installed", identity: change.installed, highlight: false)
                        Image(systemName: "arrow.right").font(.title3.weight(.bold)).foregroundStyle(.orange).padding(.top, 40).accessibilityHidden(true)
                        SignerCard(title: "Update \(change.version)", identity: change.candidate, highlight: true)
                    }
                    Card(title: "Checks", symbol: "checklist", tint: Theme.mint) {
                        CheckLine(ok: true, text: "Code signature is valid (codesign --deep --strict).")
                        CheckLine(ok: true, text: "Gatekeeper accepted it: \(change.candidate.gatekeeper ?? "accepted").")
                        CheckLine(ok: true, text: "Bundle ID matches: \(change.bundleID).")
                        CheckLine(ok: false, text: "Developer team changed from \(change.installed.teamID) to \(change.candidate.teamID).")
                    }
                    Text("A team can change when an app moves to a new company account or is sold, but an unexpected change can also mean a tampered download. Check the developer's website or release notes before you approve.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("The approval applies only to \(change.appName) (\(change.bundleID)) and team \(change.candidate.teamID). Code signing and Gatekeeper are still checked on every update. Revoke it anytime in Settings → Trust.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
            }
            .frame(maxHeight: 540)
            Divider()
            // The confirmation stays next to the buttons so it is always visible.
            HStack(alignment: .center, spacing: 12) {
                Toggle(isOn: $confirmed) {
                    Text("I checked that \(change.candidate.signerName) (\(change.candidate.teamID)) is a legitimate publisher of \(change.appName).")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
                Spacer(minLength: 8)
                Button("Don't Install", role: .cancel) { model.declineSigner(change); dismiss() }.keyboardShortcut(.cancelAction)
                Button { model.approveSigner(change); dismiss() } label: { Label("Approve and Install", systemImage: "checkmark.shield.fill") }
                    .buttonStyle(.borderedProminent).tint(.orange).disabled(!confirmed)
            }
            .padding(14)
        }
        .frame(width: 660)
    }
}

struct SignerCard: View {
    let title: String
    let identity: SignerIdentity
    let highlight: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(identity.signerName).font(.headline).lineLimit(2).textSelection(.enabled)
            Pill(text: "Team \(identity.teamID)", symbol: highlight ? "exclamationmark.triangle.fill" : "checkmark.seal.fill", tint: highlight ? .orange : .green)
            VStack(alignment: .leading, spacing: 4) {
                detail("Certificate", identity.certificateKind)
                if identity.authorities.count > 1 { detail("Issued by", identity.authorities.dropFirst().joined(separator: " → ")) }
                if let time = identity.signedTime { detail("Signed", time) }
                if let expires = identity.leafExpires { detail("Expires", expires.formatted(date: .abbreviated, time: .omitted)) }
                if let sha = identity.leafSHA256 { detail("SHA-256", sha, monospaced: true) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill((highlight ? Color.orange : Color.green).opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder((highlight ? Color.orange : Color.green).opacity(0.35), lineWidth: 1))
    }
    private func detail(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(monospaced ? .system(.caption2, design: .monospaced) : .caption).textSelection(.enabled)
                .lineLimit(monospaced ? 2 : 3).truncationMode(.middle)
        }
    }
}

struct CheckLine: View {
    let ok: Bool
    let text: String
    var body: some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(ok ? Theme.mint : .orange)
        }
        .font(.callout)
    }
}

// MARK: License agreement

struct LicenseSheet: View {
    let prompt: LicenseAgreementRequired
    @EnvironmentObject var model: WorkbenchModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.fill").font(.title).foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text("License agreement").font(.title2.weight(.bold)).foregroundStyle(.white)
                    Text("\(prompt.appName) \(prompt.version) asks you to accept these terms before its disk image can be opened.").font(.callout).foregroundStyle(.white.opacity(0.9))
                }
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Theme.idleGradient)
            ScrollView {
                Text(prompt.text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(18)
            }
            .frame(height: 300)
            .background(.background.secondary)
            Divider()
            HStack {
                Text("Nothing is mounted or installed until you agree.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Disagree", role: .cancel) { model.declineLicense(prompt); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Agree and Continue") { model.acceptLicense(prompt); dismiss() }.buttonStyle(.borderedProminent)
            }
            .padding(14)
        }
        .frame(width: 560)
    }
}

// MARK: History

extension HistoryEntry.Result {
    var symbol: String {
        switch self {
        case .installed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .restored: "arrow.uturn.backward.circle.fill"
        case .restoreFailed: "exclamationmark.triangle.fill"
        }
    }
    var tint: Color {
        switch self {
        case .installed: .green
        case .failed: .red
        case .restored: Theme.indigo
        case .restoreFailed: .orange
        }
    }
}

struct HistoryListColumn: View {
    @EnvironmentObject var model: WorkbenchModel
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(section: .history)
                if !model.history.isEmpty {
                    HStack(spacing: 8) {
                        StatTile(value: model.history.filter { $0.result == .installed }.count, label: "Installed", symbol: "checkmark.circle.fill", tint: .green)
                        StatTile(value: model.history.filter { $0.result == .failed || $0.result == .restoreFailed }.count, label: "Failed", symbol: "xmark.octagon.fill", tint: .red)
                        StatTile(value: Set(model.history.map(\.appName)).count, label: "Apps", symbol: "square.grid.2x2.fill", tint: Theme.indigo)
                        StatTile(value: model.history.filter { $0.date > Date().addingTimeInterval(-7 * 86400) }.count, label: "Last 7 days", symbol: "calendar", tint: Theme.violet)
                    }
                }
            }
            .padding(14)
            Divider()
            if model.history.isEmpty {
                ContentUnavailableView {
                    Label("No updates yet", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Every update you run here is listed with its result.")
                }
                .frame(maxHeight: .infinity)
            } else {
                List(model.history, selection: $model.selectedHistory) { entry in
                    HistoryRow(entry: entry).tag(entry.id)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry
    @EnvironmentObject var model: WorkbenchModel
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.result.symbol).font(.title2).foregroundStyle(entry.result.tint).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.appName).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    Pill(text: entry.result.rawValue, symbol: entry.result.symbol, tint: entry.result.tint)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(entry.fromVersion) → \(entry.toVersion)").font(.system(.callout, design: .monospaced).weight(.semibold)).lineLimit(1)
                Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct HistoryDetail: View {
    let entry: HistoryEntry
    @EnvironmentObject var model: WorkbenchModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                HStack(spacing: 14) {
                    Image(systemName: entry.result.symbol).font(.system(size: 30, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 60, height: 60)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(LinearGradient(colors: [entry.result.tint, entry.result.tint.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.appName).font(.title.weight(.bold))
                        Text("\(entry.result.rawValue) · \(entry.date.formatted(date: .complete, time: .shortened))").foregroundStyle(.secondary)
                    }
                }
                Card {
                    HStack(spacing: 14) {
                        version("From", entry.fromVersion, .primary)
                        Image(systemName: "arrow.right").font(.title3.weight(.semibold)).foregroundStyle(Theme.accentGradient)
                        version("To", entry.toVersion, Theme.accent)
                        Spacer()
                    }
                    Text(entry.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                Card(title: "Details", symbol: "info.circle.fill", tint: Theme.indigo) {
                    InfoRow(label: "Source", value: entry.source)
                    if let bundle = entry.bundleID { InfoRow(label: "Bundle ID", value: bundle, monospaced: true) }
                    if let path = entry.appPath { InfoRow(label: "Location", value: abbreviatedPath(path)) }
                }
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
    private func version(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .monospaced).weight(.semibold)).foregroundStyle(color)
        }
    }
}

// MARK: Menu bar

struct MenuBarLabel: View {
    let count: Int
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: count > 0 ? "arrow.down.circle.fill" : "arrow.triangle.2.circlepath")
            if count > 0 { Text("\(count)").monospacedDigit() }
        }
        .accessibilityLabel(count > 0 ? "Update Workbench, \(count) updates" : "Update Workbench")
    }
}

struct MenuBarPanel: View {
    @EnvironmentObject var model: WorkbenchModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let updates = model.updates.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(HeroSummary.title(updates: updates.count, scanned: model.scanned)).font(.headline).foregroundStyle(.white)
                    Text(statusLine).font(.caption).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small).tint(.white) }
                else { Image(systemName: updates.isEmpty ? "checkmark.seal.fill" : "arrow.down.circle.fill").font(.title2).foregroundStyle(.white.opacity(0.9)) }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(!model.scanned ? Theme.idleGradient : (updates.isEmpty ? Theme.successGradient : Theme.accentGradient)))
            if !updates.isEmpty {
                VStack(spacing: 2) {
                    ForEach(updates.prefix(6)) { item in
                        Button { open(item) } label: {
                            HStack(spacing: 10) {
                                AppIconView(item: item, size: 26)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name).font(.callout.weight(.semibold)).lineLimit(1)
                                    Text("\(item.installedVersion) → \(item.latestVersion ?? "")").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                SourceBadge(provider: item.provider)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Show \(item.name) in Update Workbench")
                    }
                    if updates.count > 6 {
                        Text("+ \(updates.count - 6) more").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 6)
                    }
                }
            }
            HStack(spacing: 8) {
                Button { model.scan() } label: { Label("Check Now", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderedProminent).disabled(model.busy)
                Button { openMain() } label: { Label("Open Update Workbench", systemImage: "macwindow") }
                Spacer(minLength: 0)
            }
            .controlSize(.regular)
            Divider()
            HStack(spacing: 10) {
                Label(model.schedule == .off ? "Automatic checks off" : "Checks \(model.schedule.rawValue.lowercased())", systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.borderless).help("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.buttonStyle(.borderless).help("Quit Update Workbench")
            }
            Text("Nothing installs automatically. Every update asks first.").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(width: 340)
    }
    private var statusLine: String {
        if model.busy { return model.operation }
        guard let last = model.lastCheck ?? model.lastScheduledCheck else { return "Not checked yet" }
        return "Last check \(last.formatted(.relative(presentation: .named)))"
    }
    private func openMain() {
        openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
    }
    private func open(_ item: UpdateItem) {
        model.section = .updates; model.selected = item.id; openMain()
    }
}
