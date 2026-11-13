import Foundation
import Testing
@testable import UpdateWorkbench

enum SecurityTests {
    static func run() async throws {
        let report = SecurityBackend.report(path: "/tmp/fixture.app", observedAt: "fixture", metadata: .init(status: 0, text: "Executable=/private/secret\nIdentifier=example.app\nTeamIdentifier=TEAM\nAuthority=Developer ID Application: Example\nCodeDirectory v=20500 flags=0x10000(runtime)"), verification: .init(status: 0, text: ""), gatekeeper: .init(status: 3, text: "rejected"))
        #expect(report.summary.contains("Code signature verifies"))
        #expect(report.summary.contains("Gatekeeper did not accept (exit 3)"))
        #expect(report.details.contains("TeamIdentifier=TEAM"))
        #expect(!report.details.contains("Executable=/private/secret"))
        #expect(report.details.contains("flags=0x10000(runtime)"))
        let unavailable = SecurityBackend.report(path: "/tmp/fixture.app", observedAt: "fixture", metadata: .init(status: nil, text: "launch failed"), verification: .init(status: nil, text: "timed out"), gatekeeper: .init(status: nil, text: "unavailable"))
        #expect(unavailable.summary.contains("Unavailable"))
        #expect(unavailable.details.contains("timed out"))
        let invalid = await SecurityBackend.inspect(path: "relative.app")
        #expect(invalid.summary == "Security inspection unavailable")
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(SecurityReport.self, from: data)
        #expect(decoded.summary == report.summary)
        print("PASS: security result separation, identity filtering, unavailable states, invalid paths, Codable")
    }
}
