import Foundation

/// The checked-in `status.json` contract fixture (Sources/CCSBarKit/Fixtures/
/// status.json), bundled as a resource. It is the SINGLE source of truth for
/// both the `--snapshot` dev render and the decode contract test — so the two can
/// never drift, and a Rust-side shape change is caught by the test before it
/// blanks the panel. Regenerate from a live daemon with Scripts/regen-fixture.sh.
///
/// PROFILES are neutral DEMO names for the public README hero media: three
/// anthropic accounts `account-1` (active, watching, chain #1) + `account-2`
/// (chain #2) + `account-3` (chain #3, `last_resort` so the flag badge shows).
/// No third-party account lives here on purpose: a real third-party row only
/// exists for a clauth-recognised provider whose display name is a brand, which
/// must not appear in public media. Third-party-decode contract coverage is kept
/// separately as a neutral inline sample in `DaemonStatusTests`. Keeping one
/// bundled fixture for both the render and the decode contract preserves the
/// "fixture = contract" invariant — the alternative (a separate demo.json) could
/// silently drift from the real daemon shape without the contract test catching it.
///
/// INVARIANT — this is DEV-ONLY. It is reached solely from the `--snapshot` path
/// (dev aid) and the tests, NEVER from the normal app run (which reads
/// ~/.clauth/status.json, not this fixture). That is why `Scripts/package_app.sh`
/// deliberately omits the `.bundle` resource from the shipped `.app`. Do NOT read
/// this on the app's hot path: `Bundle.module` **fatalErrors** when the resource
/// bundle is absent (as it is in the packaged .app), so a hot-path read would
/// crash the shipped app rather than degrade.
enum Fixtures {
    /// Raw bytes of the bundled `status.json` fixture. Runs only under `swift
    /// run`/`.build`/tests where the bundle is present; `Bundle.module` traps if
    /// it is missing, so the `nil` return is only for an unreadable-but-present
    /// file, not a defense against the packaged-app case (see the type's INVARIANT).
    static func statusJSONData() -> Data? {
        guard let url = Bundle.module.url(forResource: "status", withExtension: "json") else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    /// Raw bytes of the bundled `tokens.json` fixture (TOK-4) — the machine-wide
    /// token snapshot, DEV-ONLY exactly like `statusJSONData()` (same `Bundle.module`
    /// INVARIANT: never read on the shipped app's hot path). Drives the `tokens`
    /// snapshot variant and the `MachineTokens` decode contract test.
    static func tokensJSONData() -> Data? {
        guard let url = Bundle.module.url(forResource: "tokens", withExtension: "json") else {
            return nil
        }
        return try? Data(contentsOf: url)
    }
}
