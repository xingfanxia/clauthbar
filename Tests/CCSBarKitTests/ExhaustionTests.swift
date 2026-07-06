import Foundation
import XCTest

@testable import CCSBarKit

/// `ProfileStatus.spentTag` — the single source of truth for "this account has hit a
/// usage cap" (design §5 danger role). The row pill, the muted name, and VoiceOver all
/// read from here, so the whole (5h × 7d) matrix + the boundary is pinned once.
final class ExhaustionTests: XCTestCase {
    /// A one-profile fixture with the given 5h / 7d utilisation (nil = window absent).
    private func profile(fiveH: Double?, sevenD: Double?, provider: String = "anthropic") throws -> ProfileStatus {
        var windows: [String] = []
        if let fiveH { windows.append("{\"label\":\"5h\",\"utilization_pct\":\(fiveH)}") }
        if let sevenD { windows.append("{\"label\":\"7d\",\"utilization_pct\":\(sevenD)}") }
        let json = """
        {"name":"acct","active":false,"provider":"\(provider)","windows":[\(windows.joined(separator: ","))]}
        """
        return try JSONDecoder().decode(ProfileStatus.self, from: Data(json.utf8))
    }

    func testHeadroomIsNotSpent() throws {
        XCTAssertNil(try profile(fiveH: 42, sevenD: 78).spentTag)
        XCTAssertNil(try profile(fiveH: 0, sevenD: 0).spentTag)
    }

    func testAbsentWindowsAreNotSpent() throws {
        // No windows at all → the `?? 0` fallback keeps both pcts at 0 → nil (never a
        // crash or a false pill on a profile the daemon hasn't fetched yet).
        XCTAssertNil(try profile(fiveH: nil, sevenD: nil).spentTag)
    }

    func testOverHundredStillReadsAsSpent() throws {
        // The daemon can briefly report >100% (usage counted past the cap); `>=` keeps
        // it spent rather than flipping back to headroom.
        XCTAssertEqual(try profile(fiveH: 120, sevenD: 105).spentTag, "spent")
    }

    func testFiveHourCapNamesTheSessionWindow() throws {
        // 5h maxed, weekly has headroom → "5h spent" (recovers in hours).
        XCTAssertEqual(try profile(fiveH: 100, sevenD: 31).spentTag, "5h spent")
    }

    func testWeeklyCapNamesTheWeekWindow() throws {
        // The real-world cl-ax case: session has headroom, weekly cap hit → "week spent".
        XCTAssertEqual(try profile(fiveH: 8, sevenD: 100).spentTag, "week spent")
    }

    func testBothCapsCollapseToSpent() throws {
        // When both windows are maxed the pill is just "spent" — no window is the
        // one to wait on.
        XCTAssertEqual(try profile(fiveH: 100, sevenD: 100).spentTag, "spent")
    }

    func testBoundaryMatchesTheDisplayedPercent() throws {
        // The bar rounds to an integer; 99.5 shows "100%", so it counts as spent — and
        // 99.4 (shows "99%") does not. The pill can never disagree with the number.
        XCTAssertEqual(try profile(fiveH: 99.5, sevenD: 0).spentTag, "5h spent")
        XCTAssertNil(try profile(fiveH: 99.4, sevenD: 99.4).spentTag)
    }

    func testFableOnlyCapIsNotSpent() throws {
        // A maxed Fable-trial window with 5h/7d headroom is deliberately NOT "spent" —
        // the account still serves non-Fable requests. Characterization: pin it so a
        // future change doesn't silently fold Fable into spentTag.
        let json = """
        {"name":"acct","active":false,"provider":"anthropic","windows":[
          {"label":"5h","utilization_pct":12},
          {"label":"7d","utilization_pct":40},
          {"label":"7d fable","utilization_pct":100}
        ]}
        """
        let p = try JSONDecoder().decode(ProfileStatus.self, from: Data(json.utf8))
        XCTAssertEqual(p.fableWeek?.utilizationPct, 100) // the window IS maxed…
        XCTAssertNil(p.spentTag)                          // …but the account isn't "spent".
    }

    func testThirdPartyNeverReadsAsSpent() throws {
        // z.ai / third-party accounts have no %-windows — availability, not usage.
        let p = try profile(fiveH: 100, sevenD: 100, provider: "z.ai")
        // The provider gate lives ONLY in spentTag → no pill for a third-party account…
        XCTAssertNil(p.spentTag)
        // …even though the low-level, provider-agnostic window boolean still sees 100%.
        XCTAssertTrue(p.fiveHourSpent)
    }
}
