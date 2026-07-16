import SwiftUI

/// The panel's top-level pages (TABS-1, codexbar-style): a cross-harness glance
/// page plus one management page per harness. Tabs exist only for harnesses clauth
/// actually supports — no dead chrome for providers it can't switch.
enum ProviderTab: String, CaseIterable, Sendable {
    case overview, claude, codex

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    /// SF Symbol per tab — native glyphs, not brand bitmaps (license-clean and
    /// they template-render correctly in both appearances).
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .claude: return "sparkle"
        case .codex: return "hexagon"
        }
    }

    /// The harness a tab manages; nil for the Overview glance page.
    var harness: Harness? {
        switch self {
        case .overview: return nil
        case .claude: return .claude
        case .codex: return .codex
        }
    }

    /// UserDefaults key for the persisted selection (read/written by StatusModel —
    /// NOT @AppStorage: a DynamicProperty inside an ObservableObject never
    /// publishes, so the model persists manually and publishes via @Published).
    static let persistenceKey = "providerTab"
}

/// The codexbar-style top tab bar: three equal segments (glyph + label), the
/// selected one filled in the accent wash, and — the signature detail — a small
/// usage-colored underline bar per harness tab showing that harness's ACTIVE
/// account 5h burn, so "which agent is near its limit" is answered without
/// entering the tab. Overview carries no underline (nothing to summarize into 3pt).
struct ProviderTabBar: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(ProviderTab.allCases.enumerated()), id: \.element) { i, tab in
                segment(tab, index: i)
            }
        }
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Provider pages")
    }

    private func segment(_ tab: ProviderTab, index: Int) -> some View {
        let selected = model.tab == tab
        return Button {
            model.tab = tab
        } label: {
            VStack(spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: tab.symbol).font(.system(size: 11))
                    Text(tab.title).font(.subheadline).fontWeight(selected ? .semibold : .regular)
                }
                underline(for: tab)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(TabSegmentStyle(selected: selected))
        // ⌘1/⌘2/⌘3 jump straight to a page.
        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
        .accessibilityLabel("\(tab.title) tab")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// The 3pt usage underline: the harness's active-account 5h % in the shared
    /// usage color ramp. Hidden (clear, height-preserving) when the tab has no
    /// harness or the harness has no active account — labels stay vertically
    /// aligned across segments. Decorative: the rows/detail read the real numbers.
    @ViewBuilder private func underline(for tab: ProviderTab) -> some View {
        let active = tab.harness.flatMap { model.activeProfile(for: $0) }
        let pct = active?.fiveHourPct
        UsageBar(
            pct: pct ?? 0,
            color: pct.map { Theme.usageColor($0, threshold: active?.fallback?.threshold ?? 100) } ?? .clear,
            height: 3
        )
        .frame(width: 56)
        .opacity(pct == nil ? 0 : 1)
        .accessibilityHidden(true)
    }
}

/// Selected = accent-tinted label on an accent wash; unselected = secondary label
/// with the panel's quiet hover treatment (AccountRow's 0.045 idiom).
private struct TabSegmentStyle: ButtonStyle {
    let selected: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? Theme.accent : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Theme.accent.opacity(0.16)
                          : (hovering ? Color.primary.opacity(0.045) : .clear))
            )
            .onHover { hovering = $0 }
    }
}
