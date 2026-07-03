import Foundation

/// Mirror of `~/.clauth/status.json` (schema 1), written by `clauth daemon`.
/// See clauth's `src/daemon/status_json.rs` for the authoritative shape.
struct DaemonStatus: Codable, Sendable {
    let schema: Int
    let generatedAt: String
    let activeProfile: String?
    let wrapOff: Bool
    let refreshIntervalMs: Int
    let profiles: [ProfileStatus]

    enum CodingKeys: String, CodingKey {
        case schema
        case generatedAt = "generated_at"
        case activeProfile = "active_profile"
        case wrapOff = "wrap_off"
        case refreshIntervalMs = "refresh_interval_ms"
        case profiles
    }
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

    enum CodingKeys: String, CodingKey {
        case name, active, provider, tier, fallback, windows
        case baseUrl = "base_url"
        case hasLiveSession = "has_live_session"
        case fetchStatus = "fetch_status"
        case fetchedAt = "fetched_at"
        case nextRefreshAt = "next_refresh_at"
        case autoStart = "auto_start"
        case bellThreshold = "bell_threshold"
        case thirdParty = "third_party"
    }

    /// The 5-hour window — the one that actually throttles a session.
    var fiveHour: UsageWindow? { windows.first { $0.label == "5h" } }
    var fiveHourPct: Double { fiveHour?.utilizationPct ?? 0 }

    /// Freshness cue: numbers are trustworthy only on a live ("Fresh") read.
    var isStale: Bool { fetchStatus != nil && fetchStatus != "Fresh" }
}

struct FallbackInfo: Codable, Sendable {
    let position: Int
    let threshold: Double
    let armed: Bool
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
