import Foundation
import XCTest

@testable import CCSBarKit

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
        // "Last resort" is now the independent `last_resort` flag, not a threshold
        // value — 100 is a plain "leave at 100%" threshold.
        XCTAssertEqual(ChainEdit.thresholdLabel(100), "100%")
        XCTAssertEqual(ChainEdit.currentThresholdLabel(100), "100%")
        XCTAssertEqual(ChainEdit.currentThresholdLabel(80), "80%")
    }

    func testNoWrapOffJargonInVocabulary() {
        // §7: the "wrap-off" jargon is retired from all user-facing copy.
        let copy = [
            ChainEdit.thresholdLegend, ChainEdit.lastResortLegend, ChainEdit.lastResortLabel,
            ChainEdit.addHint, ChainEdit.stayOnLastLabel, ChainEdit.switchEverythingOffLabel,
            ChainEdit.switchEverythingOffDetail,
        ].joined(separator: " ").lowercased()
        XCTAssertFalse(copy.contains("wrap-off"))
        XCTAssertFalse(copy.contains("wrap off"))
    }

    // MARK: - Config row order = chain order (so Move up/down reorders visibly)

    func testChainOrderedMembersByChainThenNonMembersInFileOrder() throws {
        // File order interleaves members + non-members: [b(non), a(chain[0]), d(non),
        // c(chain[1])]. Expect members in CHAIN order (a, c) then non-members in FILE
        // order (b, d) — proves both the chain-order sort AND non-member stability.
        let s = try status("""
        {"schema":1,"generated_at":"2099-01-01T00:00:00+00:00","active_profile":"a",
         "wrap_off":false,"refresh_interval_ms":90000,"fallback_chain":["a","c"],
         "profiles":[
           {"name":"b","active":false},
           {"name":"a","active":true,"fallback":{"position":1,"threshold":95,"armed":true}},
           {"name":"d","active":false},
           {"name":"c","active":false,"fallback":{"position":2,"threshold":95,"armed":false}}
         ]}
        """)
        XCTAssertEqual(ChainEdit.chainOrdered(s.profiles, chain: s.fallbackChain).map(\.name),
                       ["a", "c", "b", "d"])
        // The member prefix equals fallbackChain exactly — the invariant that keeps
        // the config rows consistent with the chain-rail chips + detail-card ordinal.
        let members = ChainEdit.chainOrdered(s.profiles, chain: s.fallbackChain).prefix(s.fallbackChain.count)
        XCTAssertEqual(members.map(\.name), s.fallbackChain)
    }

    func testChainOrderedEmptyChainIsFileOrder() throws {
        // No members → every profile is a non-member → order is unchanged file order.
        let s = try status("""
        {"schema":1,"generated_at":"2099-01-01T00:00:00+00:00","active_profile":"xfx2",
         "wrap_off":false,"refresh_interval_ms":90000,"fallback_chain":[],
         "profiles":[{"name":"zai","active":false},{"name":"xfx2","active":true},{"name":"cl-ax","active":false}]}
        """)
        XCTAssertEqual(ChainEdit.chainOrdered(s.profiles, chain: s.fallbackChain).map(\.name),
                       ["zai", "xfx2", "cl-ax"])
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
           {"name":"xfx","active":true,"fallback":{"position":1,"threshold":95,"armed":true}},
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
