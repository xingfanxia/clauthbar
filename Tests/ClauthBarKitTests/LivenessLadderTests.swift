import XCTest

@testable import ClauthBarKit

/// The graded freshness ladder (CBAR4-2 / design §8): live < 5s, syncing 5–15s,
/// dead ≥ 15s — keyed to the 1s write cadence, NOT refresh_interval_ms. The
/// boundaries are the finding-prone part (a dead daemon must read dead in 15s).
final class LivenessLadderTests: XCTestCase {
    func testBands() {
        XCTAssertEqual(LivenessLadder.freshness(ageSeconds: 0), .live)
        XCTAssertEqual(LivenessLadder.freshness(ageSeconds: 4.99), .live)
        // 5s boundary: live below, syncing at/above.
        XCTAssertEqual(LivenessLadder.freshness(ageSeconds: 5), .syncing)
        XCTAssertEqual(LivenessLadder.freshness(ageSeconds: 14.99), .syncing)
        // 15s boundary: syncing below, dead at/above — the red-banner line.
        XCTAssertEqual(LivenessLadder.freshness(ageSeconds: 15), .dead)
        XCTAssertEqual(LivenessLadder.freshness(ageSeconds: 600), .dead)
    }

    func testCrossCheckTrustsTheYoungerAge() {
        // A stale generated_at but a fresh file mtime (or vice versa) still means the
        // daemon is writing → trust the younger age.
        XCTAssertEqual(
            LivenessLadder.freshness(generatedAtAge: 40, statusMtimeAge: 1), .live
        )
        XCTAssertEqual(
            LivenessLadder.freshness(generatedAtAge: 2, statusMtimeAge: 40), .live
        )
        // Both stale → dead.
        XCTAssertEqual(
            LivenessLadder.freshness(generatedAtAge: 30, statusMtimeAge: 30), .dead
        )
    }

    func testCrossCheckWithMissingSignals() {
        // Only one signal present → use it.
        XCTAssertEqual(LivenessLadder.freshness(generatedAtAge: 3, statusMtimeAge: nil), .live)
        XCTAssertEqual(LivenessLadder.freshness(generatedAtAge: nil, statusMtimeAge: 8), .syncing)
        // Neither → dead (no evidence of life).
        XCTAssertEqual(LivenessLadder.freshness(generatedAtAge: nil, statusMtimeAge: nil), .dead)
    }
}
