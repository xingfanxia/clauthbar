import Foundation

/// Predicts the daemon's NEXT auto-switch target — the FALLBACK truthfulness core
/// behind every "would switch to X" string when the daemon is too old to publish
/// its own forecast. A daemon at clauth 81c00a2+ writes `status.json.forecast`
/// (computed by the exact Rust walk); `StatusModel.forecast` prefers that and only
/// drops to this mirror for older daemons. A PURE mirror of clauth's
/// `src/fallback.rs::next_target` (fallback.rs:336-393, chain walk at :301-317);
/// naive position+1 is banned (design §8 Watchtower graft, risk register #2).
///
/// CONTRACT — mirrors `fallback.rs::next_target` as of clauth 81c00a2 (fixture
/// tests + line pins are mandatory, not optional):
///   - `threshold_for(p)` = `fallback_threshold ?? 95` (fallback.rs:27, DEFAULT 95).
///   - `is_exhausted(p)` = 5h window is LIVE (`resets_at` in the future) AND its
///     utilization ≥ threshold (fallback.rs:51). A lapsed/absent window = headroom.
///   - Walk from one slot after the active profile, wrapping; skip the active slot,
///     a member with no matching profile, or an auth-broken member (AUTH-1,
///     fallback.rs:348).
///   - Pass 1 (fallback.rs:358): first member with headroom.
///   - Pass 2 (fallback.rs:366-372): the EXCLUSIVE last-resort rule — first member
///     whose `fallback.last_resort` flag is set, accepted even while exhausted; but
///     if the ACTIVE profile is itself `last_resort`, return `.none` (no
///     last-resort ping-pong). The old "threshold == 100 sink" convention is GONE —
///     do NOT reintroduce it; it is wrong against any current daemon.
///   - Wrap-off → OFF (fallback.rs:380-391): only when wrap_off is on AND the active
///     is itself exhausted.
///
/// BURN-AWARE GAP (accepted): the Rust wrap-off check is burn-aware — it projects
/// the active's exhaustion on `current + burn_rate × interval` when
/// `burn_aware_switching` is on. This mirror uses the STATIC `is_exhausted` because
/// status.json carries no burn rates. That is fine: any daemon new enough to run
/// burn-aware switching (and set `burn_aware`) also publishes `forecast`, so this
/// mirror never runs for it — it only ever answers for pre-forecast daemons, which
/// are pre-burn-aware too.
enum ForecastEngine {
    /// What the daemon would do next, given the current snapshot.
    enum Outcome: Equatable, Sendable {
        case switchTo(String) // would rotate to this chain member
        case off              // wrap-off: would switch every account off
        case none             // nothing viable (no forecast to show)
    }

    /// `now` is injected so the `five_hour_live` clock is deterministic in tests.
    static func nextTarget(_ status: DaemonStatus, now: Date) -> Outcome {
        guard let active = status.activeProfile,
              let activeIdx = status.fallbackChain.firstIndex(of: active) else {
            return .none
        }
        let chain = status.fallbackChain
        let len = chain.count

        func profile(_ name: String) -> ProfileStatus? { status.profiles.first { $0.name == name } }
        func thresholdFor(_ p: ProfileStatus) -> Double { p.fallback?.threshold ?? 95 }

        // weekly_blocked (fallback.rs): a LIVE overall 7d window past the
        // chain-wide weekly line (clauth `weekly_switch_threshold`, default 98 —
        // a SOFT line below the API's 100% cap since 2026-07-12) counts the
        // account as spent until its weekly reset — its idle 5h window (often
        // lapsed entirely) would otherwise read as fresh headroom.
        let weeklyLine = status.weeklySwitchThreshold ?? ChainEdit.defaultWeeklyLine
        func weeklyBlocked(_ p: ProfileStatus) -> Bool {
            guard let w = p.sevenDay,
                  let resetsAt = w.resetsAt,
                  let resets = Theme.parseISO(resetsAt),
                  resets > now
            else { return false }
            return w.utilizationPct >= weeklyLine
        }

        // is_exhausted (fallback.rs): weekly line first, else only a LIVE 5h
        // window (resets_at in the future) can exhaust; a lapsed/absent window
        // means headroom again.
        func exhausted(_ p: ProfileStatus) -> Bool {
            if weeklyBlocked(p) { return true }
            guard let w = p.fiveHour,
                  let resetsAt = w.resetsAt,
                  let resets = Theme.parseISO(resetsAt),
                  resets > now
            else { return false }
            return w.utilizationPct >= thresholdFor(p)
        }

        // skip (fallback.rs:170): active slot, unresolvable member, auth-broken.
        func skip(_ i: Int) -> Bool {
            chain[i] == active || profile(chain[i]) == nil || (profile(chain[i])?.authBroken ?? false)
        }

        // walk_chain (fallback.rs:127): first accepted slot after activeIdx, wrapping.
        func walk(_ accept: (ProfileStatus) -> Bool) -> String? {
            for offset in 1...len {
                let i = (activeIdx + offset) % len
                if skip(i) { continue }
                if let p = profile(chain[i]), accept(p) { return chain[i] }
            }
            return nil
        }

        // Pass 1 — headroom (fallback.rs:358).
        if let name = walk({ !exhausted($0) }) { return .switchTo(name) }

        // Two last-resort members rotating into each other gains nothing: if the
        // ACTIVE is itself last_resort, park (fallback.rs:366-369).
        let activeIsLastResort = profile(active)?.fallback?.lastResort ?? false
        if activeIsLastResort { return .none }

        // Pass 2 — the exclusive last-resort mark (fallback.rs:370): first member
        // flagged `last_resort`, accepted even while exhausted. (The old
        // threshold-100 sink convention is gone — see the CONTRACT.)
        if let name = walk({ $0.fallback?.lastResort ?? false }) { return .switchTo(name) }

        // Wrap-off → OFF, only when the active is itself exhausted (fallback.rs:380).
        // STATIC exhaustion here; the Rust twin is burn-aware — see the BURN-AWARE
        // GAP note on the enum (never runs for a forecast-publishing daemon).
        if status.wrapOff, let ap = profile(active), exhausted(ap) { return .off }
        return .none
    }
}
