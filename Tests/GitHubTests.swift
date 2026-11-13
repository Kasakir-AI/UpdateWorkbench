import Foundation
@testable import UpdateWorkbench

/// Offline fixtures; invoke run() from the repository's backend test entry point.
enum GitHubTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func run() throws {
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw Failure(description: message) }
        }
        func asset(_ name: String, repository: String = "owner/repo") -> [String: Any] {
            ["name": name, "browser_download_url": "https://github.com/\(repository)/releases/download/v2.0/\(name)", "state": "uploaded"]
        }
        func metadata(_ assets: [[String: Any]], tag: String = "v2.0", prerelease: Bool = false, draft: Bool = false,
                      page: String = "https://github.com/owner/repo/releases/tag/v2.0") throws -> Data {
            try JSONSerialization.data(withJSONObject: ["tag_name": tag, "html_url": page, "draft": draft, "prerelease": prerelease, "assets": assets])
        }
        try expect(GitHubBackend.validRepository("owner/my-app"), "Normal owner/repo must validate")
        for invalid in ["owner", "../repo", "owner/repo.git", "owner/repo?x", "https://github.com/owner/repo", "owner/repo/extra", "-owner/repo", "owner/", "owner/é"] {
            try expect(!GitHubBackend.validRepository(invalid), "Unsafe repository must be rejected: \(invalid)")
        }
        let payload = try metadata([asset("App-macos-arm64.dmg"), asset("App-macos-x64.zip"), asset("App-linux-arm64.zip")])
        let arm = try GitHubBackend.parseRelease(payload, repository: "owner/repo", installedVersion: "1.0", architecture: "arm64")
        try expect(arm?.version == "2.0" && arm?.downloadURL?.lastPathComponent == "App-macos-arm64.dmg", "Native macOS payload and normalized tag must match")
        let intel = try GitHubBackend.parseRelease(payload, repository: "owner/repo", installedVersion: "1.0", architecture: "x86_64")
        try expect(intel?.downloadURL?.lastPathComponent == "App-macos-x64.zip", "Intel payload must be selected separately")
        let ambiguous = try GitHubBackend.parseRelease(metadata([asset("App-macos-arm64.dmg"), asset("App-macos-arm64.zip")]), repository: "owner/repo", installedVersion: "1", architecture: "arm64")
        try expect(ambiguous?.downloadURL?.lastPathComponent == "App-macos-arm64.dmg", "A single native DMG must win over a ZIP")
        let twoDMGs = try GitHubBackend.parseRelease(metadata([asset("App-macos-arm64.dmg"), asset("App-macos-universal.dmg")]), repository: "owner/repo", installedVersion: "1", architecture: "arm64")
        try expect(twoDMGs?.downloadURL == nil && twoDMGs?.version == "2.0", "Ambiguous assets must leave a manual release-page choice")
        let noCPU = try GitHubBackend.parseRelease(metadata([asset("App.dmg")]), repository: "owner/repo", installedVersion: "1", architecture: "arm64")
        try expect(noCPU?.downloadURL == nil, "Unknown CPU assets must not enable direct installation")
        let same = try GitHubBackend.parseRelease(payload, repository: "owner/repo", installedVersion: "2.0", architecture: "arm64")
        try expect(same == nil, "Latest installed version must not be offered again")
        let pre = try GitHubBackend.parseRelease(metadata([], prerelease: true), repository: "owner/repo", installedVersion: "1")
        let draft = try GitHubBackend.parseRelease(metadata([], draft: true), repository: "owner/repo", installedVersion: "1")
        try expect(pre == nil && draft == nil, "Prereleases and drafts must be excluded")
        let foreign = try GitHubBackend.parseRelease(metadata([asset("App-macos-arm64.dmg", repository: "other/repo")]), repository: "owner/repo", installedVersion: "1", architecture: "arm64")
        try expect(foreign?.downloadURL == nil, "Foreign repository assets must not become direct downloads")
        var badPageRejected = false
        do { _ = try GitHubBackend.parseRelease(metadata([], page: "https://example.com/fake"), repository: "owner/repo", installedVersion: "1") }
        catch { badPageRejected = true }
        try expect(badPageRejected, "Foreign release pages must be rejected")
        var invalidVersionRejected = false
        do { _ = try GitHubBackend.parseRelease(metadata([], tag: "nightly"), repository: "owner/repo", installedVersion: "1") }
        catch { invalidVersionRejected = true }
        try expect(invalidVersionRejected, "Uncomparable release versions must stay unknown")
        let release = GitHubRelease(version: "2", releasePageURL: URL(string: "https://github.com/owner/repo/releases/tag/v2")!, downloadURL: URL(string: "https://github.com/owner/repo/releases/download/v2/App-arm64.dmg")!)
        let signed = UpdateItem(id: "fixture", name: "Fixture", path: "/tmp/Fixture.app", installedVersion: "1", latestVersion: "2", provider: .github, isOutdated: true, githubRepository: "owner/repo", githubRelease: release, requiresSparkleSignature: true)
        try expect(!signed.canUpdateDirectly, "A required Sparkle signature must prevent unsigned GitHub archive installation")
        var direct = signed; direct.requiresSparkleSignature = false
        try expect(direct.canUpdateDirectly, "Only a complete explicitly selected GitHub release can expose direct installation")
        let decoded = try JSONDecoder().decode(UpdateItem.self, from: JSONEncoder().encode(direct))
        try expect(decoded.githubRepository == "owner/repo" && decoded.githubRelease?.version == "2", "GitHub inventory fields must survive JSON roundtrip")
        print("PASS: GitHub repository validation, release selection, architecture/ambiguity, signature requirements, serialization")
    }
}
