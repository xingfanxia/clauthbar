import Foundation

/// CLA-SPLIT surfacing (the clauth session-token split, fork PR #53): a claude
/// profile may carry a static long-lived login in
/// `~/.clauth/profiles/<name>/session-token.json`, minted by `claude
/// setup-token` (~1yr) and installed by switches so sessions never race
/// clauth's OAuth refresher. ccsbar surfaces two things about it:
///
/// - STATUS: whether the sidecar exists and when it expires (DetailCard line,
///   read straight from the sidecar file — same direct-file idiom as
///   `CodexProxyMode` reading `~/.codex/config.toml`, and it keeps working
///   with the daemon down). Only `expiresAt` is decoded; the token value is
///   never kept, shown, or logged.
/// - CAPTURE: the context-menu "Install session token…" flow, which pipes a
///   pasted mint into `clauth login <name> --setup-token --yes` on stdin (the
///   CLI's non-TTY path). Validation here mirrors clauth's
///   `validate_setup_token` so the banner can reject a bad paste live, but
///   the CLI re-validates authoritatively.
enum SessionTokenState: Equatable {
    /// No sidecar — the profile runs on the rotating OAuth pair alone.
    case none
    /// Sidecar present but without a readable `expiresAt` (hand-rolled).
    case unstamped
    /// Sidecar present with its recorded epoch-ms horizon.
    case expires(msEpoch: Int64)
    /// Sidecar holds a ROTATING pair (refresh token present) — a mis-fill,
    /// not a `claude setup-token` mint. clauth DISENGAGES the split for it
    /// (switches install the normal rotating credentials), so displaying the
    /// stamped expiry would claim a protection that is not in force — the
    /// 2026-07-20 incident: ccsbar showed "expires in ~342d" while sessions
    /// died the rotating-pair refresh-race death the split exists to prevent.
    case misfilled
}

enum SessionToken {
    /// The sidecar path for a profile (clauth's layout contract).
    static func sidecarPath(profile: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".clauth/profiles/\(profile)/session-token.json")
    }

    /// Read a profile's sidecar state. Decodes only the expiry; tolerant of
    /// unknown fields. An unreadable/corrupt sidecar reads as `.unstamped`
    /// (present, horizon unknown) — never `.none`, which would hide that a
    /// static token is what switches install.
    static func state(profile: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> SessionTokenState {
        state(at: sidecarPath(profile: profile, home: home))
    }

    static func state(at url: URL) -> SessionTokenState {
        guard FileManager.default.fileExists(atPath: url.path) else { return .none }
        struct Sidecar: Decodable {
            struct OAuth: Decodable {
                let expiresAt: Int64?
                let refreshToken: String?
            }
            let claudeAiOauth: OAuth?
        }
        guard let data = try? Data(contentsOf: url),
              let sidecar = try? JSONDecoder().decode(Sidecar.self, from: data)
        else { return .unstamped }
        // Mirrors clauth's `session_token_status`: a refresh token means a
        // rotating pair, and the split never engages on one — surface THAT,
        // not the (meaningless) stamped expiry. Only presence is checked; the
        // value is never kept.
        if sidecar.claudeAiOauth?.refreshToken != nil { return .misfilled }
        guard let ms = sidecar.claudeAiOauth?.expiresAt else { return .unstamped }
        return .expires(msEpoch: ms)
    }

    /// Client-side echo of clauth's `validate_setup_token` (nil ⇒ valid,
    /// returning the trimmed token via `trimmed`): trimmed, non-empty,
    /// `sk-ant-` prefixed, no interior whitespace, plausible length. The copy
    /// never includes the pasted value.
    static func validationError(_ raw: String) -> String? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty { return nil } // untouched field: no error yet
        if !token.hasPrefix("sk-ant-") {
            return "Doesn't look like a `claude setup-token` mint (expected sk-ant-…)."
        }
        if token.contains(where: { $0.isWhitespace }) {
            return "The paste contains whitespace — looks partial or padded."
        }
        if token.count < 40 {
            return "Too short to be a real mint."
        }
        return nil
    }

    /// The trimmed token, or nil when the field is empty/invalid.
    static func trimmed(_ raw: String) -> String? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, validationError(raw) == nil else { return nil }
        return token
    }

    /// The DetailCard line for a state, `nil` when there is nothing to show.
    /// Day-granular — the horizon is ~a year, and the stamp itself is the
    /// documented lifetime, not a server figure.
    ///
    /// CLA-FEED (`fed`, from status.json `session_feed`): the daemon
    /// re-stamps this sidecar from the usage chain on every rotation, so an
    /// hours-scale expiry is routine maintenance — rendered as a calm
    /// refresh countdown, never the mint's 30-day warning ramp. Expired
    /// stays DANGER either way (a fed token past its stamp means the feeder
    /// is dead — the honest countdown exists to expose exactly that), and a
    /// mis-fill overrides the feed entirely.
    static func statusLine(_ state: SessionTokenState, nowMs: Int64, fed: Bool = false) -> (text: String, tone: Tone)? {
        switch state {
        case .none:
            if fed {
                // Flag on, sidecar not yet armed — the next rotation (or a
                // `clauth feed <p> on` re-run) feeds it.
                return ("Session feed enabled · arming on next rotation", .warning)
            }
            return nil
        case .misfilled:
            return (
                "Long-lived token mis-filled (rotating pair) — not in effect; re-capture via Install token…",
                .danger
            )
        case .unstamped:
            return (fed ? "Fed token · no recorded expiry" : "Long-lived token · no recorded expiry", .normal)
        case .expires(let ms):
            // Gate expiry on the clock, not the truncated day count: integer
            // division reads a token expired <24h ago as `days == 0`, which
            // mislabeled it "~0d" instead of expired (same fix as clauth's).
            let days = (ms - nowMs) / 86_400_000
            if fed {
                if nowMs >= ms {
                    return ("Feed stalled — fed token expired (daemon down or chain dead?)", .danger)
                }
                let hours = (ms - nowMs) / 3_600_000
                if hours > 48 {
                    // A mint-shaped horizon under the feed flag: the static
                    // mint is still installed; the feed supersedes it on the
                    // next rotation / switch.
                    return ("Static mint · feed arms on next rotation", .normal)
                }
                return (hours < 1 ? "Fed token · refreshes in <1h" : "Fed token · refreshes in ~\(hours)h", .normal)
            }
            if nowMs >= ms {
                return ("Long-lived token expired — re-mint: claude setup-token", .danger)
            }
            if days <= 30 {
                return ("Long-lived token · expires in ~\(days)d", .warning)
            }
            return ("Long-lived token · expires in ~\(days)d", .normal)
        }
    }

    enum Tone: Equatable { case normal, warning, danger }
}
