import Testing

/// The offline suites, one test each. They run one after another: several share fixture folders,
/// disk image mounts and UserDefaults keys.
@Suite(.serialized)
struct OfflineSuites {
    @Test func gitHub() throws { try GitHubTests.run() }
    @Test func features() async throws { try await FeatureTests.run() }
    @Test func presentation() throws { try PresentationTests.run() }
    @Test func archiveSafety() throws { try ArchiveSafetyTests.run() }
    @Test func workflow() throws { try WorkflowTests.run() }
    @Test func diskImages() async throws { try await DiskImageTests.run() }
    @Test func backend() async throws { try await BackendTests.run() }
    @Test func security() async throws { try await SecurityTests.run() }
}
