import Foundation
import XCTest

@testable import CCSBarKit

/// The model's pure decisions: the switcher's active-first tile order, the
/// staleness threshold (TECH-4 liveness), and that the preview liveness drives
/// `isHealthy` (which dims the menu-bar glyph).
final class StatusModelTests: XCTestCase {
    private func decode(_ json: String) throws -> DaemonStatus {
        try JSONDecoder().decode(DaemonStatus.self, from: Data(json.utf8))
    }

    // MARK: listProfiles — STABLE FILE ORDER (CBAR-4 §2: rows never reorder; only
    // the active badge + inspection ring move).

    @MainActor
    func testListProfilesKeepsFileOrderRegardlessOfActive() throws {
        // Active is the SECOND profile — the list must NOT reorder it to the front.
        let status = try decode(#"""
        {"schema":1,"generated_at":"2026-07-04T05:00:00+00:00","active_profile":"b",
         "wrap_off":false,"refresh_interval_ms":90000,
         "profiles":[{"name":"a","active":false},{"name":"b","active":true},
                     {"name":"c","active":false}]}
        """#)
        let model = StatusModel(preview: status)
        XCTAssertEqual(model.listProfiles.map(\.name), ["a", "b", "c"])
    }

    @MainActor
    func testInspectionDefaultsToActiveThenFollowsSelection() throws {
        let status = try decode(#"""
        {"schema":1,"generated_at":"2026-07-04T05:00:00+00:00","active_profile":"b",
         "wrap_off":false,"refresh_interval_ms":90000,
         "profiles":[{"name":"a","active":false},{"name":"b","active":true}]}
        """#)
        let model = StatusModel(preview: status)
        // Default inspection = the active account.
        XCTAssertEqual(model.inspected?.name, "b")
        XCTAssertTrue(model.isInspected("b"))
        // Inspecting a row retargets without touching the daemon.
        model.inspect("a")
        XCTAssertEqual(model.inspected?.name, "a")
        // Reset returns to active.
        model.resetInspection()
        XCTAssertEqual(model.inspected?.name, "b")
    }

    // MARK: forecast resolver — the daemon's published forecast is the source of
    // truth; the local ForecastEngine mirror only answers for older daemons.

    @MainActor
    func testPublishedForecastWinsOverMirror() throws {
        // Both members have headroom, so the local mirror would pick the first one
        // after the active ("cl-ax"). The published forecast disagrees ("zai") — the
        // resolver must honour the daemon, not the mirror.
        let status = try decode(#"""
        {"schema":1,"generated_at":"2026-07-04T05:00:00+00:00","active_profile":"xfx",
         "wrap_off":false,"refresh_interval_ms":90000,
         "forecast":{"action":"switch","to":"zai"},
         "fallback_chain":["xfx","cl-ax","zai"],
         "profiles":[
           {"name":"xfx","active":true,"fallback":{"position":1,"threshold":95,"armed":true},
            "windows":[{"label":"5h","utilization_pct":30}]},
           {"name":"cl-ax","active":false,"fallback":{"position":2,"threshold":95,"armed":false},
            "windows":[{"label":"5h","utilization_pct":10}]},
           {"name":"zai","active":false,"fallback":{"position":3,"threshold":95,"armed":false},
            "windows":[{"label":"5h","utilization_pct":10}]}]}
        """#)
        let model = StatusModel(preview: status)
        XCTAssertEqual(model.forecast, .switchTo("zai"))
    }

    @MainActor
    func testForecastFallsBackToMirrorWhenAbsent() throws {
        // Same shape WITHOUT a published forecast (older daemon): the resolver drops
        // to the mirror, which picks the first headroom member after the active.
        let status = try decode(#"""
        {"schema":1,"generated_at":"2026-07-04T05:00:00+00:00","active_profile":"xfx",
         "wrap_off":false,"refresh_interval_ms":90000,
         "fallback_chain":["xfx","cl-ax","zai"],
         "profiles":[
           {"name":"xfx","active":true,"fallback":{"position":1,"threshold":95,"armed":true},
            "windows":[{"label":"5h","utilization_pct":30}]},
           {"name":"cl-ax","active":false,"fallback":{"position":2,"threshold":95,"armed":false},
            "windows":[{"label":"5h","utilization_pct":10}]},
           {"name":"zai","active":false,"fallback":{"position":3,"threshold":95,"armed":false},
            "windows":[{"label":"5h","utilization_pct":10}]}]}
        """#)
        let model = StatusModel(preview: status)
        XCTAssertEqual(model.forecast, .switchTo("cl-ax"))
    }

    // (staleness threshold moved to LivenessLadder — see LivenessLadderTests.)

    // MARK: isHealthy reflects liveness (dims the menu-bar glyph when not .ok).

    @MainActor
    func testIsHealthyOnlyWhenLive() {
        XCTAssertTrue(StatusModel(preview: nil, liveness: .ok).isHealthy)
        XCTAssertFalse(StatusModel(preview: nil, liveness: .down).isHealthy)
        XCTAssertFalse(StatusModel(preview: nil, liveness: .stalled(since: "05:00")).isHealthy)
        XCTAssertFalse(StatusModel(preview: nil, liveness: .outOfDate(schema: 2)).isHealthy)
    }
}
