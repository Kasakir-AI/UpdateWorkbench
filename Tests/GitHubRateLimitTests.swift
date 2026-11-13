import Foundation
import Testing
@testable import UpdateWorkbench

struct GitHubRateLimitTests {
    let latest = URL(string: "https://api.github.com/repos/example/app/releases/latest")!

    @Test func explainsTheRateLimit() throws {
        func response(_ status: Int, _ headers: [String: String]) throws -> HTTPURLResponse {
            try #require(HTTPURLResponse(url: latest, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers))
        }
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let limited = GitHubBackend.rateLimitMessage(try response(403, ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1800000000"]))
        #expect(limited.contains("60 checks an hour"))
        #expect(limited.contains(reset.formatted(date: .omitted, time: .shortened)))
        #expect(GitHubBackend.rateLimitMessage(try response(429, [:])).contains("Try again later"))
        #expect(GitHubBackend.rateLimitMessage(try response(403, ["x-ratelimit-remaining": "41"])).contains("refused"))
    }
}
