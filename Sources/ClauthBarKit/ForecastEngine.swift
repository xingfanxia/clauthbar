import Foundation

/// Predicts the daemon's NEXT auto-switch target — the truthfulness core behind
/// every "would switch to X" string in the UI. A PURE mirror of clauth's
/// `src/fallback.rs::next_target` (fallback.rs:154-206, chain walk at :127-152);
/// naive position+1 is banned (design §8 Watchtower graft, risk register #2).
///
/// CONTRACT — kept in lockstep with the Rust walk (fixture tests + line pins are
/// mandatory, not optional):
///   - `threshold_for(p)` = `fallback_threshold ?? 95` (fallback.rs:24, DEFAULT 95).
///   - `is_exhausted(p)` = 5h window is LIVE (`resets_at` in the future) AND its
///     utilization ≥ threshold (fallback.rs:33). A lapsed/absent window = headroom.
///   - Walk from one slot after the active profile, wrapping; skip the active slot,
///     a member with no matching profile, or an auth-broken member (AUTH-1).
///   - Pass 1: first member with headroom. Pass 2 (only if the active is NOT itself
///     a 100% sink): first 100%-threshold sink. Then wrap-off → OFF only when the
///     active is itself exhausted. Else nothing.
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

        // is_exhausted (fallback.rs:33): only a LIVE 5h window (resets_at in the
        // future) can exhaust; a lapsed/absent window means headroom again.
        func exhausted(_ p: ProfileStatus) -> Bool {
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

        // Pass 1 — headroom (fallback.rs:189).
        if let name = walk({ !exhausted($0) }) { return .switchTo(name) }

        // Two maxed sinks rotating into each other gains nothing (fallback.rs:194).
        let activeIsSink = profile(active).map { thresholdFor($0) >= 100 } ?? false
        if activeIsSink { return .none }

        // Pass 2 — 100% sink (fallback.rs:201).
        if let name = walk({ thresholdFor($0) >= 100 }) { return .switchTo(name) }

        // Wrap-off → OFF, only when the active is itself exhausted (fallback.rs:207).
        if status.wrapOff, let ap = profile(active), exhausted(ap) { return .off }
        return .none
    }
}
