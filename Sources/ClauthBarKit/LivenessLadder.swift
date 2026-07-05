import Foundation

/// Graded daemon freshness on the 1s UI clock (design §8/§9 — Roster graft that
/// supersedes Preflight's binary 10s cliff). The daemon rewrites `status.json`
/// every ~1s tick, so the file's age is a DIRECT liveness signal:
///
///   - `.live`    (< 5s)   green pulse — ticking normally.
///   - `.syncing` (5–15s)  grey "syncing…" — a momentary stall (e.g. a switch's
///                         ~3s Keychain rewrite), NOT yet an alarm.
///   - `.dead`    (≥ 15s)  red banner — it stopped ticking.
///
/// Keyed to the FIXED 1s write cadence, NEVER `refresh_interval_ms` (the ~90s
/// usage refetch): a dead daemon must read dead in 15s, not minutes. This is the
/// same cadence-vs-refetch trap TECH-12's doctor freshness fixed on the Rust side.
enum LivenessLadder {
    enum Freshness: Equatable, Sendable { case live, syncing, dead }

    /// The bands, from a single age in seconds.
    static func freshness(ageSeconds: Double) -> Freshness {
        if ageSeconds < 5 { return .live }
        if ageSeconds < 15 { return .syncing }
        return .dead
    }

    /// From `generated_at` age plus a `statusMtime()` cross-check: trust the
    /// YOUNGER of the two ages as evidence of life — a fresh file mtime with an
    /// unparseable/skewed `generated_at` (or vice versa) still means the daemon is
    /// writing. Both ages nil → treat as dead.
    static func freshness(generatedAtAge: Double?, statusMtimeAge: Double?) -> Freshness {
        let ages = [generatedAtAge, statusMtimeAge].compactMap { $0 }
        guard let youngest = ages.min() else { return .dead }
        return freshness(ageSeconds: youngest)
    }
}
