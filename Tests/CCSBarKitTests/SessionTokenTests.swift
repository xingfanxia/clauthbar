import Foundation
import Testing
@testable import CCSBarKit

// CLA-SPLIT surfacing: the sidecar reader, the paste validator (echoing
// clauth's `validate_setup_token`), the status-line copy/tone ladder, and the
// spawn argv. All pure/local — no clauth spawn, no real ~/.clauth touched.

@Suite struct SessionTokenTests {
    private func tempSidecar(_ json: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccsbar-st-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("session-token.json")
        if let json { try Data(json.utf8).write(to: url) }
        return url
    }

    @Test func sidecarStatesDistinguishMissingUnstampedAndStamped() throws {
        let missing = try tempSidecar(nil)
        #expect(SessionToken.state(at: missing) == .none)

        let unstamped = try tempSidecar(#"{"claudeAiOauth":{"accessToken":"sk-ant-x"}}"#)
        #expect(SessionToken.state(at: unstamped) == .unstamped)

        // Corrupt JSON is "present, horizon unknown" — never hidden as .none.
        let corrupt = try tempSidecar("not json")
        #expect(SessionToken.state(at: corrupt) == .unstamped)

        let stamped = try tempSidecar(
            #"{"claudeAiOauth":{"accessToken":"sk-ant-x","expiresAt":1700000000000}}"#)
        #expect(SessionToken.state(at: stamped) == .expires(msEpoch: 1_700_000_000_000))

        // A refresh token means a rotating pair — clauth disengages the split
        // for it, so the state must read mis-filled EVEN with a stamped expiry
        // (the 2026-07-20 incident: the stamp displayed "~342d" while the
        // protection was not in force).
        let misfilled = try tempSidecar(
            #"{"claudeAiOauth":{"accessToken":"sk-ant-x","refreshToken":"sk-ant-r","expiresAt":1700000000000}}"#)
        #expect(SessionToken.state(at: misfilled) == .misfilled)
    }

    @Test func misfilledSidecarReadsDangerNotCountdown() {
        let line = SessionToken.statusLine(.misfilled, nowMs: 1_700_000_000_000)
        #expect(line?.tone == .danger)
        #expect(line?.text.contains("mis-filled") == true)
        #expect(line?.text.contains("expires in") != true)
    }

    @Test func validatorEchoesClauthsRule() {
        let good = "sk-ant-oat01-" + String(repeating: "x", count: 48)
        #expect(SessionToken.validationError("  \(good)\n") == nil)
        #expect(SessionToken.trimmed("  \(good)\n") == good)
        // Untouched field: no error yet, but also nothing to submit.
        #expect(SessionToken.validationError("") == nil)
        #expect(SessionToken.trimmed("") == nil)
        #expect(SessionToken.validationError("api-key-" + String(repeating: "x", count: 40)) != nil)
        #expect(SessionToken.validationError("Setup token: \(good)") != nil)
        #expect(SessionToken.validationError("sk-ant-short") != nil)
    }

    @Test func statusLineCountsDownAndEscalates() {
        let day: Int64 = 86_400_000
        let now: Int64 = 1_700_000_000_000

        #expect(SessionToken.statusLine(.none, nowMs: now) == nil)

        let comfy = SessionToken.statusLine(.expires(msEpoch: now + 340 * day), nowMs: now)
        #expect(comfy?.text.contains("expires in ~340d") == true)
        #expect(comfy?.tone == .normal)

        let soon = SessionToken.statusLine(.expires(msEpoch: now + 12 * day), nowMs: now)
        #expect(soon?.text.contains("expires in ~12d") == true)
        #expect(soon?.tone == .warning)

        let dead = SessionToken.statusLine(.expires(msEpoch: now - day), nowMs: now)
        #expect(dead?.text.contains("re-mint: claude setup-token") == true)
        #expect(dead?.tone == .danger)

        // Sub-day expiry: integer day-division reads this as days == 0, which
        // once mislabeled it "~0d" — the gate is the clock, not the count.
        let justDead = SessionToken.statusLine(.expires(msEpoch: now - 1), nowMs: now)
        #expect(justDead?.text.contains("re-mint: claude setup-token") == true)
        #expect(justDead?.tone == .danger)

        let unstamped = SessionToken.statusLine(.unstamped, nowMs: now)
        #expect(unstamped?.text.contains("no recorded expiry") == true)
        #expect(unstamped?.tone == .normal)
    }

    // CLA-FEED: a daemon-fed sidecar's hours-scale expiry is routine
    // maintenance — calm countdown, never the mint's 30-day warning ramp;
    // expired = the feeder is dead (DANGER); a mis-fill overrides the feed.
    @Test func fedTokenRendersMaintenanceNotADyingMint() {
        let now: Int64 = 1_700_000_000_000
        let hour: Int64 = 3_600_000

        let fed = SessionToken.statusLine(.expires(msEpoch: now + 7 * hour), nowMs: now, fed: true)
        #expect(fed?.text == "Fed token · refreshes in ~7h")
        #expect(fed?.tone == .normal)

        let subHour = SessionToken.statusLine(.expires(msEpoch: now + hour / 2), nowMs: now, fed: true)
        #expect(subHour?.text == "Fed token · refreshes in <1h")
        #expect(subHour?.tone == .normal)

        // A mint-shaped horizon under the feed flag: the static mint still
        // serves until the feed supersedes it.
        let mint = SessionToken.statusLine(.expires(msEpoch: now + 340 * 24 * hour), nowMs: now, fed: true)
        #expect(mint?.text.contains("feed arms") == true)
        #expect(mint?.tone == .normal)

        let stalled = SessionToken.statusLine(.expires(msEpoch: now - hour), nowMs: now, fed: true)
        #expect(stalled?.text.contains("Feed stalled") == true)
        #expect(stalled?.tone == .danger)

        let arming = SessionToken.statusLine(.none, nowMs: now, fed: true)
        #expect(arming?.text.contains("arming on next rotation") == true)
        #expect(arming?.tone == .warning)

        let misfilled = SessionToken.statusLine(.misfilled, nowMs: now, fed: true)
        #expect(misfilled?.tone == .danger)
        #expect(misfilled?.text.contains("mis-filled") == true)
    }

    @Test func spawnArgvPipesTokenViaStdinNeverArgv() {
        // `--yes` because a non-TTY spawn can never answer the replace-confirm;
        // the token itself must never appear in the argv (visible in `ps`).
        let args = DaemonClient.setupTokenArgs("ax-main")
        #expect(args == ["login", "ax-main", "--setup-token", "--yes"])
        #expect(!args.contains { $0.hasPrefix("sk-ant-") })
    }

    @Test func flightBannerAndFailureCopyAreSetupTokenAware() {
        #expect(LoginFlight(name: "ax", mode: .setupToken).bannerText
            == "Installing long-lived token for ax…")
        let failure = StatusModel.loginFailureMessage(
            .daemonError(code: "cli_failed", message: "clauth login exited 1"),
            name: "ax", mode: .setupToken)
        #expect(failure?.contains("long-lived token") == true)
        #expect(failure?.contains("--setup-token") == true)
        #expect(StatusModel.loginFailureMessage(.ok, name: "ax", mode: .setupToken) == nil)
    }
}
