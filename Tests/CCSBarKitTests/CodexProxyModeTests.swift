import XCTest

@testable import CCSBarKit

/// PROXY-1: the pure config.toml transforms behind the codex "Proxy mode"
/// toggle. IO, launchctl, and the port probe stay untested here — these pin
/// the text surgery, which is the part that touches a file two other parties
/// (codex itself, zylos) also read.
final class CodexProxyModeTests: XCTestCase {
    /// The real file's shape in miniature: comments, top-level scalars,
    /// tables — and no model_provider anywhere.
    private let direct = """
        # Codex global config.
        approval_policy = "never"
        model = "gpt-5.6-sol"

        [projects."/Users/x/zylos"]
        trust_level = "trusted"
        """

    func testDirectConfigIsNotRouted() {
        XCTAssertFalse(CodexProxyMode.isRouted(config: direct))
        XCTAssertFalse(CodexProxyMode.hasProviderBlock(config: direct))
    }

    func testEnableInsertsRoutingLineAndProviderBlock() {
        let on = CodexProxyMode.setRouting(config: direct, on: true)
        XCTAssertTrue(CodexProxyMode.isRouted(config: on))
        XCTAssertTrue(CodexProxyMode.hasProviderBlock(config: on))
        // The routing line lands at TOP LEVEL — before the first table header.
        let firstTable = on.range(of: "[projects.")!.lowerBound
        let providerLine = on.range(of: "model_provider = \"clauth\"")!.lowerBound
        XCTAssertLessThan(providerLine, firstTable)
        // Untouched content survives byte-for-byte.
        XCTAssertTrue(on.contains("approval_policy = \"never\""))
        XCTAssertTrue(on.contains("trust_level = \"trusted\""))
    }

    func testEnableReplacesExistingTopLevelProvider() {
        let other = "model_provider = \"openai\"\n" + direct
        let on = CodexProxyMode.setRouting(config: other, on: true)
        XCTAssertTrue(CodexProxyMode.isRouted(config: on))
        XCTAssertFalse(on.contains("model_provider = \"openai\""))
        // Replaced in place, not duplicated: exactly one routing LINE.
        let routingLines = on.components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("model_provider =") }
        XCTAssertEqual(routingLines, ["model_provider = \"clauth\""])
    }

    func testDisableRemovesOnlyTheClauthRoutingLine() {
        let on = CodexProxyMode.setRouting(config: direct, on: true)
        let off = CodexProxyMode.setRouting(config: on, on: false)
        XCTAssertFalse(CodexProxyMode.isRouted(config: off))
        // The definition block STAYS — proxy-era sessions resume through it.
        XCTAssertTrue(CodexProxyMode.hasProviderBlock(config: off))
        XCTAssertTrue(off.contains("approval_policy = \"never\""))
    }

    func testDisableLeavesForeignProviderAlone() {
        let foreign = "model_provider = \"my-relay\"\n" + direct
        let off = CodexProxyMode.setRouting(config: foreign, on: false)
        XCTAssertTrue(off.contains("model_provider = \"my-relay\""))
    }

    func testTableScopedProviderKeyIsNotTopLevel() {
        // A `model_provider` INSIDE a table (e.g. a profile overlay pasted
        // into a section) must not read as global routing.
        let scoped = direct + "\n[profiles.p]\nmodel_provider = \"clauth\"\n"
        XCTAssertFalse(CodexProxyMode.isRouted(config: scoped))
    }

    func testCommentedRoutingLineDoesNotCount() {
        // The live 2026-07-18 shape: zylos neutralized the block by
        // commenting it out — that must read as OFF, and re-enabling must
        // produce a real routing line.
        let commented = direct + "\n# model_provider = \"clauth\"\n# [model_providers.clauth]\n"
        XCTAssertFalse(CodexProxyMode.isRouted(config: commented))
        XCTAssertFalse(CodexProxyMode.hasProviderBlock(config: commented))
        XCTAssertTrue(CodexProxyMode.isRouted(config: CodexProxyMode.setRouting(config: commented, on: true)))
    }

    func testRoundTripIsStable() {
        let on = CodexProxyMode.setRouting(config: direct, on: true)
        let off = CodexProxyMode.setRouting(config: on, on: false)
        let on2 = CodexProxyMode.setRouting(config: off, on: true)
        XCTAssertTrue(CodexProxyMode.isRouted(config: on2))
        // Block is not duplicated on re-enable.
        XCTAssertEqual(on2.components(separatedBy: "[model_providers.clauth]").count, 2)
    }
}
