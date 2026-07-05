import Foundation
import XCTest

@testable import ClauthBarKit

/// The model's pure decisions: the switcher's active-first tile order, the
/// staleness threshold (TECH-4 liveness), and that the preview liveness drives
/// `isHealthy` (which dims the menu-bar glyph).
final class StatusModelTests: XCTestCase {
    private func decode(_ json: String) throws -> DaemonStatus {
        try JSONDecoder().decode(DaemonStatus.self, from: Data(json.utf8))
    }

    // MARK: orderedProfiles — active pinned first, otherwise file order.

    @MainActor
    func testOrderedProfilesPinsActiveFirst() throws {
        // Active is the SECOND profile in file order → must be reordered to front.
        let status = try decode(#"""
        {"schema":1,"generated_at":"2026-07-04T05:00:00+00:00","active_profile":"b",
         "wrap_off":false,"refresh_interval_ms":90000,
         "profiles":[{"name":"a","active":false},{"name":"b","active":true},
                     {"name":"c","active":false}]}
        """#)
        let model = StatusModel(preview: status)
        XCTAssertEqual(model.orderedProfiles.map(\.name), ["b", "a", "c"])
    }

    @MainActor
    func testOrderedProfilesStableWhenActiveAlreadyFirst() throws {
        let status = try decode(#"""
        {"schema":1,"generated_at":"2026-07-04T05:00:00+00:00","active_profile":"a",
         "wrap_off":false,"refresh_interval_ms":90000,
         "profiles":[{"name":"a","active":true},{"name":"b","active":false}]}
        """#)
        let model = StatusModel(preview: status)
        XCTAssertEqual(model.orderedProfiles.map(\.name), ["a", "b"])
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
