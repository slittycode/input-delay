// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "latbudget",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "latbudget", path: "Sources/latbudget")
    ]
)
