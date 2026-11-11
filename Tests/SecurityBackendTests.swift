import Foundation

@main struct SecurityTests {
    static func main() async throws {
        let report = SecurityBackend.report(path: "/tmp/fixture.app", observedAt: "fixture", metadata: .init(status: 0, text: "Executable=/private/secret\nIdentifier=example.app\nTeamIdentifier=TEAM\nAuthority=Developer ID Application: Example\nCodeDirectory v=20500 flags=0x10000(runtime)"), verification: .init(status: 0, text: ""), gatekeeper: .init(status: 3, text: "rejected"))
        precondition(report.summary.contains("Code signature verifies"))
        precondition(report.summary.contains("Gatekeeper did not accept (exit 3)"))
        precondition(report.details.contains("TeamIdentifier=TEAM"))
        precondition(!report.details.contains("Executable=/private/secret"))
        precondition(report.details.contains("flags=0x10000(runtime)"))
        let unavailable = SecurityBackend.report(path: "/tmp/fixture.app", observedAt: "fixture", metadata: .init(status: nil, text: "launch failed"), verification: .init(status: nil, text: "timed out"), gatekeeper: .init(status: nil, text: "unavailable"))
        precondition(unavailable.summary.contains("Unavailable"))
        precondition(unavailable.details.contains("timed out"))
        let invalid = await SecurityBackend.inspect(path: "relative.app")
        precondition(invalid.summary == "Security inspection unavailable")
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(SecurityReport.self, from: data)
        precondition(decoded.summary == report.summary)
        print("PASS: security result separation, identity filtering, unavailable states, invalid paths, Codable")
    }
}
