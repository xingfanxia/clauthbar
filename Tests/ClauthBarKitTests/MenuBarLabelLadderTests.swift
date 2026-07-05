import Foundation
import XCTest

@testable import ClauthBarKit

/// The menu-bar label ladder (CBAR4-6, design §6): one test per rung + collision
/// precedence. All state is in SF Symbol SHAPE (never color); the % always means
/// the ACTIVE account's 5h window.
final class MenuBarLabelLadderTests: XCTestCase {
    private let base = 1_700_000_000.0
    private var now: Date { Date(timeIntervalSince1970: base) }

    private func iso(_ t: TimeInterval) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    /// A profile fragment. `util` nil = no 5h window; `provider` non-anthropic +
    /// `available` = a third-party row.
    private func profile(
        _ name: String, active: Bool = false, threshold: Double? = 95,
        util: Double? = nil, armed: Bool = false,
        provider: String = "anthropic", available: Bool? = nil
    ) -> String {
        let fallback = threshold.map { "\"fallback\":{\"position\":0,\"threshold\":\($0),\"armed\":\(armed)}," } ?? ""
        let windows = util.map { "{\"label\":\"5h\",\"utilization_pct\":\($0),\"resets_at\":\"\(iso(base + 3600))\"}" } ?? ""
        let tp = available.map { ",\"third_party\":{\"available\":\($0)}" } ?? ""
        return """
        {"name":"\(name)","active":\(active),"provider":"\(provider)",\(fallback)"windows":[\(windows)]\(tp)}
        """
    }

    private func status(
        age: TimeInterval = 0, active: String?, wrapOff: Bool = false,
        chain: [String] = [], profiles: [String]
    ) -> DaemonStatus {
        let activeJSON = active.map { "\"\($0)\"" } ?? "null"
        let chainJSON = chain.map { "\"\($0)\"" }.joined(separator: ",")
        let json = """
        {"schema":1,"generated_at":"\(iso(base - age))","active_profile":\(activeJSON),
         "wrap_off":\(wrapOff),"refresh_interval_ms":90000,
         "fallback_chain":[\(chainJSON)],"profiles":[\(profiles.joined(separator: ","))]}
        """
        return try! JSONDecoder().decode(DaemonStatus.self, from: Data(json.utf8))
    }

    private func spec(_ s: DaemonStatus?, inFlight: Bool = false, rotation: String? = nil) -> MenuBarLabelLadder.Spec {
        MenuBarLabelLadder.spec(status: s, switchInFlight: inFlight, rotationFlash: rotation, now: now)
    }

    // MARK: rungs.

    func testRung1DeadWithholdsPercent() {
        // age 30s (> 15s) → dead: warning triangle, frozen age, NO %.
        let s = status(age: 30, active: "xfx", profiles: [profile("xfx", active: true, util: 62)])
        let out = spec(s)
        XCTAssertEqual(out.symbol, "exclamationmark.triangle.fill")
        XCTAssertTrue(out.text.contains("xfx"))
        XCTAssertFalse(out.text.contains("%"))
    }

    func testRung2SwitchInFlightEllipsis() {
        let s = status(active: "xfx", profiles: [profile("xfx", active: true, util: 62)])
        let out = spec(s, inFlight: true)
        XCTAssertTrue(out.text.hasSuffix("…"))
        XCTAssertFalse(out.text.contains("%"))
    }

    func testRung3RotationFlash() {
        let s = status(active: "xfx", profiles: [profile("xfx", active: true, util: 62)])
        let out = spec(s, rotation: "cl-ax")
        XCTAssertEqual(out.symbol, "arrow.left.arrow.right")
        XCTAssertEqual(out.text, "cl-ax")
    }

    func testRung4WrapOffAllOff() {
        let s = status(active: nil, profiles: [profile("xfx", util: 99)])
        let out = spec(s)
        XCTAssertEqual(out.symbol, "powersleep")
        XCTAssertEqual(out.text, "off")
    }

    func testRung5NoStatus() {
        let out = spec(nil)
        XCTAssertEqual(out.text, "")
        XCTAssertNil(out.trailingSymbol)
    }

    func testRung6OverThreshold() {
        let s = status(active: "xfx", chain: ["xfx"],
                       profiles: [profile("xfx", active: true, threshold: 95, util: 96, armed: true)])
        let out = spec(s)
        XCTAssertEqual(out.symbol, "gauge.with.dots.needle.bottom.100percent")
        XCTAssertTrue(out.text.contains("96%"))
    }

    func testRung7NearThresholdDot() {
        // 84 ≥ 0.8×95 (=76) but < 95.
        let s = status(active: "xfx", chain: ["xfx"],
                       profiles: [profile("xfx", active: true, threshold: 95, util: 84, armed: true)])
        let out = spec(s)
        XCTAssertTrue(out.nearThresholdDot)
        XCTAssertTrue(out.text.contains("84%"))
    }

    func testRung8DisarmedAppendsBoltSlash() {
        // Chain non-empty but zero armed → bolt.slash appended to the normal label.
        let s = status(active: "xfx", chain: ["xfx", "cl-ax"], profiles: [
            profile("xfx", active: true, threshold: 95, util: 62, armed: false),
            profile("cl-ax", threshold: 95, util: 10, armed: false),
        ])
        XCTAssertEqual(spec(s).trailingSymbol, "bolt.slash")
    }

    func testEmptyChainIsDisarmed() {
        let s = status(active: "xfx", chain: [], profiles: [profile("xfx", active: true, threshold: nil, util: 62)])
        XCTAssertEqual(spec(s).trailingSymbol, "bolt.slash")
    }

    func testRung9NormalArmedNoTrailing() {
        let s = status(active: "xfx", chain: ["xfx"],
                       profiles: [profile("xfx", active: true, threshold: 95, util: 62, armed: true)])
        let out = spec(s)
        XCTAssertEqual(out.symbol, "gauge.with.dots.needle.bottom.50percent")
        XCTAssertEqual(out.text, "xfx 62%")
        XCTAssertNil(out.trailingSymbol)
        XCTAssertFalse(out.nearThresholdDot)
    }

    func testThirdPartyActiveShowsDotNotPercent() {
        let s = status(active: "zai", chain: ["zai"], profiles: [
            profile("zai", active: true, threshold: nil, provider: "openai", available: true),
        ])
        let out = spec(s)
        XCTAssertEqual(out.availabilityDot, true)
        XCTAssertFalse(out.text.contains("%"))
        XCTAssertEqual(out.text, "zai")
    }

    // MARK: collision precedence (highest rung wins).

    func testDeadBeatsSwitchInFlight() {
        let s = status(age: 30, active: "xfx", profiles: [profile("xfx", active: true, util: 62)])
        XCTAssertEqual(spec(s, inFlight: true).symbol, "exclamationmark.triangle.fill")
    }

    func testSwitchInFlightBeatsRotation() {
        let s = status(active: "xfx", profiles: [profile("xfx", active: true, util: 62)])
        XCTAssertTrue(spec(s, inFlight: true, rotation: "cl-ax").text.hasSuffix("…"))
    }

    func testRotationBeatsWrapOff() {
        let s = status(active: nil, profiles: [profile("xfx", util: 99)])
        XCTAssertEqual(spec(s, rotation: "cl-ax").symbol, "arrow.left.arrow.right")
    }

    func testOverThresholdAndDisarmedCombine() {
        // rung 6 primary + rung 8 trailing co-occur.
        let s = status(active: "xfx", chain: ["xfx", "cl-ax"], profiles: [
            profile("xfx", active: true, threshold: 95, util: 96, armed: false),
            profile("cl-ax", threshold: 95, util: 10, armed: false),
        ])
        let out = spec(s)
        XCTAssertEqual(out.symbol, "gauge.with.dots.needle.bottom.100percent")
        XCTAssertEqual(out.trailingSymbol, "bolt.slash")
    }

    func testNameTruncatedToTwelve() {
        let s = status(active: "a-very-long-account-name", chain: ["a-very-long-account-name"],
                       profiles: [profile("a-very-long-account-name", active: true, threshold: 95, util: 62, armed: true)])
        // 11 chars + ellipsis.
        XCTAssertTrue(spec(s).text.contains("…"))
        XCTAssertTrue(spec(s).text.count <= 12 + 4) // name budget + " 62%"
    }
}
