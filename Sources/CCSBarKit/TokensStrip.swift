import SwiftUI

/// The machine-wide token-usage strip (TOK-4) — Claude Code's LOCAL usage across ALL
/// accounts on this machine, fed by `~/.clauth/tokens.json`. It sits ABOVE the
/// per-account content as ambient machine context, so it is deliberately NEUTRAL:
/// secondary/tertiary tones only, never terracotta (ACTIVE) or sapphire (ARMED) —
/// those hues carry per-account meaning the §5 palette reserves.
///
/// Collapsed to ONE line ("today 41.2M · $12.40"); hovering anywhere over the strip
/// expands an inline detail block (a 4-row period table + the top models) in place,
/// the same expand-in-place idiom the banners/disclosures use — no popover. The hover
/// target is the whole strip+detail container, so sliding the pointer down into the
/// detail keeps it open. Rendered only when `machineTokens != nil`; PanelView also
/// gates the surrounding divider on that, so a machine with no snapshot yet shows no
/// trace of the strip.
struct TokensStrip: View {
    @ObservedObject var model: StatusModel
    @State private var expanded: Bool

    /// `startExpanded` is true only for snapshot/preview renders: the detail is
    /// hover-gated, and a headless `ImageRenderer` can't hover, so the media would
    /// otherwise capture only the collapsed line. The live app always starts collapsed.
    init(model: StatusModel, startExpanded: Bool = false) {
        self.model = model
        self._expanded = State(initialValue: startExpanded)
    }

    var body: some View {
        if let tokens = model.machineTokens {
            VStack(alignment: .leading, spacing: 6) {
                collapsedLine(tokens)
                if expanded { detail(tokens) }
            }
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 8)
            .contentShape(Rectangle())
            .onHover { expanded = $0 }
        }
    }

    // MARK: - Collapsed line

    private func collapsedLine(_ t: MachineTokens) -> some View {
        let today = t.periods.today
        return HStack(spacing: 6) {
            Image(systemName: "chart.bar.xaxis").font(.caption).foregroundStyle(.secondary)
            Text("Tokens").font(.caption).fontWeight(.medium).foregroundStyle(.secondary)
            Text("today \(MachineTokens.abbreviateCount(today.inOut)) · \(MachineTokens.formatCost(today.costUsd, isFloor: today.costIsFloor))")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 8)).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Expanded detail (period table + top models)

    private func detail(_ t: MachineTokens) -> some View {
        let top = t.modelsPeriod.topModels(3)
        return VStack(alignment: .leading, spacing: 6) {
            periodRow("TODAY", t.periods.today)
            periodRow("WEEK", t.periods.week)
            periodRow("MONTH", t.periods.month)
            periodRow("LIFETIME", t.periods.lifetime)
            if !top.isEmpty {
                Divider().padding(.vertical, 1)
                Text("TOP MODELS · \(t.modelsBasis.rawValue)")
                    .font(.system(size: 9)).fontWeight(.semibold).foregroundStyle(.tertiary)
                ForEach(top) { modelRow($0) }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Neutral wash (not a colored banner tint) — this is machine context, not an
        // alert; the primary-based fill reads as a quiet card in light and dark.
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func periodRow(_ label: String, _ p: TokenPeriod) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            Text(MachineTokens.abbreviateCount(p.inOut))
                .font(.caption).monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(MachineTokens.formatCost(p.costUsd, isFloor: p.costIsFloor))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)
        }
    }

    private func modelRow(_ m: TokenModel) -> some View {
        HStack(spacing: 8) {
            Text(m.display).font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(MachineTokens.abbreviateCount(m.inOut))
                .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
            Text(MachineTokens.formatCost(m.costUsd))
                .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                .frame(width: 54, alignment: .trailing)
        }
    }
}
