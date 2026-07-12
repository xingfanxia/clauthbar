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
        // Neutral demo profiles for public README media (see Fixtures header): three
        // anthropic accounts, account-3 marked last_resort so the flag badge shows.
        XCTAssertEqual(status.activeProfile, "account-1")
        XCTAssertEqual(status.fallbackChain, ["account-1", "account-2", "account-3"])
        XCTAssertEqual(status.profiles.count, 3)
        XCTAssertTrue(status.profiles.allSatisfy { $0.provider == "anthropic" },
                      "public media fixture stays brand-free (all anthropic)")
        // Current daemon output (clauth 81c00a2+): published forecast + burn_aware.
        XCTAssertEqual(status.forecast?.action, "switch")
        XCTAssertEqual(status.forecast?.to, "account-2")
        XCTAssertEqual(status.forecast?.outcome, .switchTo("account-2"))
        XCTAssertEqual(status.burnAware, false)
        XCTAssertEqual(status.weeklySwitchThreshold, 98.0)
        XCTAssertEqual(status.profiles.first { $0.name == "account-1" }?.fallback?.lastResort, false)
        // account-3 is the chain tail marked last resort — exercises the flag badge.
        XCTAssertEqual(status.profiles.first { $0.name == "account-3" }?.fallback?.lastResort, true)
        // CAP-3 account_email: present decodes verbatim; absent (older daemon /
        // not yet backfilled — account-3) stays nil, never a decode failure.
        XCTAssertEqual(
            status.profiles.first { $0.name == "account-1" }?.accountEmail,
            "alpha@example.com"
        )
        XCTAssertNil(status.profiles.first { $0.name == "account-3" }?.accountEmail)
    }

    // MARK: Additive forecast fields (clauth 81c00a2) — present AND absent decode.

    func testForecastBurnAwareAndLastResortDecodeWhenPresent() throws {
        let status = try decode(#"""
        {"schema":1,"generated_at":"2026-07-04T05:00:00+00:00","active_profile":"a",
         "wrap_off":false,"refresh_interval_ms":90000,"burn_aware":true,
         "forecast":{"action":"switch","to":"b"},
         "fallback_chain":["a","b"],
         "profiles":[{"name":"a","active":true,
            "fallback":{"position":1,"threshold":95,"armed":true,"last_resort":true}},
                     {"name":"b","active":false,
            "fallback":{"position":2,"threshold":100,"armed":false,"last_resort":false}}]}
        """#)
        XCTAssertEqual(status.burnAware, true)
        XCTAssertEqual(status.forecast?.action, "switch")
        XCTAssertEqual(status.forecast?.to, "b")
        XCTAssertEqual(status.forecast?.outcome, .switchTo("b"))
        XCTAssertEqual(status.profiles.first { $0.name == "a" }?.fallback?.lastResort, true)
        XCTAssertEqual(status.profiles.first { $0.name == "b" }?.fallback?.lastResort, false)
    }

    func testAdditiveForecastFieldsAbsentDecodeBackCompat() throws {
        // An OLDER daemon that predates these fields: forecast/burnAware are nil,
        // and a fallback object with no `last_resort` decodes as false — the panel
        // must still read it (never a blank panel over an old daemon).
        let status = try decode(#"""
        {"schema":1,"generated_at":"2026-07-04T05:00:00+00:00","active_profile":"a",
         "wrap_off":false,"refresh_interval_ms":90000,"fallback_chain":["a"],
         "profiles":[{"name":"a","active":true,
            "fallback":{"position":1,"threshold":95,"armed":true}}]}
        """#)
        XCTAssertNil(status.forecast)
        XCTAssertNil(status.burnAware)
        XCTAssertEqual(status.profiles.first?.fallback?.lastResort, false)
    }

    func testForecastOffAndNoneMapToOutcomes() throws {
        for (action, expected) in [("off", ForecastEngine.Outcome.off),
                                   ("none", ForecastEngine.Outcome.none)] {
            let status = try decode("""
            {"schema":1,"generated_at":"2026-07-04T05:00:00+00:00","active_profile":"a",
             "wrap_off":true,"refresh_interval_ms":90000,
             "forecast":{"action":"\(action)","to":null},"profiles":[{"name":"a","active":true}]}
            """)
            XCTAssertEqual(status.forecast?.outcome, expected, "action \(action)")
        }
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

    // MARK: third-party (api-key) decode coverage — kept inline since the bundled
    // fixture stays all-anthropic (public media is brand-free). `"custom"` is a
    // neutral stand-in for a recognised third-party provider's display name, which
    // clauth emits verbatim; the SHAPE (base_url + `third_party.available` + null
    // tier + no fallback/windows) is the faithful part.

    func testThirdPartyProfileDecodes() throws {
        let status = try decode(#"""
        {"schema":1,"generated_at":"2026-07-04T05:00:00+00:00","active_profile":null,
         "wrap_off":false,"refresh_interval_ms":90000,
         "profiles":[{"name":"proxy","active":false,"provider":"custom","tier":null,
                      "base_url":"https://llm.internal.example",
                      "third_party":{"available":false}}]}
        """#)
        let p = try XCTUnwrap(status.profiles.first)
        XCTAssertEqual(p.provider, "custom")
        XCTAssertEqual(p.baseUrl, "https://llm.internal.example")
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
