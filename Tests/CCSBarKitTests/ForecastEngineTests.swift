import Foundation
import XCTest

@testable import CCSBarKit

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
        live: Bool = true, authBroken: Bool = false, lastResort: Bool = false
    ) -> String {
        let resets = iso(live ? base + 3600 : base - 3600)
        let windows = util.map {
            "{\"label\":\"5h\",\"utilization_pct\":\($0),\"resets_at\":\"\(resets)\"}"
        } ?? ""
        let auth = authBroken ? ",\"auth_status\":\"broken\"" : ""
        return """
        {"name":"\(name)","active":false,\
        "fallback":{"position":0,"threshold":\(threshold),"armed":true,"last_resort":\(lastResort)},\
        "windows":[\(windows)]\(auth)}
        """
    }

    private func status(
        active: String, wrapOff: Bool = false, weeklyLine: Double? = nil,
        chain: [String], profiles: [String]
    ) -> DaemonStatus {
        let chainJSON = chain.map { "\"\($0)\"" }.joined(separator: ",")
        let weeklyJSON = weeklyLine.map { ",\"weekly_switch_threshold\":\($0)" } ?? ""
        let json = """
        {"schema":1,"generated_at":"\(iso(base))","active_profile":"\(active)",
         "wrap_off":\(wrapOff),"refresh_interval_ms":90000\(weeklyJSON),
         "fallback_chain":[\(chainJSON)],"profiles":[\(profiles.joined(separator: ","))]}
        """
        return try! JSONDecoder().decode(DaemonStatus.self, from: Data(json.utf8))
    }

    // MARK: Pass 1 — headroom.

    func testNormalChainPicksFirstHeadroomMember() {
        let s = status(active: "xfx", chain: ["xfx", "cl-ax", "alt"], profiles: [
            profile("xfx", util: 30), profile("cl-ax", util: 20), profile("alt", util: 10),
        ])
        XCTAssertEqual(ForecastEngine.nextTarget(s, now: now), .switchTo("cl-ax"))
    }

    func testSkipsExhaustedUntilHeadroom() {
        let s = status(active: "xfx", chain: ["xfx", "cl-ax", "alt"], profiles: [
            profile("xfx", util: 50),
            profile("cl-ax", threshold: 95, util: 99), // exhausted (99 ≥ 95, live)
            profile("alt", util: 10),                  // headroom
        ])
        XCTAssertEqual(ForecastEngine.nextTarget(s, now: now), .switchTo("alt"))
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
        let s = status(active: "xfx", chain: ["xfx", "ghost", "alt"], profiles: [
            profile("xfx", util: 50), profile("alt", util: 10), // no "ghost"
        ])
        XCTAssertEqual(ForecastEngine.nextTarget(s, now: now), .switchTo("alt"))
    }

    func testAuthBrokenSkippedInSinkPassToo() {
        // The broken exclusion must cover the last-resort pass, not just headroom:
        // both last-resort members are exhausted (pass 1 empty), the first is
        // auth-broken → the sink pass must walk past it to the healthy last resort.
        let s = status(active: "xfx", chain: ["xfx", "brokensink", "goodsink"], profiles: [
            profile("xfx", threshold: 95, util: 50),
            profile("brokensink", util: 100, authBroken: true, lastResort: true),
            profile("goodsink", util: 100, lastResort: true),
        ])
        XCTAssertEqual(ForecastEngine.nextTarget(s, now: now), .switchTo("goodsink"))
    }

    func testAuthBrokenMemberSkipped() {
        let s = status(active: "xfx", chain: ["xfx", "cl-ax", "alt"], profiles: [
            profile("xfx", util: 50),
            profile("cl-ax", util: 10, authBroken: true), // headroom but revoked → skip
            profile("alt", util: 20),
        ])
        XCTAssertEqual(ForecastEngine.nextTarget(s, now: now), .switchTo("alt"))
    }

    // MARK: Pass 2 — the exclusive last-resort mark.

    func testLastResortPickedWhenNoHeadroomAndActiveIsNotLastResort() {
        // A member flagged last_resort is accepted in pass 2 even while exhausted,
        // but ONLY because the active profile is not itself last_resort.
        let s = status(active: "xfx", chain: ["xfx", "sink"], profiles: [
            profile("xfx", threshold: 95, util: 50),
            profile("sink", util: 100, lastResort: true), // exhausted in pass 1, last resort in pass 2
        ])
        XCTAssertEqual(ForecastEngine.nextTarget(s, now: now), .switchTo("sink"))
    }

    func testActiveLastResortDoesNotRotateIntoAnotherLastResort() {
        // Active is itself last_resort → the exclusive rule parks it (no ping-pong),
        // even though `sink` is also a last_resort member.
        let s = status(active: "xfx", chain: ["xfx", "sink"], profiles: [
            profile("xfx", util: 100, lastResort: true),
            profile("sink", util: 100, lastResort: true),
        ])
        XCTAssertEqual(ForecastEngine.nextTarget(s, now: now), .none)
    }

    func testHighThresholdMemberIsNoLongerASinkWithoutLastResort() {
        // The retired threshold-100 convention: a 100%-threshold member with NO
        // last_resort flag must NOT be picked in pass 2 (it isn't a sink anymore).
        let s = status(active: "xfx", wrapOff: false, chain: ["xfx", "maxed"], profiles: [
            profile("xfx", threshold: 95, util: 99),   // active exhausted, no headroom
            profile("maxed", threshold: 100, util: 100), // exhausted, but last_resort=false
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
        let s = status(active: "xfx", chain: ["cl-ax", "alt"], profiles: [
            profile("cl-ax", util: 10), profile("alt", util: 10),
        ])
        XCTAssertEqual(ForecastEngine.nextTarget(s, now: now), .none)
    }

    func testSingletonChainIsNone() {
        let s = status(active: "xfx", chain: ["xfx"], profiles: [profile("xfx", util: 99)])
        XCTAssertEqual(ForecastEngine.nextTarget(s, now: now), .none)
    }
}

// MARK: - weekly line parity (fallback.rs weekly_blocked_info, default 98)

extension ForecastEngineTests {
    /// Profile fragment with an overall 7d window and NO 5h window at all —
    /// the live specimen's exact shape (a weekly-dead account's 5h window
    /// lapses to `resets_at: null`).
    private func weeklyProfile(_ name: String, util: Double, live: Bool = true) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        let resets = f.string(from: Date(timeIntervalSince1970: 1_700_000_000.0 + (live ? 7 * 86_400 : -3600)))
        return """
        {"name":"\(name)","active":false,\
        "fallback":{"position":0,"threshold":95,"armed":true,"last_resort":false},\
        "windows":[{"label":"7d","utilization_pct":\(util),"resets_at":"\(resets)"}]}
        """
    }

    /// A member whose OVERALL 7d window is spent to 100% is dead until its
    /// weekly reset — the walk must route around it even though it has no live
    /// 5h window at all (the 2026-07-08 daemon bug, mirrored here for parity).
    func testWeeklyDeadMemberIsSkippedDespiteAbsentFiveHour() {
        let s = status(active: "a", chain: ["a", "b", "c"], profiles: [
            profile("a", util: 97),
            weeklyProfile("b", util: 100),
            profile("c", util: 10),
        ])
        XCTAssertEqual(ForecastEngine.nextTarget(s, now: now), .switchTo("c"))
    }

    /// Below the 98 default line is headroom, and a PAST weekly reset is a
    /// renewed quota — neither blocks. (99.9 used to be headroom under the old
    /// 100 hard cap; the 2026-07-12 soft line moved it past the default.)
    func testWeeklyBelowLineOrLapsedStillHasHeadroom() {
        let below = status(active: "a", chain: ["a", "b"], profiles: [
            profile("a", util: 97),
            weeklyProfile("b", util: 97.9),
        ])
        XCTAssertEqual(ForecastEngine.nextTarget(below, now: now), .switchTo("b"))
        let renewed = status(active: "a", chain: ["a", "b"], profiles: [
            profile("a", util: 97),
            weeklyProfile("b", util: 100, live: false),
        ])
        XCTAssertEqual(ForecastEngine.nextTarget(renewed, now: now), .switchTo("b"))
    }

    /// The line rides status.json (`weekly_switch_threshold`): at a configured
    /// 90 a member riding 7d 92% is spent; absent (old daemon) the 98 default
    /// applies and the same member is headroom.
    func testWeeklyLineIsConfigurable() {
        let tightened = status(active: "a", weeklyLine: 90, chain: ["a", "b", "c"], profiles: [
            profile("a", util: 97),
            weeklyProfile("b", util: 92),
            profile("c", util: 10),
        ])
        XCTAssertEqual(ForecastEngine.nextTarget(tightened, now: now), .switchTo("c"))
        let defaulted = status(active: "a", chain: ["a", "b", "c"], profiles: [
            profile("a", util: 97),
            weeklyProfile("b", util: 92),
            profile("c", util: 10),
        ])
        XCTAssertEqual(ForecastEngine.nextTarget(defaulted, now: now), .switchTo("b"))
    }
}
