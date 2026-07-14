// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "lagtrack",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "lagtrack", path: "Sources/lagtrack")
    ]
)
