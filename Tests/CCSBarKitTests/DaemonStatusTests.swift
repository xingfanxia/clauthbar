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
        // anthropic accounts, account-3 marked last_resort so the flag badge shows,
        // plus two codex profiles (INT-2/TABS-1): the two-active-slots case AND a
        // 2-member codex chain so the codex rail renders with a rotation target.
        XCTAssertEqual(status.activeProfile, "account-1")
        XCTAssertEqual(status.fallbackChain, ["account-1", "account-2", "account-3"])
        XCTAssertEqual(status.profiles.count, 5)
        XCTAssertTrue(status.profiles.filter { !$0.isCodex }.allSatisfy { $0.provider == "anthropic" },
                      "claude-slot fixture profiles stay brand-free (all anthropic)")
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
        // INT-2 codex slot: top-level pointers + the codex profile's per-profile fields.
        XCTAssertEqual(status.activeCodexProfile, "codex-1")
        XCTAssertEqual(status.codexFallbackChain, ["codex-1", "codex-2"])
        let codex = try XCTUnwrap(status.profiles.first { $0.name == "codex-1" })
        XCTAssertTrue(codex.isCodex)
        XCTAssertEqual(codex.harness, "codex")
        XCTAssertEqual(codex.provider, "openai")
        XCTAssertEqual(codex.tier, "pro")
        XCTAssertTrue(codex.active, "codex slot is active independently of the claude slot")
        XCTAssertEqual(codex.codexSnapshotAt, "2026-07-03T12:00:00+00:00")
        XCTAssertNil(codex.codexRateLimitReached)
        // TABS-1: chain members carry a real fallback block for THEIR harness's
        // chain (the daemon emits one per member; position is 1-based).
        XCTAssertEqual(codex.fallback?.position, 1)
        XCTAssertEqual(status.profiles.first { $0.name == "codex-2" }?.fallback?.position, 2)
        XCTAssertEqual(codex.harnessKind, .codex)
        XCTAssertEqual(status.activeName(for: .codex), "codex-1")
        XCTAssertEqual(status.activeName(for: .claude), "account-1")
        XCTAssertEqual(status.chain(for: .codex), ["codex-1", "codex-2"])
        // A claude profile has no harness key → nil, isCodex false (default slot).
        let account1 = try XCTUnwrap(status.profiles.first { $0.name == "account-1" })
        XCTAssertNil(account1.harness)
        XCTAssertFalse(account1.isCodex)
        XCTAssertNil(account1.codexSnapshotAt)
        // Both slots can be active at once — that is the contract, not a bug.
        XCTAssertTrue(account1.active)
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

    // MARK: Additive codex fields (INT-2) — present AND absent-on-old-daemon decode.

    func testCodexFieldsDecodeWhenPresent() throws {
        // A codex-aware daemon: top-level active_codex_profile + codex_fallback_chain,
        // and a codex profile carrying harness/codex_snapshot_at/codex_rate_limit_reached.
        // The claude profile stays active simultaneously (two independent slots).
        let status = try decode(#"""
        {"schema":1,"generated_at":"2026-07-04T05:00:00+00:00","active_profile":"cl",
         "wrap_off":false,"refresh_interval_ms":90000,
         "fallback_chain":["cl"],"active_codex_profile":"cx","codex_fallback_chain":["cx"],
         "profiles":[
           {"name":"cl","active":true,"provider":"anthropic",
            "windows":[{"label":"5h","utilization_pct":30}]},
           {"name":"cx","active":true,"provider":"openai","harness":"codex","tier":"pro",
            "codex_snapshot_at":"2026-07-03T12:00:00+00:00","codex_rate_limit_reached":"primary",
            "windows":[{"label":"5h","utilization_pct":55},{"label":"7d","utilization_pct":40}]}]}
        """#)
        XCTAssertEqual(status.activeCodexProfile, "cx")
        XCTAssertEqual(status.codexFallbackChain, ["cx"])
        let cl = try XCTUnwrap(status.profiles.first { $0.name == "cl" })
        XCTAssertFalse(cl.isCodex)
        XCTAssertNil(cl.harness)
        let cx = try XCTUnwrap(status.profiles.first { $0.name == "cx" })
        XCTAssertTrue(cx.isCodex)
        XCTAssertEqual(cx.harness, "codex")
        XCTAssertEqual(cx.codexSnapshotAt, "2026-07-03T12:00:00+00:00")
        XCTAssertEqual(cx.codexRateLimitReached, "primary")
        // Both slots active at once — the contract.
        XCTAssertTrue(cl.active)
        XCTAssertTrue(cx.active)
    }

    func testCodexFieldsAbsentDecodeBackCompat() throws {
        // An OLDER (codex-less) daemon: no top-level codex pointers, no per-profile
        // harness. active_codex_profile is nil, codex_fallback_chain empty, and every
        // profile reads as a non-codex (claude) slot — never a decode failure.
        let status = try decode(#"""
        {"schema":1,"generated_at":"2026-07-04T05:00:00+00:00","active_profile":"a",
         "wrap_off":false,"refresh_interval_ms":90000,"fallback_chain":["a"],
         "profiles":[{"name":"a","active":true,
            "fallback":{"position":1,"threshold":95,"armed":true}}]}
        """#)
        XCTAssertNil(status.activeCodexProfile)
        XCTAssertEqual(status.codexFallbackChain, [])
        let p = try XCTUnwrap(status.profiles.first)
        XCTAssertNil(p.harness)
        XCTAssertFalse(p.isCodex)
        XCTAssertNil(p.codexSnapshotAt)
        XCTAssertNil(p.codexRateLimitReached)
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
