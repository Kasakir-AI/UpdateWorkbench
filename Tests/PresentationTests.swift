import Foundation

/// Offline checks for the UI presentation rules (status precedence, hero copy, appearance default, path abbreviation).
enum PresentationTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func expect(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description: message) } }

    static func run() throws {
        try expect(AppearanceMode.stored(nil) == .dark, "Dark is the default appearance")
        try expect(AppearanceMode.stored("garbage") == .dark, "Unknown appearance values fall back to Dark")
        try expect(AppearanceMode.stored("Light") == .light && AppearanceMode.stored("System") == .system, "Stored appearances round-trip")

        let ready = UpdateItem(id: "a", name: "A", installedVersion: "1", latestVersion: "2", provider: .homebrewCask, token: "a", isOutdated: true)
        let manual = UpdateItem(id: "b", name: "B", path: "/Applications/B.app", installedVersion: "1", latestVersion: "2", provider: .vendor, isOutdated: true)
        let current = UpdateItem(id: "c", name: "C", installedVersion: "2", latestVersion: "2", provider: .sparkle)
        let unknown = UpdateItem(id: "d", name: "D", installedVersion: "2", provider: .manual)
        func status(_ item: UpdateItem, ignored: Bool = false, skipped: String? = nil, snoozed: Double? = nil, failure: String? = nil) -> ItemStatus {
            ItemStatus.classify(item, ignored: ignored, skippedVersion: skipped, snoozedUntil: snoozed, failure: failure, now: 1000)
        }
        try expect(status(ready) == .ready, "Direct updates are ready")
        try expect(status(manual) == .manualUpdate, "Outdated vendor apps need a manual update")
        let vendorCurrent = UpdateItem(id: "v", name: "V", installedVersion: "1", provider: .vendor)
        try expect(status(vendorCurrent) == .selfUpdating, "Vendor apps without a known version update themselves")
        try expect(status(current) == .upToDate, "Known latest equal version is up to date")
        try expect(status(unknown) == .unknown, "Manual apps without a feed are not checked")
        try expect(status(ready, failure: "boom") == .failed, "Failures take precedence")
        try expect(status(ready, ignored: true) == .ignored, "Ignored apps show as ignored")
        try expect(status(ready, skipped: "2") == .skipped, "Skipped version shows as skipped")
        try expect(status(ready, skipped: "1.5") == .ready, "Skipping an older version does not hide a newer one")
        try expect(status(ready, snoozed: 2000) == .snoozed && status(ready, snoozed: 500) == .ready, "Snooze expires")
        for value in [ItemStatus.failed, .ready, .manualUpdate, .selfUpdating, .snoozed, .skipped, .ignored, .upToDate, .unknown] {
            try expect(!value.rawValue.isEmpty && !value.symbol.isEmpty, "Every status has text and an icon, not only a color")
        }

        try expect(HeroSummary.title(updates: 0, scanned: false) == "Let's check your apps", "Hero before first scan")
        try expect(HeroSummary.title(updates: 0, scanned: true) == "Everything is up to date", "Hero when current")
        try expect(HeroSummary.title(updates: 1, scanned: true) == "1 update available", "Singular hero")
        try expect(HeroSummary.title(updates: 5, scanned: true) == "5 updates available", "Plural hero")
        try expect(HeroSummary.subtitle(updates: 5, direct: 3, scanned: true, total: 80) == "3 can be installed here · 2 update through their own app", "Hero subtitle splits direct/manual")

        try expect(abbreviatedPath("/Users/someone/Applications/X.app", home: "/Users/someone") == "~/Applications/X.app", "Home is abbreviated")
        try expect(abbreviatedPath("/Users/someoneelse/X.app", home: "/Users/someone") == "/Users/someoneelse/X.app", "Only whole home prefix is abbreviated")
        try expect(abbreviatedPath("/Applications/X.app", home: "/Users/someone") == "/Applications/X.app", "Other paths unchanged")
        try expect(SidebarSection.allCases.allSatisfy { !$0.symbol.isEmpty && !$0.subtitle.isEmpty }, "Sidebar sections have icons and subtitles")
        print("PASS: presentation (appearance default, status precedence, hero copy, path abbreviation)")
    }
}
