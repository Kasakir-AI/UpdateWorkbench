// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "UpdateWorkbench",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "UpdateWorkbench", targets: ["UpdateWorkbench"])],
    targets: [
        .executableTarget(name: "UpdateWorkbench", swiftSettings: [.swiftLanguageMode(.v5)]),
        // `swift test` (or ./test.sh) runs the offline suites against the app module with @testable import.
        .testTarget(name: "UpdateWorkbenchTests", dependencies: ["UpdateWorkbench"], path: "Tests"),
    ]
)
