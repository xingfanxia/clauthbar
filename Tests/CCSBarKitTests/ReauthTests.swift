import Foundation
import XCTest

@testable import CCSBarKit

/// AUTH-3 reauth flow: the pure outcome→message mapping (`reauthFailureMessage`)
/// and the in-flight guard. The spawn itself (`clauth login`) is never invoked —
/// operator constraint: no real browser login in tests — so coverage is on the
/// state routing, which is where the user-facing behavior actually lives.
final class ReauthTests: XCTestCase {
    // MARK: - Outcome → user message (pure)

    func testSuccessHasNoErrorMessage() {
        // Exit 0: the CLI captured tokens and cleared auth_broken → no error, the
        // caller instead nudges a refresh.
        XCTAssertNil(StatusModel.reauthFailureMessage(.ok, name: "xfx"))
    }

    func testCLIFailureSurfacesCauseAndTerminalFallback() {
        // A non-zero `clauth login` (browser abandoned, timeout) must be loud AND
        // give the exact command to run by hand.
        let msg = StatusModel.reauthFailureMessage(
            .daemonError(code: "cli_failed", message: "clauth exited 1"), name: "xfx")
        XCTAssertNotNil(msg)
        XCTAssertTrue(msg!.contains("clauth exited 1"), "carries the cause")
        XCTAssertTrue(msg!.contains("clauth login xfx"), "gives the terminal fallback")
    }

    func testMissingBinaryTellsUserToRunTheCLI() {
        let msg = StatusModel.reauthFailureMessage(.unreachable, name: "cl-ax")
        XCTAssertNotNil(msg)
        XCTAssertTrue(msg!.contains("clauth login cl-ax"))
    }

    // MARK: - In-flight guard (only one browser login at a time)

    @MainActor
    func testGuardBlocksASecondConcurrentReauth() async {
        let model = StatusModel(preview: nil, liveness: .down)
        XCTAssertNil(model.reauthInFlight)
        // `reauthInFlight` is set synchronously (before the Task awaits the runner), so
        // a second call while the first is in flight must no-op. A runner that never
        // returns keeps the first login "in flight" for the duration of the assert.
        let blocked: @Sendable (String) async -> CommandOutcome = { _ in
            try? await Task.sleep(nanoseconds: 5_000_000_000); return .ok
        }
        model.reauth("xfx", run: blocked)
        XCTAssertEqual(model.reauthInFlight, "xfx", "first reauth marks in-flight synchronously")
        model.reauth("cl-ax", run: blocked)
        XCTAssertEqual(model.reauthInFlight, "xfx", "a second reauth is dropped while one is in flight")
    }

    // MARK: - Full lifecycle (injected fake runner — no real login)

    @MainActor
    func testSuccessClearsInFlightAndSurfacesNoError() async {
        // daemon down (.down) → the .ok path skips the socket refresh, so this exercises
        // pure state routing with zero IO.
        let model = StatusModel(preview: nil, liveness: .down)
        model.reauth("xfx", run: { _ in .ok })
        XCTAssertEqual(model.reauthInFlight, "xfx")
        await settleReauth(model)
        XCTAssertNil(model.reauthInFlight, "a completed login clears the in-flight flag")
        XCTAssertNil(model.lastCommandError, "success surfaces no error banner")
    }

    @MainActor
    func testFailureClearsInFlightAndShowsLoudError() async {
        let model = StatusModel(preview: nil, liveness: .down)
        model.reauth("xfx", run: { _ in .daemonError(code: "cli_failed", message: "clauth login exited 1") })
        await settleReauth(model)
        XCTAssertNil(model.reauthInFlight, "a failed login also clears the in-flight flag")
        XCTAssertNotNil(model.lastCommandError, "failure is loud")
        XCTAssertTrue(model.lastCommandError!.contains("clauth login xfx"),
                      "the error gives the terminal fallback command")
    }

    /// Yield the main actor until the reauth Task has run to completion (cleared the
    /// in-flight flag), or a generous cap elapses.
    @MainActor
    private func settleReauth(_ model: StatusModel, cap: Int = 500) async {
        for _ in 0..<cap {
            if model.reauthInFlight == nil { return }
            await Task.yield()
        }
    }
}
