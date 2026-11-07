// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "BlueFatFishMCP",
    platforms: [.macOS(.v14)],
    products: [.library(name: "BlueFatFishMCP", type: .dynamic, targets: ["BlueFatFishMCP"])],
    dependencies: [.package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"), .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0")],
    targets: [.target(name: "BlueFatFishMCP", dependencies: [.product(name: "MCP", package: "swift-sdk"), .product(name: "Logging", package: "swift-log")])]
)
