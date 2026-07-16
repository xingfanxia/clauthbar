import Foundation

/// The single field we must read BEFORE a full decode: a schema-2 status.json
/// would fail the `DaemonStatus` decode below, and without this probe that failure
/// is indistinguishable from "no daemon" — sending the operator to debug launchd
/// instead of updating ccsbar (TECH-4 schema gate, #8/#29/#40).
struct SchemaProbe: Decodable, Sendable {
    let schema: Int
}

/// The `status.json` schema this ccsbar build understands. A newer daemon
/// bumps the on-disk `schema`; the gate turns that into an explicit
/// "ccsbar out of date" state instead of a silent blank panel.
let supportedSchema = 1

/// Mirror of `~/.clauth/status.json` (schema 1), written by `clauth daemon`.
/// See clauth's `src/daemon/status_json.rs` for the authoritative shape.
struct DaemonStatus: Codable, Sendable {
    let schema: Int
    let generatedAt: String
    let activeProfile: String?
    let wrapOff: Bool
    let refreshIntervalMs: Int
    /// Ordered fallback-chain member names (the auto-switch order).
    let fallbackChain: [String]
    let profiles: [ProfileStatus]
    /// The clauth binary version that wrote this file (TECH-8/TECH-11) — always
    /// present; drives the soft version-skew badge.
    let clauthVersion: String?
    /// The switch target the daemon accepted but hasn't applied yet, else nil
    /// (AUTH-2). Decoded for forward-compat / contract mirroring; not yet surfaced
    /// in the panel (the settle ladder already tracks in-flight truth via
    /// `activeProfile`). Wire into a "switching…" affordance if it earns one.
    let pendingSwitch: String?
    /// The last executed switch (TECH-8), for the "last switch" line, or nil.
    let lastSwitch: LastSwitch?
    /// The last drain skip/failure reason (TECH-6), or nil.
    let lastError: LastError?
    /// The daemon's OWN next-move forecast (clauth 81c00a2), computed by the same
    /// `fallback::next_target` walk the real switch decision runs — the single
    /// source of truth for every "would switch to X" string. `nil` on older
    /// daemons whose status.json predates the field (then the local
    /// `ForecastEngine` mirror answers instead — see `StatusModel.forecast`).
    let forecast: DaemonForecast?
    /// Whether the daemon's ACTIVE-side switch decision projects on burn rate
    /// (issue #8-b upstream) instead of the static threshold. Additive; `nil` on
    /// older daemons. A daemon new enough to report this also publishes
    /// `forecast`, so the burn-aware gap in the mirror never actually runs.
    let burnAware: Bool?
    /// The chain-wide weekly (7d) exhaustion line (percent) auto-switch gates on
    /// in BOTH walk directions (clauth `weekly_switch_threshold`, default 98).
    /// Additive; `nil` on older daemons → treat as 98 (`ChainEdit.defaultWeeklyLine`).
    let weeklySwitchThreshold: Double?
    /// The codex active slot's profile name (INT-2) — independent of `activeProfile`
    /// (the claude slot). A codex profile and a claude profile can BOTH be active at
    /// once (per-slot truth), so this is a SECOND active pointer, not a replacement.
    /// `nil` on codex-less installs or older daemons.
    let activeCodexProfile: String?
    /// The codex auto-switch chain (INT-2) — same shape as `fallbackChain` but for the
    /// codex slot. Empty on codex-less installs / older daemons. Codex profiles are
    /// NEVER in `fallbackChain`; they live here only. DEFERRED: decoded for contract
    /// conformance, but the codex chain-rail visual editor is not built yet — no panel
    /// surface reads this field.
    let codexFallbackChain: [String]

    enum CodingKeys: String, CodingKey {
        case schema
        case generatedAt = "generated_at"
        case activeProfile = "active_profile"
        case wrapOff = "wrap_off"
        case refreshIntervalMs = "refresh_interval_ms"
        case fallbackChain = "fallback_chain"
        case profiles
        case clauthVersion = "clauth_version"
        case pendingSwitch = "pending_switch"
        case lastSwitch = "last_switch"
        case lastError = "last_error"
        case forecast
        case burnAware = "burn_aware"
        case weeklySwitchThreshold = "weekly_switch_threshold"
        case activeCodexProfile = "active_codex_profile"
        case codexFallbackChain = "codex_fallback_chain"
    }

    /// Decode additively — every field the daemon added after schema 1 is
    /// `decodeIfPresent` so an older daemon's status.json still decodes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        generatedAt = try c.decode(String.self, forKey: .generatedAt)
        activeProfile = try c.decodeIfPresent(String.self, forKey: .activeProfile)
        wrapOff = try c.decode(Bool.self, forKey: .wrapOff)
        refreshIntervalMs = try c.decode(Int.self, forKey: .refreshIntervalMs)
        fallbackChain = try c.decodeIfPresent([String].self, forKey: .fallbackChain) ?? []
        profiles = try c.decode([ProfileStatus].self, forKey: .profiles)
        clauthVersion = try c.decodeIfPresent(String.self, forKey: .clauthVersion)
        pendingSwitch = try c.decodeIfPresent(String.self, forKey: .pendingSwitch)
        lastSwitch = try c.decodeIfPresent(LastSwitch.self, forKey: .lastSwitch)
        lastError = try c.decodeIfPresent(LastError.self, forKey: .lastError)
        forecast = try c.decodeIfPresent(DaemonForecast.self, forKey: .forecast)
        burnAware = try c.decodeIfPresent(Bool.self, forKey: .burnAware)
        weeklySwitchThreshold = try c.decodeIfPresent(Double.self, forKey: .weeklySwitchThreshold)
        activeCodexProfile = try c.decodeIfPresent(String.self, forKey: .activeCodexProfile)
        codexFallbackChain = try c.decodeIfPresent([String].self, forKey: .codexFallbackChain) ?? []
    }
}

/// The daemon's published next-move forecast, mirrored from `status.json.forecast`
/// (clauth 81c00a2). `action` is `"switch"` (with `to`), `"off"` (wrap-off would
/// halt every account), or `"none"` (nothing viable / no chain).
struct DaemonForecast: Codable, Sendable, Equatable {
    let action: String
    let to: String?

    /// Map the published forecast onto the UI's forecast enum. An unknown action
    /// — or a `"switch"` with a null `to` — reads as `.none` rather than throwing,
    /// so a future action variant degrades to "no rotation target".
    var outcome: ForecastEngine.Outcome {
        switch action {
        case "switch": return to.map(ForecastEngine.Outcome.switchTo) ?? .none
        case "off": return .off
        default: return .none
        }
    }
}

/// The last executed switch, mirrored from `status.json.last_switch` (TECH-8).
struct LastSwitch: Codable, Sendable, Equatable {
    let from: String?
    let to: String?
    let at: String
    /// `"user"` (socket tap), `"scheduler"` (auto), or `"wrap_off"`.
    let trigger: String
}

/// The last drain skip/failure reason, mirrored from `status.json.last_error` (TECH-6).
struct LastError: Codable, Sendable, Equatable {
    let at: String
    let message: String
}

struct ProfileStatus: Codable, Sendable, Identifiable {
    var id: String { name }
    let name: String
    let active: Bool
    let provider: String
    let baseUrl: String?
    let tier: String?
    let hasLiveSession: Bool
    let fetchStatus: String?
    let fetchedAt: String?
    let nextRefreshAt: String?
    let autoStart: Bool
    let bellThreshold: Double?
    let fallback: FallbackInfo?
    let windows: [UsageWindow]
    let thirdParty: ThirdPartyInfo?
    /// AUTH-2 per-profile auth status: "ok" | "expiring" | "broken"; absent = ok
    /// (older daemons). Drives the forecast engine's auth-broken skip (AUTH-1) and
    /// the red auth badge — a revoked login must never be a rotation target.
    let authStatus: String?
    /// CAP-3: the account email this profile's stored login belongs to (the
    /// identity anchor's readable half, backfilled by the daemon's /profile
    /// fetch). Absent on older daemons or before the first backfill. Shown so
    /// a wrong-account capture is visible at a glance — the 2026-07-12
    /// double-poll incident was invisible precisely because nothing displayed
    /// WHICH account each profile held.
    let accountEmail: String?
    /// INT-2: which harness this profile belongs to — `"codex"` for a codex profile,
    /// else `"claude"`/absent (default). Distinguishes the two independent active
    /// slots so two simultaneously-`active` rows read as two slots, not a bug.
    let harness: String?
    /// INT-2 (codex-only): when the stored codex login was last captured/adopted
    /// (ISO-8601). A CREDENTIAL age — distinct from usage freshness (`fetchedAt`) and
    /// window resets. `nil` for claude profiles / older daemons.
    let codexSnapshotAt: String?
    /// INT-2 (codex-only): codex's OWN limiter verdict on the last request —
    /// `"primary"` (5h window) or `"secondary"` (7d window) rejected it. `nil` when
    /// not rate-limited, for claude profiles, or older daemons.
    let codexRateLimitReached: String?

    enum CodingKeys: String, CodingKey {
        case name, active, provider, tier, fallback, windows, harness
        case authStatus = "auth_status"
        case accountEmail = "account_email"
        case baseUrl = "base_url"
        case hasLiveSession = "has_live_session"
        case fetchStatus = "fetch_status"
        case fetchedAt = "fetched_at"
        case nextRefreshAt = "next_refresh_at"
        case autoStart = "auto_start"
        case bellThreshold = "bell_threshold"
        case thirdParty = "third_party"
        case codexSnapshotAt = "codex_snapshot_at"
        case codexRateLimitReached = "codex_rate_limit_reached"
    }

    /// Lenient decode (TECH-4): only `name` + `active` are load-bearing; every
    /// other field falls back to a benign default so a missing/renamed non-critical
    /// field in an additive-era status.json can't throw and blank the whole panel.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? false
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "anthropic"
        baseUrl = try c.decodeIfPresent(String.self, forKey: .baseUrl)
        tier = try c.decodeIfPresent(String.self, forKey: .tier)
        hasLiveSession = try c.decodeIfPresent(Bool.self, forKey: .hasLiveSession) ?? false
        fetchStatus = try c.decodeIfPresent(String.self, forKey: .fetchStatus)
        fetchedAt = try c.decodeIfPresent(String.self, forKey: .fetchedAt)
        nextRefreshAt = try c.decodeIfPresent(String.self, forKey: .nextRefreshAt)
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
        bellThreshold = try c.decodeIfPresent(Double.self, forKey: .bellThreshold)
        fallback = try c.decodeIfPresent(FallbackInfo.self, forKey: .fallback)
        windows = try c.decodeIfPresent([UsageWindow].self, forKey: .windows) ?? []
        thirdParty = try c.decodeIfPresent(ThirdPartyInfo.self, forKey: .thirdParty)
        authStatus = try c.decodeIfPresent(String.self, forKey: .authStatus)
        accountEmail = try c.decodeIfPresent(String.self, forKey: .accountEmail)
        harness = try c.decodeIfPresent(String.self, forKey: .harness)
        codexSnapshotAt = try c.decodeIfPresent(String.self, forKey: .codexSnapshotAt)
        codexRateLimitReached = try c.decodeIfPresent(String.self, forKey: .codexRateLimitReached)
    }

    /// The window with the given label (`"5h"`, `"7d"`, `"7d fable"`), or nil.
    func window(_ label: String) -> UsageWindow? { windows.first { $0.label == label } }

    /// The 5-hour window — the one that actually throttles a session.
    var fiveHour: UsageWindow? { window("5h") }
    var fiveHourPct: Double { fiveHour?.utilizationPct ?? 0 }

    /// The 7-day rolling window (weekly limit). `"7d"` is a clauth compile-time
    /// constant, so an exact match is safe.
    var sevenDay: UsageWindow? { window("7d") }

    /// The 7-day Fable-model window (fable weekly limit). Matched leniently: clauth
    /// derives this label from the server's model display name
    /// (`"7d " + display_name.lowercased()`), so it can be `"7d fable"`,
    /// `"7d fable 5"`, etc. Key on the `"7d …fable…"` shape, not an exact string.
    var fableWeek: UsageWindow? {
        windows.first { $0.label.hasPrefix("7d ") && $0.label.lowercased().contains("fable") }
    }

    /// INT-2: a codex-harness profile (the codex active slot's truth). A codex row
    /// and a claude row can both be `active` at once — this tells them apart.
    var isCodex: Bool { harness == "codex" }

    /// Is this profile a member of the fallback chain?
    var inChain: Bool { fallback != nil }

    /// Freshness cue: numbers are trustworthy only on a live ("Fresh") read.
    var isStale: Bool { fetchStatus != nil && fetchStatus != "Fresh" }

    /// AUTH-1: a revoked/dead login the daemon must never rotate into (forecast
    /// engine skips it like an exhausted member).
    var authBroken: Bool { authStatus == "broken" }
}

struct FallbackInfo: Codable, Sendable {
    let position: Int
    let threshold: Double
    let armed: Bool
    /// The exclusive last-resort mark (clauth 81c00a2): the walk's sink pass
    /// accepts this member even while exhausted. Additive — absent on older
    /// daemons, decoded as `false`. Drives `ForecastEngine`'s pass 2 in the
    /// fallback (no-published-forecast) path.
    let lastResort: Bool

    enum CodingKeys: String, CodingKey {
        case position, threshold, armed
        case lastResort = "last_resort"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        position = try c.decode(Int.self, forKey: .position)
        threshold = try c.decode(Double.self, forKey: .threshold)
        armed = try c.decode(Bool.self, forKey: .armed)
        lastResort = try c.decodeIfPresent(Bool.self, forKey: .lastResort) ?? false
    }
}

struct UsageWindow: Codable, Sendable, Identifiable {
    var id: String { label }
    let label: String
    let utilizationPct: Double
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case label
        case utilizationPct = "utilization_pct"
        case resetsAt = "resets_at"
    }
}

struct ThirdPartyInfo: Codable, Sendable {
    let available: Bool
}
