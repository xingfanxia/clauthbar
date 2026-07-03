import AppKit

/// Palette + usage helpers mapped from clauth's TUI (Catppuccin Mocha,
/// `src/tui/theme.rs`). Brand + usage hues only; structural text uses semantic
/// NSColors so it flips correctly in light/dark.
enum Theme {
    // Catppuccin Mocha values used for brand + usage semantics.
    static let orange = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1) // #D97757 accent_2 (active)
    static let sapphire = NSColor(srgbRed: 0.263, green: 0.671, blue: 0.898, alpha: 1) // #43ABE5 accent (focus)
    static let textDim = NSColor(srgbRed: 0.651, green: 0.678, blue: 0.784, alpha: 1) // #A6ADC8 (<60%)
    static let warning = NSColor(srgbRed: 0.976, green: 0.886, blue: 0.686, alpha: 1) // #F9E2AF (60–80%)
    static let danger = NSColor(srgbRed: 0.953, green: 0.545, blue: 0.659, alpha: 1) // #F38BA8 (≥80%)
    static let success = NSColor(srgbRed: 0.651, green: 0.890, blue: 0.631, alpha: 1) // #A6E3A1
    static let lineStrong = NSColor(srgbRed: 0.271, green: 0.278, blue: 0.353, alpha: 1) // #45475A (track)

    /// clauth's `util_color(pct)`: neutral < 60, warning 60–80, danger ≥ 80.
    static func utilColor(_ pct: Double) -> NSColor {
        switch pct {
        case ..<60: return textDim
        case ..<80: return warning
        default: return danger
        }
    }

    /// clauth's `health_color(pct, threshold)` for fallback-chain members.
    static func healthColor(_ pct: Double, threshold: Double) -> NSColor {
        if pct >= threshold { return danger }
        if pct >= 0.8 * threshold { return warning }
        return success
    }

    /// A fixed-width text usage bar, e.g. `████████░░░░░░░░`, colored by `color`.
    /// `cells` block characters; fill = round(pct/100 * cells).
    static func bar(pct: Double, cells: Int = 14, color: NSColor) -> NSAttributedString {
        let clamped = max(0, min(100, pct))
        let filled = Int((clamped / 100.0 * Double(cells)).rounded())
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(
            string: String(repeating: "█", count: filled),
            attributes: [.foregroundColor: color]
        ))
        s.append(NSAttributedString(
            string: String(repeating: "░", count: cells - filled),
            attributes: [.foregroundColor: lineStrong]
        ))
        return s
    }
}
