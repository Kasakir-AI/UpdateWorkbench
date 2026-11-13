import Foundation
@testable import UpdateWorkbench

/// Symlink-aware ZIP validation: fixture archives are built in a temporary folder with /usr/bin/zip and ditto.
enum ArchiveSafetyTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func expect(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description: message) } }
    static func expectRejected(_ message: String, contains fragment: String = "", _ body: () throws -> Void) throws {
        do { try body() } catch {
            try expect(fragment.isEmpty || error.localizedDescription.contains(fragment), "\(message): unexpected error \(error.localizedDescription)")
            return
        }
        throw Failure(description: message)
    }

    static func run() throws {
        try listingRules()
        let fm = FileManager.default
        let work = TestTemp.root.appendingPathComponent("archive-safety-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        try fixtures(in: work)
        print("PASS: archive safety (framework links accepted, absolute/escaping/write-through/hard links rejected, DMG preference)")
    }

    static func listingRules() throws {
        typealias E = ArchiveSafety.Entry
        let safe: [E] = [
            E(path: "Demo.app/", kind: .directory, linkTarget: nil),
            E(path: "Demo.app/Contents/Frameworks/Kit.framework/Versions/A/Kit", kind: .file, linkTarget: nil, uncompressedSize: 10),
            E(path: "Demo.app/Contents/Frameworks/Kit.framework/Versions/Current", kind: .symlink, linkTarget: "A"),
            E(path: "Demo.app/Contents/Frameworks/Kit.framework/Kit", kind: .symlink, linkTarget: "Versions/Current/Kit"),
            E(path: "Demo.app/Contents/Resources/shared", kind: .symlink, linkTarget: "../Frameworks/./Kit.framework"),
        ]
        try ArchiveSafety.validate(safe)
        try expectRejected("Absolute link targets must be rejected", contains: "absolute") {
            try ArchiveSafety.validate(safe + [E(path: "Demo.app/Contents/evil", kind: .symlink, linkTarget: "/etc")])
        }
        try expectRejected("Home-relative link targets must be rejected", contains: "absolute") {
            try ArchiveSafety.validate([E(path: "Demo.app/Contents/evil", kind: .symlink, linkTarget: "~/Library")])
        }
        try expectRejected("Links escaping the bundle must be rejected", contains: "outside the app bundle") {
            try ArchiveSafety.validate([E(path: "Demo.app/Contents/evil", kind: .symlink, linkTarget: "../../Other.app")])
        }
        try expectRejected("Transient escapes must be rejected", contains: "outside the app bundle") {
            try ArchiveSafety.validate([E(path: "Demo.app/Contents/evil", kind: .symlink, linkTarget: "../../Demo.app/Contents")])
        }
        try ArchiveSafety.validate([E(path: "Demo.app/Contents/root", kind: .symlink, linkTarget: "..")])
        try expectRejected("Links outside any app bundle must be rejected", contains: "not inside an app bundle") {
            try ArchiveSafety.validate([E(path: "README-link", kind: .symlink, linkTarget: "Demo.app")])
        }
        try expectRejected("The bundle itself must not be a link") {
            try ArchiveSafety.validate([E(path: "Demo.app", kind: .symlink, linkTarget: "Other.app")])
        }
        try expectRejected("Entries below a link must be rejected", contains: "written through") {
            try ArchiveSafety.validate([E(path: "Demo.app/Contents/dir", kind: .symlink, linkTarget: "MacOS"),
                                        E(path: "Demo.app/Contents/DIR/payload", kind: .file, linkTarget: nil)])
        }
        try expectRejected("Path traversal must be rejected", contains: "safe relative path") {
            try ArchiveSafety.validate([E(path: "Demo.app/../../escape", kind: .file, linkTarget: nil)])
        }
        try expectRejected("Absolute entry paths must be rejected", contains: "safe relative path") {
            try ArchiveSafety.validate([E(path: "/Applications/Demo.app/x", kind: .file, linkTarget: nil)])
        }
        try expectRejected("Hard links and special files must be rejected", contains: "hard link") {
            try ArchiveSafety.validate([E(path: "Demo.app/Contents/fifo", kind: .special, linkTarget: nil)])
        }
        try expectRejected("Case-folded duplicates must be rejected", contains: "more than once") {
            try ArchiveSafety.validate([E(path: "Demo.app/a", kind: .file, linkTarget: nil), E(path: "Demo.app/A", kind: .symlink, linkTarget: "b")])
        }
        try expectRejected("Encrypted entries must be rejected", contains: "encrypted") {
            try ArchiveSafety.validate([E(path: "Demo.app/a", kind: .file, linkTarget: nil, uncompressedSize: 1, encrypted: true)])
        }
        try expectRejected("Expansion beyond 4 GB must be rejected", contains: "4 GB") {
            try ArchiveSafety.validate([E(path: "Demo.app/a", kind: .file, linkTarget: nil, uncompressedSize: 3_000_000_000),
                                        E(path: "Demo.app/b", kind: .file, linkTarget: nil, uncompressedSize: 3_000_000_000)])
        }
    }

    @discardableResult
    static func shell(_ tool: String, _ arguments: [String], in directory: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Builds Demo.app with an Electron-style nested framework (Versions/Current -> A and top-level links).
    static func makeApp(in folder: URL) throws -> URL {
        let fm = FileManager.default
        let app = folder.appendingPathComponent("Demo.app", isDirectory: true)
        let framework = app.appendingPathComponent("Contents/Frameworks/Kit Framework.framework", isDirectory: true)
        let version = framework.appendingPathComponent("Versions/A", isDirectory: true)
        try fm.createDirectory(at: version.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try fm.createDirectory(at: version.appendingPathComponent("Helpers/Helper.app/Contents"), withIntermediateDirectories: true)
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: version.appendingPathComponent("Kit Framework"))
        try Data("plist".utf8).write(to: version.appendingPathComponent("Resources/Info.plist"))
        try Data("main".utf8).write(to: app.appendingPathComponent("Contents/MacOS/Demo"))
        try fm.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        try fm.createSymbolicLink(atPath: framework.appendingPathComponent("Kit Framework").path, withDestinationPath: "Versions/Current/Kit Framework")
        try fm.createSymbolicLink(atPath: framework.appendingPathComponent("Resources").path, withDestinationPath: "Versions/Current/Resources")
        try fm.createSymbolicLink(atPath: framework.appendingPathComponent("Helpers").path, withDestinationPath: "Versions/Current/Helpers")
        return app
    }

    static func fixtures(in work: URL) throws {
        let fm = FileManager.default
        // 1. Safe nested framework layout, archived by both zip -y and ditto.
        let source = work.appendingPathComponent("safe-src", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        _ = try makeApp(in: source)
        let zipped = work.appendingPathComponent("safe-zip.zip"), dittoed = work.appendingPathComponent("safe-ditto.zip")
        try expect(try shell("/usr/bin/zip", ["-q", "-r", "-y", zipped.path, "Demo.app"], in: source) == 0, "zip fixture")
        try expect(try shell("/usr/bin/ditto", ["-c", "-k", "--keepParent", "Demo.app", dittoed.path], in: source) == 0, "ditto fixture")
        for archive in [zipped, dittoed] {
            let entries = try ArchiveSafety.entries(inZIP: archive)
            let links = entries.filter { $0.kind == .symlink }
            try expect(links.count == 4, "\(archive.lastPathComponent): four framework links must be listed, got \(links.count)")
            try expect(links.contains { $0.path.hasSuffix("Versions/Current") && $0.linkTarget == "A" }, "Versions/Current target must be read")
            try expect(links.contains { $0.linkTarget == "Versions/Current/Kit Framework" }, "Link targets with spaces must be read")
            let out = work.appendingPathComponent("out-\(archive.deletingPathExtension().lastPathComponent)", isDirectory: true)
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
            try ArchiveSafety.extractZIP(archive, to: out)
            let app = out.appendingPathComponent("Demo.app")
            try ArchiveSafety.validateExtracted(app: app, rejectHardLinks: true)
            let current = app.appendingPathComponent("Contents/Frameworks/Kit Framework.framework/Versions/Current").path
            try expect((try? fm.destinationOfSymbolicLink(atPath: current)) == "A", "Extraction must keep Versions/Current as a link")
            let binary = app.appendingPathComponent("Contents/Frameworks/Kit Framework.framework/Kit Framework").path
            try expect((try? String(contentsOfFile: binary, encoding: .utf8)) == "binary", "Framework links must resolve after extraction")
            try expectRejected("Extraction must require an empty folder", contains: "empty") { try ArchiveSafety.extractZIP(archive, to: out) }
        }

        // 2. Absolute link inside the bundle.
        let absolute = work.appendingPathComponent("absolute-src", isDirectory: true)
        let absoluteApp = try makeApp(in: absolute)
        try fm.createSymbolicLink(atPath: absoluteApp.appendingPathComponent("Contents/Resources").path, withDestinationPath: "/etc")
        let absoluteZip = work.appendingPathComponent("absolute.zip")
        try expect(try shell("/usr/bin/zip", ["-q", "-r", "-y", absoluteZip.path, "Demo.app"], in: absolute) == 0, "zip fixture")
        let absoluteOut = work.appendingPathComponent("absolute-out", isDirectory: true)
        try fm.createDirectory(at: absoluteOut, withIntermediateDirectories: true)
        try expectRejected("An absolute link in a ZIP must be rejected", contains: "absolute location") { try ArchiveSafety.extractZIP(absoluteZip, to: absoluteOut) }
        try expect((try fm.contentsOfDirectory(atPath: absoluteOut.path)).isEmpty, "A rejected ZIP must not write anything")
        try expectRejected("An absolute link on disk must be rejected", contains: "absolute target") {
            try ArchiveSafety.validateExtracted(app: absoluteApp, rejectHardLinks: true)
        }

        // 3. Relative link escaping the bundle.
        let escaping = work.appendingPathComponent("escape-src", isDirectory: true)
        let escapingApp = try makeApp(in: escaping)
        try fm.createSymbolicLink(atPath: escapingApp.appendingPathComponent("Contents/MacOS/data").path, withDestinationPath: "../../../outside")
        try Data("x".utf8).write(to: escaping.appendingPathComponent("outside"))
        let escapingZip = work.appendingPathComponent("escape.zip")
        try expect(try shell("/usr/bin/zip", ["-q", "-r", "-y", escapingZip.path, "Demo.app"], in: escaping) == 0, "zip fixture")
        let escapingOut = work.appendingPathComponent("escape-out", isDirectory: true)
        try fm.createDirectory(at: escapingOut, withIntermediateDirectories: true)
        try expectRejected("An escaping link in a ZIP must be rejected", contains: "outside the app bundle") { try ArchiveSafety.extractZIP(escapingZip, to: escapingOut) }
        try expectRejected("An escaping link on disk must be rejected", contains: "outside its bundle") {
            try ArchiveSafety.validateExtracted(app: escapingApp, rejectHardLinks: true)
        }

        // 4. Hard links and broken links on disk.
        let hard = work.appendingPathComponent("hard-src", isDirectory: true)
        let hardApp = try makeApp(in: hard)
        try fm.linkItem(at: hardApp.appendingPathComponent("Contents/MacOS/Demo"), to: hardApp.appendingPathComponent("Contents/MacOS/Copy"))
        try expectRejected("Hard links from a ZIP must be rejected", contains: "hard link") { try ArchiveSafety.validateExtracted(app: hardApp, rejectHardLinks: true) }
        try ArchiveSafety.validateExtracted(app: hardApp, rejectHardLinks: false)
        let broken = work.appendingPathComponent("broken-src", isDirectory: true)
        let brokenApp = try makeApp(in: broken)
        try fm.createSymbolicLink(atPath: brokenApp.appendingPathComponent("Contents/missing").path, withDestinationPath: "MacOS/none")
        try expectRejected("Broken links must be rejected", contains: "broken") { try ArchiveSafety.validateExtracted(app: brokenApp, rejectHardLinks: true) }

        // 5. Not a ZIP.
        let junk = work.appendingPathComponent("junk.zip")
        try Data(repeating: 7, count: 100).write(to: junk)
        try expectRejected("Non-ZIP data must be rejected", contains: "not a valid ZIP") { _ = try ArchiveSafety.entries(inZIP: junk) }
    }
}
