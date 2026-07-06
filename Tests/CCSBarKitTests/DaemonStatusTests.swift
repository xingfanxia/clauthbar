import Foundation
import XCTest

@testable import CCSBarKit

/// The cross-repo contract: the checked-in `status.json` fixture (the same one the
/// `--snapshot` render uses) must decode through `DaemonStatus`. If the Rust
/// serializer changes shape, this test fails before the change can blank the panel
/// in the field. Plus the leniency guarantees an additive-era daemon relies on.
final class DaemonStatusTests: XCTestCase {
    private func decode(_ json: String) throws -> DaemonStatus {
        try JSONDecoder().decode(DaemonStatus.self, from: Data(json.utf8))
    }

    // MARK: Contract — the bundled fixture decodes and matches known values.

    func testBundledFixtureDecodes() throws {
        let data = try XCTUnwrap(Fixtures.statusJSONData(), "fixture resource must be bundled")
        let status = try JSONDecoder().decode(DaemonStatus.self, from: data)
        XCTAssertEqual(status.schema, 1)
        XCTAssertEqual(status.activeProfile, "xfx")
        XCTAssertEqual(status.fallbackChain, ["xfx", "cl-ax"])
        XCTAssertEqual(status.profiles.count, 3)
        // The third-party profile carries the availability flag (not a balance).
        let zai = try XCTUnwrap(status.profiles.first { $0.name == "zai" })
        XCTAssertEqual(zai.thirdParty?.available, true)
        XCTAssertEqual(zai.provider, "z.ai")
    }

    // MARK: SchemaProbe — reads schema without a full decode (the gate's basis).

    func testSchemaProbeReadsSchemaAloneFromAFutureShape() throws {
        // A schema-2 body with an otherwise-unknown shape still yields its schema.
        let probe = try JSONDecoder().decode(
            SchemaProbe.self,
            from: Data(#"{"schema": 2, "totally": "different"}"#.utf8)
        )
        XCTAssertEqual(probe.schema, 2)
    }

    // MARK: Leniency — additive-era survival.

    func testMissingFallbackChainDecodesAsEmpty() throws {
        let status = try decode(#"""
        {"schema":1,"generated_at":"2026-07-04T05:00:00+00:00","active_profile":null,
         "wrap_off":false,"refresh_interval_ms":90000,"profiles":[]}
        """#)
        XCTAssertEqual(status.fallbackChain, [])
        XCTAssertNil(status.activeProfile)
    }

    func testProfileDecodesWithOnlyNameAndActive() throws {
        // Every non-load-bearing field is absent — must still decode with defaults.
        let status = try decode(#"""
        {"schema":1,"generated_at":"2026-07-04T05:00:00+00:00","active_profile":"a",
         "wrap_off":false,"refresh_interval_ms":90000,
         "profiles":[{"name":"a","active":true}]}
        """#)
        let p = try XCTUnwrap(status.profiles.first)
        XCTAssertEqual(p.name, "a")
        XCTAssertTrue(p.active)
        XCTAssertEqual(p.provider, "anthropic") // default
        XCTAssertNil(p.tier)                     // null tier tolerated
        XCTAssertTrue(p.windows.isEmpty)         // missing windows → empty
        XCTAssertFalse(p.autoStart)
    }

    func testNullTierAndMissingWindowsTolerated() throws {
        let status = try decode(#"""
        {"schema":1,"generated_at":"2026-07-04T05:00:00+00:00","active_profile":"a",
         "wrap_off":false,"refresh_interval_ms":90000,
         "profiles":[{"name":"a","active":false,"provider":"z.ai","tier":null,
                      "third_party":{"available":false}}]}
        """#)
        let p = try XCTUnwrap(status.profiles.first)
        XCTAssertNil(p.tier)
        XCTAssertEqual(p.thirdParty?.available, false)
    }

    // MARK: fableWeek — derived label, matched leniently.

    func testFableWeekMatchesDerivedLabels() throws {
        for label in ["7d fable", "7d fable 5", "7d Fable"] {
            let status = try decode("""
            {"schema":1,"generated_at":"2026-07-04T05:00:00+00:00","active_profile":"a",
             "wrap_off":false,"refresh_interval_ms":90000,
             "profiles":[{"name":"a","active":true,
               "windows":[{"label":"\(label)","utilization_pct":5}]}]}
            """)
            let p = try XCTUnwrap(status.profiles.first)
            XCTAssertNotNil(p.fableWeek, "\(label) must match fableWeek")
        }
    }

    func testFableWeekDoesNotMatchPlainSevenDay() throws {
        let status = try decode(#"""
        {"schema":1,"generated_at":"2026-07-04T05:00:00+00:00","active_profile":"a",
         "wrap_off":false,"refresh_interval_ms":90000,
         "profiles":[{"name":"a","active":true,
           "windows":[{"label":"7d","utilization_pct":5}]}]}
        """#)
        let p = try XCTUnwrap(status.profiles.first)
        XCTAssertNil(p.fableWeek, "plain 7d must NOT be treated as the fable window")
        XCTAssertNotNil(p.sevenDay)
    }
}
