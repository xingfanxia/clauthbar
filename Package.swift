// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ccsbar",
    platforms: [.macOS(.v14)],
    targets: [
        // All app logic lives in the library so the test target can
        // `@testable import CCSBarKit` and exercise the pure, regression-prone
        // functions (parseISO / resetHint / usageColor / fableWeek / decode) that
        // the executable alone couldn't expose to tests.
        .target(
            name: "CCSBarKit",
            path: "Sources/CCSBarKit",
            resources: [
                .copy("Fixtures/status.json"),
                .copy("Fixtures/tokens.json"),
            ]
        ),
        // The thin executable: just `@main` → `runCCSBar()`.
        .executableTarget(
            name: "ccsbar",
            dependencies: ["CCSBarKit"],
            path: "Sources/ccsbar"
        ),
        .testTarget(
            name: "CCSBarKitTests",
            dependencies: ["CCSBarKit"],
            path: "Tests/CCSBarKitTests"
        ),
    ]
)
