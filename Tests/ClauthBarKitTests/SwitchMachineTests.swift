import XCTest

@testable import ClauthBarKit

/// The switch state machine (CBAR4-3), driven purely by events — the design's
/// STATE 3 flow: live-session arm-confirm, instant refusal/unreachable failure,
/// accepted-then-dropped 6s timeout, socket-observed confirm, and CLI-exit confirm.
final class SwitchMachineTests: XCTestCase {
    private typealias Phase = SwitchMachine.Phase
    private func reduce(_ p: Phase, _ e: SwitchMachine.Event) -> Phase { SwitchMachine.reduce(p, e) }

    // MARK: request → arm (live session) vs straight to pending.

    func testRequestWithLiveSessionArms() {
        // The current account has a live session → arm-confirm (guard the asset the
        // Keychain rewrite would strand).
        XCTAssertEqual(
            reduce(.idle, .requestSwitch(target: "cl-ax", currentHasLiveSession: true)),
            .arming(target: "cl-ax")
        )
    }

    func testRequestWithoutLiveSessionGoesPending() {
        XCTAssertEqual(
            reduce(.idle, .requestSwitch(target: "cl-ax", currentHasLiveSession: false)),
            .pending(target: "cl-ax")
        )
    }

    func testConfirmArmMovesToPending() {
        XCTAssertEqual(reduce(.arming(target: "cl-ax"), .confirmArm), .pending(target: "cl-ax"))
    }

    func testArmCancelAndTimeoutRevertToIdle() {
        XCTAssertEqual(reduce(.arming(target: "cl-ax"), .cancel), .idle)
        XCTAssertEqual(reduce(.arming(target: "cl-ax"), .armTimedOut), .idle)
    }

    func testReArmToADifferentTarget() {
        XCTAssertEqual(
            reduce(.arming(target: "cl-ax"), .requestSwitch(target: "zai", currentHasLiveSession: true)),
            .arming(target: "zai")
        )
    }

    // MARK: pending → outcomes.

    func testAcceptedStaysPending() {
        // Socket accepted ≠ landed — wait for the daemon's tick (observedActive).
        XCTAssertEqual(reduce(.pending(target: "cl-ax"), .dispatched(.accepted)), .pending(target: "cl-ax"))
    }

    func testObservedActiveConfirms() {
        XCTAssertEqual(
            reduce(.pending(target: "cl-ax"), .observedActive("cl-ax")),
            .confirmed(target: "cl-ax", viaCLI: false)
        )
    }

    func testObservedOtherStaysPending() {
        XCTAssertEqual(reduce(.pending(target: "cl-ax"), .observedActive("xfx")), .pending(target: "cl-ax"))
    }

    func testConfirmedByCLIWhenDaemonDead() {
        // Daemon dead → CLI did the switch, confirmed by exit code (status.json won't
        // move), and flagged viaCLI so the UI can say auto-switch is inactive.
        XCTAssertEqual(
            reduce(.pending(target: "cl-ax"), .dispatched(.confirmedByCLI)),
            .confirmed(target: "cl-ax", viaCLI: true)
        )
    }

    func testRefusedFailsInstantlyWithReason() {
        XCTAssertEqual(
            reduce(.pending(target: "cl-ax"), .dispatched(.refused(code: "busy", message: "a switch is in progress"))),
            .failed(reason: "a switch is in progress")
        )
    }

    func testUnreachableFails() {
        if case .failed = reduce(.pending(target: "cl-ax"), .dispatched(.unreachable)) {} else {
            XCTFail("unreachable dispatch must fail")
        }
    }

    func testPendingTimeoutFails() {
        // Accepted-then-silently-dropped: the 6s timer is the only signal.
        if case .failed = reduce(.pending(target: "cl-ax"), .pendingTimedOut) {} else {
            XCTFail("pending timeout must fail")
        }
    }

    func testRequestIgnoredWhilePending() {
        // A double-tap mid-switch must not interrupt the in-flight switch.
        XCTAssertEqual(
            reduce(.pending(target: "cl-ax"), .requestSwitch(target: "zai", currentHasLiveSession: false)),
            .pending(target: "cl-ax")
        )
    }

    // MARK: transient dismissal.

    func testConfirmedAndFailedDismissToIdle() {
        XCTAssertEqual(reduce(.confirmed(target: "cl-ax", viaCLI: false), .dismiss), .idle)
        XCTAssertEqual(reduce(.failed(reason: "x"), .dismiss), .idle)
    }

    // MARK: phase helpers.

    func testIsBusyAndInFlightTarget() {
        XCTAssertTrue(Phase.arming(target: "a").isBusy)
        XCTAssertTrue(Phase.pending(target: "a").isBusy)
        XCTAssertFalse(Phase.idle.isBusy)
        XCTAssertFalse(Phase.confirmed(target: "a", viaCLI: false).isBusy)
        XCTAssertEqual(Phase.pending(target: "a").inFlightTarget, "a")
        XCTAssertNil(Phase.confirmed(target: "a", viaCLI: false).inFlightTarget)
    }

    // MARK: a full happy path.

    func testHappyPathArmConfirmLand() {
        var p = Phase.idle
        p = reduce(p, .requestSwitch(target: "cl-ax", currentHasLiveSession: true))
        XCTAssertEqual(p, .arming(target: "cl-ax"))
        p = reduce(p, .confirmArm)
        XCTAssertEqual(p, .pending(target: "cl-ax"))
        p = reduce(p, .dispatched(.accepted))
        XCTAssertEqual(p, .pending(target: "cl-ax"))
        p = reduce(p, .observedActive("cl-ax"))
        XCTAssertEqual(p, .confirmed(target: "cl-ax", viaCLI: false))
        p = reduce(p, .dismiss)
        XCTAssertEqual(p, .idle)
    }
}
