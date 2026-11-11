// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "UpdateWorkbench", platforms: [.macOS(.v14)], products: [.executable(name: "UpdateWorkbench", targets: ["UpdateWorkbench"])], targets: [.executableTarget(name: "UpdateWorkbench")])
