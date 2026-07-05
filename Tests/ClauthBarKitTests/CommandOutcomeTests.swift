import Foundation
import XCTest

@testable import ClauthBarKit

/// The command-outcome honesty layer (TECH-11): a daemon reply must classify into
/// three DISTINCT outcomes so a rejection is never mistaken for daemon-absence (and
/// thus never triggers the blind shell fallback), and the version-skew signal.
final class CommandOutcomeTests: XCTestCase {
    private func reply(_ json: String) -> Data { Data(json.utf8) }

    // MARK: classifyReply — ok / daemonError / unreachable.

    func testOkReplyIsOk() {
        XCTAssertEqual(DaemonClient.classifyReply(reply(#"{"ok":true}"#)), .ok)
    }

    func testRejectionCarriesCodeAndMessage() {
        let out = DaemonClient.classifyReply(
            reply(#"{"ok":false,"error":"login for 'work' has expired","error_code":"auth_broken"}"#)
        )
        XCTAssertEqual(out, .daemonError(code: "auth_broken", message: "login for 'work' has expired"))
        XCTAssertEqual(out.errorMessage, "login for 'work' has expired")
    }

    func testRejectionWithoutFieldsStillDaemonError() {
        // A malformed ok:false still classifies as a daemonError (NOT unreachable —
        // the daemon answered, so the shell fallback must not fire), with defaults.
        let out = DaemonClient.classifyReply(reply(#"{"ok":false}"#))
        guard case .daemonError(let code, _) = out else {
            return XCTFail("ok:false must be a daemonError, got \(out)")
        }
        XCTAssertEqual(code, "unknown")
    }

    func testNilReplyIsUnreachable() {
        XCTAssertEqual(DaemonClient.classifyReply(nil), .unreachable)
    }

    func testUnparseableReplyIsUnreachable() {
        XCTAssertEqual(DaemonClient.classifyReply(reply("not json")), .unreachable)
        // A JSON array (not an object) is also transport-level garbage.
        XCTAssertEqual(DaemonClient.classifyReply(reply("[1,2,3]")), .unreachable)
    }

    func testOkOutcomeHasNoErrorMessage() {
        XCTAssertNil(CommandOutcome.ok.errorMessage)
        XCTAssertNil(CommandOutcome.unreachable.errorMessage)
    }

    // MARK: versionSkew — soft signal from clauth_version.

    @MainActor
    func testNoSkewWhenVersionsMatch() throws {
        let json = """
        {"schema":1,"generated_at":"2026-07-04T05:00:00+00:00","active_profile":"a",
         "wrap_off":false,"refresh_interval_ms":90000,"profiles":[{"name":"a","active":true}],
         "clauth_version":"\(StatusModel.expectedClauthVersion)"}
        """
        let status = try JSONDecoder().decode(DaemonStatus.self, from: Data(json.utf8))
        XCTAssertNil(StatusModel(preview: status).versionSkew)
    }

    @MainActor
    func testSkewReportsDaemonVersionWhenDifferent() throws {
        let json = #"""
        {"schema":1,"generated_at":"2026-07-04T05:00:00+00:00","active_profile":"a",
         "wrap_off":false,"refresh_interval_ms":90000,"profiles":[{"name":"a","active":true}],
         "clauth_version":"9.9.9"}
        """#
        let status = try JSONDecoder().decode(DaemonStatus.self, from: Data(json.utf8))
        XCTAssertEqual(StatusModel(preview: status).versionSkew, "9.9.9")
    }

    // MARK: switchTo fallback POLICY — the feature's headline invariant.

    func testRejectionDoesNotFallBackToShell() {
        // A daemon rejection is authoritative: switchTo returns .refused and must
        // NOT reach the CLI fallback (the cli closure asserts it's never called).
        let out = DaemonClient.switchTo(
            "work",
            send: { _ in .daemonError(code: "busy", message: "a switch is already in progress") },
            cli: { XCTFail("a rejection must not shell to the CLI"); return .unreachable }
        )
        XCTAssertEqual(out, .refused(code: "busy", message: "a switch is already in progress"))
    }

    func testAcceptedSwitchIsAccepted() {
        // A socket-accepted switch reports .accepted (still needs the daemon's tick).
        let out = DaemonClient.switchTo("work", send: { _ in .ok }, cli: { .unreachable })
        XCTAssertEqual(out, .accepted)
    }

    func testUnreachableFallsBackToCLIConfirmedByExit() {
        // Daemon unreachable → CLI runs; exit 0 → confirmedByCLI (not observed via
        // status.json, which a dead daemon never rewrites).
        let out = DaemonClient.switchTo("work", send: { _ in .unreachable }, cli: { .ok })
        XCTAssertEqual(out, .confirmedByCLI)
    }

    func testUnreachableWithFailingCLIIsRefused() {
        let out = DaemonClient.switchTo(
            "work", send: { _ in .unreachable },
            cli: { .daemonError(code: "cli_failed", message: "clauth exited 1") }
        )
        XCTAssertEqual(out, .refused(code: "cli_failed", message: "clauth exited 1"))
    }

    func testUnreachableWithNoCLIIsUnreachable() {
        let out = DaemonClient.switchTo("work", send: { _ in .unreachable }, cli: { .unreachable })
        XCTAssertEqual(out, .unreachable)
    }

    // MARK: last_switch / last_error decode (the observability fields).

    func testLastSwitchAndLastErrorDecode() throws {
        let json = #"""
        {"schema":1,"generated_at":"2026-07-04T05:00:00+00:00","active_profile":"home",
         "wrap_off":false,"refresh_interval_ms":90000,"profiles":[],
         "last_switch":{"from":"work","to":"home","at":"2026-07-04T04:59:00+00:00","trigger":"scheduler"},
         "last_error":{"at":"2026-07-04T04:58:00+00:00","message":"target busy"}}
        """#
        let status = try JSONDecoder().decode(DaemonStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status.lastSwitch?.from, "work")
        XCTAssertEqual(status.lastSwitch?.to, "home")
        XCTAssertEqual(status.lastSwitch?.trigger, "scheduler")
        XCTAssertEqual(status.lastError?.message, "target busy")
    }

    func testMissingObservabilityFieldsAreNil() throws {
        // An older daemon omits them entirely — must decode to nil, not throw.
        let json = #"""
        {"schema":1,"generated_at":"2026-07-04T05:00:00+00:00","active_profile":"a",
         "wrap_off":false,"refresh_interval_ms":90000,"profiles":[]}
        """#
        let status = try JSONDecoder().decode(DaemonStatus.self, from: Data(json.utf8))
        XCTAssertNil(status.lastSwitch)
        XCTAssertNil(status.lastError)
        XCTAssertNil(status.clauthVersion)
    }
}
