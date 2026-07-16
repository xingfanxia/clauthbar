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
                // Provider brand glyphs (from steipete/CodexBar, MIT — see
                // Resources/ICONS-ATTRIBUTION.md). Unlike the dev-only fixtures,
                // these DO ship: package_app.sh copies them into the .app's
                // Contents/Resources; ProviderGlyph loads Bundle.main first.
                .copy("Resources/ProviderIcon-codex.svg"),
                .copy("Resources/ProviderIcon-claude.svg"),
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
