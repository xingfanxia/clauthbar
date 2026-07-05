import SwiftUI

/// One account in the CBAR-4 list (design §2 row anatomy). Rows never reorder; only
/// the terracotta ✓ badge and the inspection ring move. Single click INSPECTS (pure
/// view state, zero daemon traffic). In the dead state rows dim to 60%, bars go
/// greyscale, and every stamp becomes "as of Xm ago".
struct AccountRow: View {
    @ObservedObject var model: StatusModel
    let p: ProfileStatus
    let status: DaemonStatus
    let inspected: Bool
    let dead: Bool
    let frozenStamp: String? // "as of 4m ago" when dead, else nil
    let onInspect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if p.provider != "anthropic" {
                thirdPartyLine
            } else {
                fiveHourRow
                secondaryRow
            }
        }
        .padding(.vertical, 7).padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.primary.opacity(inspected ? 0.08 : 0))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Color.primary.opacity(inspected ? 0.18 : 0), lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onInspect)
        .contextMenu { AccountContextMenu(model: model, p: p, status: status) }
        .opacity(dead ? 0.6 : 1)
        .help("\(p.name) · \(p.tier ?? p.provider) — click to inspect")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(voiceOver)
    }

    // MARK: - Header (badge + name + tier + badge cluster)

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: p.active ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12))
                .foregroundStyle(p.active ? Theme.accent : Color.secondary)
            Text(p.name).font(.body).fontWeight(.semibold).lineLimit(1).truncationMode(.tail)
            if let tier = p.tier {
                Text(tier).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            } else if p.provider != "anthropic" {
                Text(providerLabel).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            badgeCluster
        }
    }

    @ViewBuilder private var badgeCluster: some View {
        HStack(spacing: 5) {
            if p.authBroken {
                Label("login expired", systemImage: "exclamationmark.shield.fill")
                    .labelStyle(.iconOnly).font(.system(size: 11)).foregroundStyle(Theme.danger)
                    .help("Login expired — clauth login \(p.name)")
            }
            if p.fallback?.armed == true {
                Image(systemName: "bolt.fill").font(.system(size: 11)).foregroundStyle(Theme.sapphire)
                    .help("Armed — auto-switch is watching this account")
            }
            if (p.fallback?.threshold ?? 0) >= 100 {
                Image(systemName: "flag.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    .help("Last-resort sink — the chain parks here even at 100%")
            }
            if p.hasLiveSession {
                Text("in use").font(.system(size: 10)).foregroundStyle(.secondary)
                    .help("A claude session is attached to this account")
            }
            if p.isStale, let fs = p.fetchStatus {
                Text(fs).font(.system(size: 10)).foregroundStyle(Theme.warning)
            }
        }
    }

    // MARK: - 5h hero row

    private var fiveHourRow: some View {
        let pct = p.fiveHourPct
        return VStack(spacing: 3) {
            UsageBar(
                pct: pct,
                color: dead ? Color.secondary.opacity(0.5) : Theme.usageColor(pct, threshold: p.fallback?.threshold ?? 100),
                height: 6,
                threshold: p.fallback?.threshold
            )
            HStack {
                Text("5h").font(.caption).foregroundStyle(.tertiary)
                Text("\(Int(pct.rounded()))%").font(.body).fontWeight(.semibold).monospacedDigit()
                Spacer()
                Text(stamp(p.fiveHour?.resetsAt)).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 7d / Fable secondary row (half-width bars)

    private var secondaryRow: some View {
        HStack(spacing: 12) {
            miniBar("7d", p.sevenDay?.utilizationPct)
            miniBar("Fb", p.fableWeek?.utilizationPct)
        }
    }

    private func miniBar(_ label: String, _ pct: Double?) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.tertiary)
            UsageBar(pct: pct ?? 0, color: dead ? Color.secondary.opacity(0.5) : Theme.usageColor(pct ?? 0), height: 4)
                .frame(maxWidth: .infinity)
            Text(pct.map { "\(Int($0.rounded()))%" } ?? "—").font(.callout).monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Third-party line (never %-bars)

    private var thirdPartyLine: some View {
        let available = p.thirdParty?.available
        let (text, color): (String, Color) = {
            switch available {
            case .some(true): return ("Available", Theme.success)
            case .some(false): return ("Unavailable", Theme.danger)
            case .none: return ("No data yet", .secondary)
            }
        }()
        return HStack(spacing: 6) {
            Circle().fill(dead ? Color.secondary : color).frame(width: 7, height: 7)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
            if let checked = stampChecked(p.fetchedAt) {
                Text("· \(checked)").font(.subheadline).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Helpers

    private var providerLabel: String {
        switch p.provider {
        case "openai": return "Z.AI"
        default: return p.provider
        }
    }

    private func stamp(_ iso: String?) -> String {
        if let frozenStamp { return frozenStamp }
        return Theme.resetHint(iso) ?? "—"
    }

    private func stampChecked(_ iso: String?) -> String? {
        if let frozenStamp { return frozenStamp }
        guard let iso, let d = Theme.parseISO(iso) else { return nil }
        return "checked \(StatusModel.ago(Int(Date().timeIntervalSince(d))))"
    }

    private var voiceOver: String {
        var parts = [p.name]
        if p.active { parts.append("active account") }
        if let tier = p.tier { parts.append(tier) }
        if p.fallback?.armed == true { parts.append("armed") }
        if p.provider == "anthropic" { parts.append("session \(Int(p.fiveHourPct.rounded())) percent used") }
        return parts.joined(separator: ", ")
    }
}
