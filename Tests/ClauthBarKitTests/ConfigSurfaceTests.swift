import Foundation
import XCTest

@testable import ClauthBarKit

/// CBAR4-5 config-surface logic (design §7): the shared `ChainEdit` vocabulary and
/// the armed-member removal gate. Pure decisions over an injected status — no socket
/// is ever touched (the non-armed / confirm paths that WOULD dispatch a real
/// `fallback_remove` are covered through `ChainEdit.removalConsequence` directly, so
/// the tests never risk mutating a live daemon's chain — operator constraint).
final class ConfigSurfaceTests: XCTestCase {
    private func status(_ json: String) throws -> DaemonStatus {
        try JSONDecoder().decode(DaemonStatus.self, from: Data(json.utf8))
    }

    // MARK: - Shared vocabulary (one source of truth for both surfaces)

    func testThresholdPresets() {
        XCTAssertEqual(ChainEdit.thresholdPresets, [50, 80, 90, 95, 100])
    }

    func testThresholdLabels() {
        XCTAssertEqual(ChainEdit.thresholdLabel(50), "50%")
        XCTAssertEqual(ChainEdit.thresholdLabel(95), "95%")
        // 100 reads as the sink, never "switch at 100%".
        XCTAssertEqual(ChainEdit.thresholdLabel(100), "Last resort (100%)")
    }

    func testNoWrapOffJargonInVocabulary() {
        // §7: the "wrap-off" jargon is retired from all user-facing copy.
        let copy = [
            ChainEdit.thresholdLegend, ChainEdit.sinkLegend, ChainEdit.addHint,
            ChainEdit.stayOnLastLabel, ChainEdit.switchEverythingOffLabel,
            ChainEdit.switchEverythingOffDetail,
        ].joined(separator: " ").lowercased()
        XCTAssertFalse(copy.contains("wrap-off"))
        XCTAssertFalse(copy.contains("wrap off"))
    }

    // MARK: - Removal consequence (the armed-member gate)

    // `position` is 1-based to match the daemon contract (status_json.rs / the
    // checked-in Fixtures/status.json) — the move-button disable logic keys off it.
    private func chain(_ members: String) throws -> DaemonStatus {
        try status("""
        {"schema":1,"generated_at":"2099-01-01T00:00:00+00:00","active_profile":"xfx",
         "wrap_off":false,"refresh_interval_ms":90000,"fallback_chain":[\(members)],
         "profiles":[
           {"name":"xfx","active":true,"fallback":{"position":1,"threshold":95,"armed":true}},
           {"name":"cl-ax","active":false,"fallback":{"position":2,"threshold":100,"armed":false}},
           {"name":"zai","active":false}
         ]}
        """)
    }

    func testRemovingNonMemberIsFree() throws {
        // zai has no fallback block → not in the chain → remove freely (nil).
        let s = try chain("\"xfx\",\"cl-ax\"")
        XCTAssertNil(ChainEdit.removalConsequence(of: "zai", in: s))
    }

    func testRemovingUnarmedMemberIsFree() throws {
        // cl-ax is a member but not armed → remove freely.
        let s = try chain("\"xfx\",\"cl-ax\"")
        XCTAssertNil(ChainEdit.removalConsequence(of: "cl-ax", in: s))
    }

    func testRemovingLastArmedMemberDisablesAutoSwitch() throws {
        // xfx is the only armed member → removing it stops auto-switch entirely.
        let s = try chain("\"xfx\",\"cl-ax\"")
        XCTAssertEqual(ChainEdit.removalConsequence(of: "xfx", in: s), .disablesAutoSwitch)
        XCTAssertEqual(RemovalConsequence.disablesAutoSwitch.prompt,
                       "This disables auto-switch — remove anyway?")
    }

    func testRemovingArmedMemberWithOthersRemaining() throws {
        // Both xfx and cl-ax armed → removing xfx leaves auto-switch alive on cl-ax.
        let s = try status("""
        {"schema":1,"generated_at":"2099-01-01T00:00:00+00:00","active_profile":"xfx",
         "wrap_off":false,"refresh_interval_ms":90000,"fallback_chain":["xfx","cl-ax"],
         "profiles":[
           {"name":"xfx","active":true,"fallback":{"position":0,"threshold":95,"armed":true}},
           {"name":"cl-ax","active":false,"fallback":{"position":2,"threshold":90,"armed":true}}
         ]}
        """)
        XCTAssertEqual(ChainEdit.removalConsequence(of: "xfx", in: s), .armedMember)
        XCTAssertEqual(RemovalConsequence.armedMember.prompt,
                       "This account is armed for auto-switch — remove anyway?")
    }

    // MARK: - Model routing (armed path only — never fires a socket command)

    @MainActor
    func testRequestRemoveArmsTheConfirmWithoutDispatching() throws {
        // An armed member routes to the inline confirm (sets pendingRemoval) and
        // stops BEFORE `fallbackRemove` — so this test dispatches no socket command.
        let s = try chain("\"xfx\",\"cl-ax\"")
        let model = StatusModel(preview: s)
        XCTAssertNil(model.pendingRemoval)
        model.requestRemove("xfx")
        XCTAssertEqual(model.pendingRemoval, "xfx")
        XCTAssertEqual(model.pendingRemovalPrompt, "This disables auto-switch — remove anyway?")
        // No command was dispatched, so nothing is in flight and no error surfaced.
        XCTAssertFalse(model.configBusy)
        XCTAssertNil(model.lastCommandError)

        model.cancelRemoval()
        XCTAssertNil(model.pendingRemoval)
        XCTAssertNil(model.pendingRemovalPrompt)
    }
}
