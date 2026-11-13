import Foundation
import Testing
@testable import UpdateWorkbench

struct VersionOrderTests {
    @Test(arguments: [
        ("1.10", "1.9"),
        ("1.0", "1.0-beta.1"),          // the release is newer than its beta
        ("1.0", "1.0b2"),
        ("1.0", "1.0rc1"),
        ("1.0", "1.0 Preview"),
        ("1.0-rc.1", "1.0-beta.2"),
        ("1.0-beta.2", "1.0-beta.1"),
        ("1.0-beta.1", "1.0-beta"),
        ("1.0-beta", "1.0-alpha"),
        ("1.0.1-beta", "1.0"),
        ("1.0 (45)", "1.0"),            // a trailing build number counts after the release
        ("1.0 (46)", "1.0 (45)"),
        ("v2.1", "2.0"),
        ("2026.1", "2025.12.3"),
        ("27.2.1", "15.0"),
        ("1234", "1233"),
    ])
    func newer(_ newer: String, _ older: String) {
        #expect(SparkleBackend.isNewer(newer, than: older), "\(newer) should be newer than \(older)")
        #expect(!SparkleBackend.isNewer(older, than: newer), "\(older) should not be newer than \(newer)")
    }

    @Test(arguments: [
        ("2.0", "2.0.0"),               // trailing zeros are the same version
        ("14", "14.0"),
        ("v1.2.3", "1.2.3"),
        ("1.2.3+sha.5114f85", "1.2.3"), // semver build metadata is ignored
        ("1.0RC1", "1.0rc1"),
        ("1.0rc1", "1.0-rc.1"),
    ])
    func same(_ lhs: String, _ rhs: String) {
        #expect(VersionOrder.isSame(lhs, rhs), "\(lhs) and \(rhs) should be the same version")
        #expect(!SparkleBackend.isNewer(lhs, than: rhs) && !SparkleBackend.isNewer(rhs, than: lhs))
    }

    @Test func unparsableVersionsFallBackToTextOrder() {
        #expect(!VersionOrder.isSame("Unknown", "1.0"))
        #expect(VersionOrder.isSame("Unknown", "unknown"))
        #expect(SparkleBackend.isNewer("99999999999999999999999.1", than: "99999999999999999999999.0"))
    }

    /// Beta testers are offered the final release, and the same version written differently isn't an update.
    @Test func appcastSelection() throws {
        let appcast = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        <item><enclosure url="https://example.com/App-2.0.0.zip" sparkle:shortVersionString="2.0.0"/></item>
        </channel></rss>
        """
        let data = Data(appcast.utf8)
        #expect(try SparkleBackend.parseAppcast(data, installedVersion: "2.0-beta.3")?.version == "2.0.0")
        #expect(try SparkleBackend.parseAppcast(data, installedVersion: "2.0") == nil)
        #expect(try SparkleBackend.parseAppcast(data, installedVersion: "2.0.1") == nil)
    }
}
