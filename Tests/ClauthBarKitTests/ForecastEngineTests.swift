import Foundation
import XCTest

@testable import ClauthBarKit

/// The forecast engine (CBAR4-2) is the truthfulness core — a contractual mirror
/// of clauth `fallback.rs::next_target`. These fixture tests pin the pass order
/// (headroom → 100%-sink → wrap-off) and the skip set (active / auth-broken); if
/// the Rust walk changes, these must change with it (risk register #2).
final class ForecastEngineTests: XCTestCase {
    // A fixed clock so `five_hour_live` (resets_at in the future) is deterministic.
    private let base = 1_700_000_000.0
    private var now: Date { Date(timeIntervalSince1970: base) }

    private func iso(_ t: TimeInterval) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    /// A profile JSON fragment. `util` nil = no 5h window (headroom); `live:false`
    /// = a lapsed window (headroom regardless of util).
    private func profile(
        _ name: String, threshold: Double = 95, util: Double? = nil,
        live: Bool = true, authBroken: Bool = false
    ) -> String {
        let resets = iso(live ? base + 3600 : base - 3600)
        let windows = util.map {
            "{\"label\":\"5h\",\"utilization_pct\":\($0),\"resets_at\":\"\(resets)\"}"
        } ?? ""
        let auth = authBroken ? ",\"auth_status\":\"broken\"" : ""
        return """
        {"name":"\(name)","active":false,\
        "fallback":{"position":0,"threshold":\(threshold),"armed":true},\
        "windows":[\(windows)]\(auth)}
        """
    }

    private func status(active: String, wrapOff: Bool = false, chain: [String], profiles: [String]) -> DaemonStatus {
        let chainJSON = chain.map { "\"\($0)\"" }.joined(separator: ",")
        let json = """
        {"schema":1,"generated_at":"\(iso(base))","active_profile":"\(active)",
         "wrap_off":\(wrapOff),"refresh_interval_ms":90000,
         "fallback_chain":[\(chainJSON)],"profiles":[\(profiles.joined(separator: ","))]}
        """
        return try! JSONDecoder().decode(DaemonStatus.self, from: Data(json.utf8))
    }

    // MARK: Pass 1 — headroom.

    func testNormalChainPicksFirstHeadroomMember() {
        let s = status(active: "xfx", chain: ["xfx", "cl-ax", "zai"], profiles: [
            profile("xfx", util: 30), profile("cl-ax", util: 20), profile("zai", util: 10),
        ])
        XCTAssertEqual(ForecastEngine.nextTarget(s, now: now), .switchTo("cl-ax"))
    }

    func testSkipsExhaustedUntilHeadroom() {
        let s = status(active: "xfx", chain: ["xfx", "cl-ax", "zai"], profiles: [
            profile("xfx", util: 50),
            profile("cl-ax", threshold: 95, util: 99), // exhausted (99 ≥ 95, live)
            profile("zai", util: 10),                  // headroom
        ])
        XCTAssertEqual(ForecastEngine.nextTarget(s, now: now), .switchTo("zai"))
    }

    func testLapsedWindowIsHeadroomDespiteHighUtil() {
        // A high util on a LAPSED window (resets_at past) is NOT exhausted.
        let s = status(active: "xfx", chain: ["xfx", "cl-ax"], profiles: [
            profile("xfx", util: 50),
            profile("cl-ax", threshold: 95, util: 99, live: false),
        ])
        XCTAssertEqual(ForecastEngine.nextTarget(s, now: now), .switchTo("cl-ax"))
    }

    func testWalkWrapsPastEndToALowerIndex() {
        // The whole reason this engine exists (risk #2: naive position+1 is banned):
        // active is MID-chain and the only viable target is at a LOWER index, so the
        // walk must wrap `(idx+offset) % len` past the end. active=xfx@1; b@2 exhausted;
        // a@0 headroom → must wrap to a.
        let s = status(active: "xfx", chain: ["a", "xfx", "b"], profiles: [
            profile("a", util: 10),
            profile("xfx", util: 50),
            profile("b", threshold: 95, util: 99), // exhausted
        ])
        XCTAssertEqual(ForecastEngine.nextTarget(s, now: now), .switchTo("a"))
    }

    // MARK: skip set — auth-broken (AUTH-1) + unresolvable member.

    func testUnresolvableMemberSkipped() {
        // A stale chain entry with no matching profile is skipped, not crashed on.
        let s = status(active: "xfx", chain: ["xfx", "ghost", "zai"], profiles: [
            profile("xfx", util: 50), profile("zai", util: 10), // no "ghost"
        ])
        XCTAssertEqual(ForecastEngine.nextTarget(s, now: now), .switchTo("zai"))
    }

    func testAuthBrokenSkippedInSinkPassToo() {
        // The broken exclusion must cover the 100%-sink pass, not just headroom:
        // both sinks are exhausted (pass 1 empty), the first is auth-broken → the
        // sink pass must walk past it to the healthy sink.
        let s = status(active: "xfx", chain: ["xfx", "brokensink", "goodsink"], profiles: [
            profile("xfx", threshold: 95, util: 50),
            profile("brokensink", threshold: 100, util: 100, authBroken: true),
            profile("goodsink", threshold: 100, util: 100),
        ])
        XCTAssertEqual(ForecastEngine.nextTarget(s, now: now), .switchTo("goodsink"))
    }

    func testAuthBrokenMemberSkipped() {
        let s = status(active: "xfx", chain: ["xfx", "cl-ax", "zai"], profiles: [
            profile("xfx", util: 50),
            profile("cl-ax", util: 10, authBroken: true), // headroom but revoked → skip
            profile("zai", util: 20),
        ])
        XCTAssertEqual(ForecastEngine.nextTarget(s, now: now), .switchTo("zai"))
    }

    // MARK: Pass 2 — 100% sink (last resort).

    func testSinkIsLastResortWhenNoHeadroom() {
        let s = status(active: "xfx", chain: ["xfx", "sink"], profiles: [
            profile("xfx", threshold: 95, util: 50),
            profile("sink", threshold: 100, util: 100), // exhausted in pass 1, sink in pass 2
        ])
        XCTAssertEqual(ForecastEngine.nextTarget(s, now: now), .switchTo("sink"))
    }

    func testActiveSinkDoesNotRotateIntoAnotherSink() {
        // Active is itself a 100% sink → no point migrating sink→sink.
        let s = status(active: "xfx", chain: ["xfx", "sink"], profiles: [
            profile("xfx", threshold: 100, util: 100),
            profile("sink", threshold: 100, util: 100),
        ])
        XCTAssertEqual(ForecastEngine.nextTarget(s, now: now), .none)
    }

    // MARK: wrap-off / all-spent.

    func testAllSpentNoWrapOffIsNone() {
        let s = status(active: "xfx", chain: ["xfx", "a", "b"], profiles: [
            profile("xfx", threshold: 95, util: 99),
            profile("a", threshold: 95, util: 99),
            profile("b", threshold: 90, util: 95),
        ])
        XCTAssertEqual(ForecastEngine.nextTarget(s, now: now), .none)
    }

    func testAllSpentWithWrapOffIsOff() {
        let s = status(active: "xfx", wrapOff: true, chain: ["xfx", "a", "b"], profiles: [
            profile("xfx", threshold: 95, util: 99), // active itself exhausted
            profile("a", threshold: 95, util: 99),
            profile("b", threshold: 90, util: 95),
        ])
        XCTAssertEqual(ForecastEngine.nextTarget(s, now: now), .off)
    }

    func testWrapOffButActiveHasHeadroomIsNone() {
        // The picker also runs on a healthy active — wrap-off must not fire OFF then.
        let s = status(active: "xfx", wrapOff: true, chain: ["xfx", "a"], profiles: [
            profile("xfx", threshold: 95, util: 40), // active has headroom
            profile("a", threshold: 95, util: 99),
        ])
        XCTAssertEqual(ForecastEngine.nextTarget(s, now: now), .none)
    }

    // MARK: degenerate inputs.

    func testActiveNotInChainIsNone() {
        let s = status(active: "xfx", chain: ["cl-ax", "zai"], profiles: [
            profile("cl-ax", util: 10), profile("zai", util: 10),
        ])
        XCTAssertEqual(ForecastEngine.nextTarget(s, now: now), .none)
    }

    func testSingletonChainIsNone() {
        let s = status(active: "xfx", chain: ["xfx"], profiles: [profile("xfx", util: 99)])
        XCTAssertEqual(ForecastEngine.nextTarget(s, now: now), .none)
    }
}
