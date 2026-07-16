import SwiftUI

/// The Overview page (TABS-1, codexbar-style): one glance card per harness —
/// glyph + harness name, the active account's identity (name, email, tier), the
/// updated stamp, and 5h/7d mini bars. Read-only + navigation: tapping a card
/// jumps to that harness's management page. No chain editing, no switch verbs —
/// those live on the per-harness pages.
struct OverviewPage: View {
    @ObservedObject var model: StatusModel
    let status: DaemonStatus
    let dead: Bool

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Harness.allCases, id: \.self) { harness in
                HarnessCard(model: model, harness: harness, dead: dead)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .opacity(dead ? 0.6 : 1)
    }
}

/// One harness's glance card. Empty harness → an invitation, not a blank: the
/// card names the setup path and still navigates to the page that has the door.
private struct HarnessCard: View {
    @ObservedObject var model: StatusModel
    let harness: Harness
    let dead: Bool
    @State private var hovering = false

    private var tab: ProviderTab { harness == .codex ? .codex : .claude }
    private var active: ProfileStatus? { model.activeProfile(for: harness) }
    private var count: Int { model.profiles(for: harness).count }

    var body: some View {
        Button { model.tab = tab } label: {
            VStack(alignment: .leading, spacing: 6) {
                header
                if let active {
                    identityLine(active)
                    bars(active)
                } else if count > 0 {
                    Text("No active account — pick one on the \(tab.title) page.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(harness == .codex
                         ? "No codex accounts yet — set up in the Codex tab."
                         : "No Claude accounts yet — set up in the Claude tab.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8).padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.primary.opacity(hovering ? 0.06 : 0.035))
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open the \(tab.title) page")
        .accessibilityLabel(voiceOver)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.symbol).font(.system(size: 12)).foregroundStyle(Theme.accent)
            Text(tab.title).font(.body).fontWeight(.semibold)
            if let tier = active?.tier {
                Text(tier).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(dead ? "as of \(model.frozenAge)" : "updated \(model.freshAge) ago")
                .font(.caption).foregroundStyle(.tertiary)
            Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }

    private func identityLine(_ active: ProfileStatus) -> some View {
        HStack(spacing: 5) {
            Text(active.name).font(.callout).fontWeight(.medium)
            if let email = active.accountEmail {
                Text(email).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }

    private func bars(_ active: ProfileStatus) -> some View {
        HStack(spacing: 10) {
            miniBar("5h", active.fiveHour?.utilizationPct, threshold: active.fallback?.threshold)
            miniBar("7d", active.sevenDay?.utilizationPct, threshold: nil)
        }
    }

    private func miniBar(_ label: String, _ pct: Double?, threshold: Double?) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.tertiary)
            UsageBar(
                pct: pct ?? 0,
                color: dead ? Color.secondary.opacity(0.5)
                            : Theme.usageColor(pct ?? 0, threshold: threshold ?? 100),
                height: 4
            )
            .frame(maxWidth: .infinity)
            Text(pct.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private var voiceOver: String {
        var parts = [tab.title]
        if let active {
            parts.append("active \(active.name)")
            if let email = active.accountEmail { parts.append(email) }
            parts.append("session \(Int(active.fiveHourPct.rounded())) percent used")
        } else {
            parts.append(count > 0 ? "no active account" : "no accounts yet")
        }
        parts.append("opens the \(tab.title) page")
        return parts.joined(separator: ", ")
    }
}
