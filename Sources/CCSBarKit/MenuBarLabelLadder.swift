import Foundation

/// The menu-bar label as a PURE priority ladder (CBAR4-6, design §6). ALL state is
/// encoded in SF Symbol SHAPE, never color — the menu bar template-renders and
/// flattens custom hues, so a gauge/warning/rotation/power/bolt-slash glyph is the
/// only reliable state channel. The `%` always means the ACTIVE account's 5h window
/// (the same number the forecast sentence explains inside the panel).
///
/// Priority (highest wins): dead > switch-in-flight > rotation-flash > wrap-off-all
/// > no-status > 5h≥threshold > 5h≥0.8×threshold > (normal), with an auto-switch-
/// disarmed bolt-slash APPENDED to the normal rungs.
enum MenuBarLabelLadder {
    /// A resolved label. The view maps `symbol`/`trailingSymbol` to SF Symbols and
    /// renders `text` in 13pt monospaced-digit; `nearThresholdDot` draws the small
    /// gauge dot badge; `availabilityDot` is the third-party up/down dot.
    struct Spec: Equatable, Sendable {
        var symbol: String
        var text: String
        var trailingSymbol: String? = nil
        var nearThresholdDot: Bool = false
        var availabilityDot: Bool? = nil // nil = none; true/false = up/down
    }

    private static let gauge = "gauge.with.dots.needle.bottom.50percent"
    private static let gaugeHigh = "gauge.with.dots.needle.bottom.100percent"

    static func spec(
        status: DaemonStatus?,
        switchInFlight: Bool,
        rotationFlash: String?,
        now: Date
    ) -> Spec {
        let genAge = status.flatMap { Theme.parseISO($0.generatedAt) }.map { now.timeIntervalSince($0) }
        let dead = genAge.map { LivenessLadder.freshness(ageSeconds: $0) == .dead } ?? false

        // (1) DAEMON DEAD — frozen numbers must never impersonate live ones: withhold
        // the %, show the frozen age with a warning triangle.
        if let s = status, dead {
            return Spec(symbol: "exclamationmark.triangle.fill",
                        text: "\(name(s)) \(coarseAge(genAge ?? 0))")
        }
        // (2) SWITCH IN FLIGHT — current label + trailing ellipsis.
        if switchInFlight {
            return Spec(symbol: gauge, text: "\(status.map(name) ?? "")…")
        }
        // (3) ROTATION FLASH — the auto-switch heartbeat, visible without opening up.
        if let rotated = rotationFlash {
            return Spec(symbol: "arrow.left.arrow.right", text: truncated(rotated))
        }
        // (4) WRAP-OFF ALL-OFF — daemon alive, no active account.
        if let s = status, s.activeProfile == nil {
            return Spec(symbol: "powersleep", text: "off")
        }
        // (5) NO status.json — bare gauge, nothing to report.
        guard let s = status, let active = s.profiles.first(where: { $0.active }) else {
            return Spec(symbol: gauge, text: "")
        }

        // Third-party active: availability dot, never a %.
        if active.provider != "anthropic" {
            return Spec(symbol: gauge, text: truncated(active.name),
                        availabilityDot: active.thirdParty?.available ?? false)
        }

        // (8) auto-switch DISARMED (chain empty, or non-empty with zero armed) —
        // appended to whatever the normal rung is, so a broken chain shows from the bar.
        let armedCount = s.profiles.filter { $0.fallback?.armed == true }.count
        let disarmed = s.fallbackChain.isEmpty || armedCount == 0
        let trailing = disarmed ? "bolt.slash" : nil

        // No 5h data yet — bare gauge + name, no misleading 0%.
        guard let pct = active.fiveHour.map({ $0.utilizationPct }) else {
            return Spec(symbol: gauge, text: truncated(active.name), trailingSymbol: trailing)
        }
        let threshold = active.fallback?.threshold ?? 100
        let text = "\(truncated(active.name)) \(Int(pct.rounded()))%"

        // (6) 5h ≥ threshold, (7) ≥ 0.8×threshold, (9) normal.
        if pct >= threshold {
            return Spec(symbol: gaugeHigh, text: text, trailingSymbol: trailing)
        }
        if pct >= 0.8 * threshold {
            return Spec(symbol: gauge, text: text, trailingSymbol: trailing, nearThresholdDot: true)
        }
        return Spec(symbol: gauge, text: text, trailingSymbol: trailing)
    }

    /// The active account name, tail-truncated to the label's 12-char budget.
    private static func name(_ s: DaemonStatus) -> String {
        truncated(s.activeProfile ?? s.profiles.first(where: { $0.active })?.name ?? "")
    }

    private static func truncated(_ s: String) -> String {
        s.count <= 12 ? s : String(s.prefix(11)) + "…"
    }

    /// Coarse "Ns/Nm/Nh/Nd" for the frozen-age stamp on the dead label.
    private static func coarseAge(_ secs: Double) -> String {
        let s = Int(max(0, secs))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }
}
