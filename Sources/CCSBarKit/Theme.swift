import AppKit
import SwiftUI

/// Palette + usage helpers. Four color ROLES, one meaning per hue (CBAR-4-DESIGN
/// §5): terracotta = ACTIVE, darkened terracotta = the ACT verb, sapphire =
/// ARMED/WATCHING, and green/amber/red = HEADROOM/HEALTH. Structural text uses
/// semantic colors so it flips correctly in light/dark.
enum Theme {
    /// #D97757 terracotta — ACTIVE only (checkmark, active-name tint, active
    /// outline). Never armed, never a healthy bar, never generic-interactive.
    static let accent = Color(.sRGB, red: 0.851, green: 0.467, blue: 0.341)
    /// #B85C33 darkened terracotta — the ACT verb: fill of the "Switch to X"
    /// button under white text (≥4.5:1 AA). The brand hue acts only where the
    /// user acts.
    static let actVerb = Color(.sRGB, red: 0.722, green: 0.361, blue: 0.200)
    /// #43ABE5 sapphire — ARMED / WATCHING / auto-switch identity (forecast bolt,
    /// armed chip ring, pending-switch pulse).
    static let sapphire = Color(.sRGB, red: 0.263, green: 0.671, blue: 0.898)
    /// #49A3B0 — codexbar's OWN codex brand color, copied VERBATIM from its
    /// provider color map (CodexProviderDescriptor → ProviderBranding →
    /// `ProviderColor(red: 73/255, green: 163/255, blue: 176/255)`). Every
    /// codex identity surface (tab pill, active marks, verb fills) uses this;
    /// claude keeps its terracotta — one brand hue per provider, per the map.
    static let codex = Color(.sRGB, red: 73.0 / 255, green: 163.0 / 255, blue: 176.0 / 255)

    // HEADROOM/HEALTH as light/dark DYNAMIC pairs (Catppuccin Latte in light,
    // Mocha in dark) — fixes the 1.3–2.3:1 light-mode contrast failures the flat
    // Mocha hues had. green = live/healthy, amber = nearing, red = at/over.
    static let success = dynamic(light: 0x40A02B, dark: 0xA6E3A1)
    static let warning = dynamic(light: 0xDF8E1D, dark: 0xF9E2AF)
    static let danger = dynamic(light: 0xD20F39, dark: 0xF38BA8)

    /// Progress-bar track — a faint neutral that adapts to light/dark.
    static let track = Color.primary.opacity(0.10)

    /// A hue that swaps between a Latte (light) and Mocha (dark) hex by the system
    /// appearance, so headroom colors keep AA contrast in both modes.
    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return nsColor(hex: isDark ? dark : light)
        })
    }

    private static func nsColor(hex: Int) -> NSColor {
        NSColor(srgbRed: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255,
                alpha: 1)
    }

    /// Bar fill by utilization, keyed to the account's OWN threshold (§5): green
    /// headroom → amber at ≥0.8×threshold → red at ≥threshold. Threshold defaults
    /// to 100 for windows with no fallback threshold. Terracotta is NOT used here —
    /// a healthy bar is green, not the (active-only) brand hue.
    static func usageColor(_ pct: Double, threshold: Double = 100) -> Color {
        if pct >= threshold { return danger }
        if pct >= 0.8 * threshold { return warning }
        return success
    }

    /// Parse an ISO-8601 timestamp as the daemon writes it. `resets_at` carries
    /// microseconds (`…T14:19:59.519183+00:00`), which the plain
    /// `.withInternetDateTime` parser rejects — try fractional first, then plain,
    /// then strip the sub-second digits (`.withFractionalSeconds` only promises
    /// milliseconds, not the daemon's 6 digits).
    static func parseISO(_ iso: String) -> Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = parser.date(from: iso) { return d }
        parser.formatOptions = [.withInternetDateTime]
        if let d = parser.date(from: iso) { return d }
        let stripped = iso.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return parser.date(from: stripped)
    }

    /// Compact "resets in" hint from an ISO-8601 timestamp — `resets in 5d 16h`,
    /// `resets in 3h 20m`, `resets in 12m`, or nil when absent or already past.
    /// Two units max, coarsest first (weekly windows read in days, not "136h").
    static func resetHint(_ iso: String?) -> String? {
        guard let iso, let date = parseISO(iso) else { return nil }
        return resetHintText(secondsRemaining: Int(date.timeIntervalSinceNow))
    }

    /// Pure d/h/m formatting — the finding-prone bit, split from the `Date.now`
    /// read so the boundary logic is deterministically unit-testable (the clock is
    /// the caller's). `secs <= 0` (already past) → nil.
    static func resetHintText(secondsRemaining secs: Int) -> String? {
        guard secs > 0 else { return nil }
        let d = secs / 86_400
        let h = (secs % 86_400) / 3600
        let m = (secs % 3600) / 60
        if d > 0 { return h > 0 ? "resets in \(d)d \(h)h" : "resets in \(d)d" }
        if h > 0 { return m > 0 ? "resets in \(h)h \(m)m" : "resets in \(h)h" }
        return "resets in \(m)m"
    }
}

/// A thin rounded usage bar — the CodexBar-style meter. Track + fill, clamped to
/// 0…100, with an optional in-track threshold tick (design §8 Roster graft): a
/// hairline at the account's own auto-switch threshold so the distance-to-rotation
/// is a pre-attentive visible gap.
struct UsageBar: View {
    let pct: Double
    let color: Color
    var height: CGFloat = 6
    /// The account's 5h auto-switch threshold (0…100); nil hides the tick. Ticks at
    /// 100 (the sink / no-threshold windows) are suppressed — a tick at the bar end
    /// is noise.
    var threshold: Double? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(1, pct / 100)) * geo.size.width)
                if let threshold, threshold > 0, threshold < 100 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: 1.5, height: height)
                        .offset(x: min(1, threshold / 100) * geo.size.width - 0.75)
                }
            }
        }
        .frame(height: height)
        .accessibilityLabel("\(Int(pct.rounded())) percent used")
    }
}
