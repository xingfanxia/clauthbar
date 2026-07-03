// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "clauthbar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "clauthbar",
            path: "Sources/clauthbar"
        )
    ]
)
