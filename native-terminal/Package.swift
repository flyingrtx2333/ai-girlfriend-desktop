// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "BlueFatFishTerminal",
    platforms: [.macOS(.v14)],
    products: [.library(name: "BlueFatFishTerminal", type: .dynamic, targets: ["BlueFatFishTerminal"])],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.19.0")],
    targets: [
        .target(name: "TerminalPTY"),
        .target(name: "BlueFatFishTerminal", dependencies: ["TerminalPTY", .product(name: "SwiftTerm", package: "SwiftTerm")]),
    ],
    swiftLanguageModes: [.v5]
)
