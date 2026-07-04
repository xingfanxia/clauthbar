import SwiftUI

/// Palette + usage helpers mapped from clauth's TUI (Catppuccin Mocha,
/// `src/tui/theme.rs`). Brand + usage hues only; structural text uses semantic
/// colors so it flips correctly in light/dark.
enum Theme {
    // Catppuccin Mocha brand + usage semantics.
    static let accent = Color(.sRGB, red: 0.851, green: 0.467, blue: 0.341) // #D97757 terracotta (active/healthy)
    static let sapphire = Color(.sRGB, red: 0.263, green: 0.671, blue: 0.898) // #43ABE5 (focus/armed)
    static let warning = Color(.sRGB, red: 0.976, green: 0.886, blue: 0.686) // #F9E2AF (nearing limit)
    static let danger = Color(.sRGB, red: 0.953, green: 0.545, blue: 0.659) // #F38BA8 (at/over limit)
    static let success = Color(.sRGB, red: 0.651, green: 0.890, blue: 0.631) // #A6E3A1

    /// Progress-bar track — a faint neutral that adapts to light/dark.
    static let track = Color.primary.opacity(0.10)

    /// Bar fill by utilization: healthy stays on the brand accent (CodexBar-like),
    /// then warns and turns danger as it approaches the given threshold (100 for
    /// windows with no fallback threshold). Keeps low usage pretty, high usage loud.
    static func usageColor(_ pct: Double, threshold: Double = 100) -> Color {
        if pct >= threshold { return danger }
        if pct >= 0.8 * threshold { return warning }
        return accent
    }

    /// Compact "resets in" hint from an ISO-8601 timestamp — `resets in 5d 16h`,
    /// `resets in 3h 20m`, `resets in 12m`, or nil when absent or already past.
    /// Two units max, coarsest first (weekly windows read in days, not "136h").
    static func resetHint(_ iso: String?) -> String? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        guard let iso, let date = parser.date(from: iso) else { return nil }
        let secs = Int(date.timeIntervalSinceNow)
        guard secs > 0 else { return nil }
        let d = secs / 86_400
        let h = (secs % 86_400) / 3600
        let m = (secs % 3600) / 60
        if d > 0 { return h > 0 ? "resets in \(d)d \(h)h" : "resets in \(d)d" }
        if h > 0 { return m > 0 ? "resets in \(h)h \(m)m" : "resets in \(h)h" }
        return "resets in \(m)m"
    }
}

/// A thin rounded usage bar — the CodexBar-style meter. Track + accent fill,
/// clamped to 0…100.
struct UsageBar: View {
    let pct: Double
    let color: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(1, pct / 100)) * geo.size.width)
            }
        }
        .frame(height: height)
        .accessibilityLabel("\(Int(pct.rounded())) percent used")
    }
}
