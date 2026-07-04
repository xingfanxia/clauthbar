import AppKit
import SwiftUI

/// The menu-bar dropdown, hosted in `MenuBarExtra(.window)`. A translucent panel:
/// account switcher → active account's usage (Session / Weekly / Fable) → the
/// fallback chain → a Configure disclosure → actions. Data comes from
/// `status.json` via `StatusModel`; edits go to the daemon socket.
struct PanelView: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let status = model.status {
                content(status)
            } else {
                emptyState
            }
        }
        .frame(width: 320)
        .padding(.vertical, 12)
    }

    // MARK: - Populated panel

    @ViewBuilder
    private func content(_ status: DaemonStatus) -> some View {
        switcher(status)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)

        if let active = model.active {
            Divider().padding(.horizontal, 12).padding(.vertical, 8)
            header(active)
            usage(active).padding(.top, 10)
        }

        Divider().padding(.horizontal, 12).padding(.vertical, 10)
        chainSection(status)

        Divider().padding(.horizontal, 12).padding(.vertical, 10)
        ConfigView(model: model, status: status).padding(.horizontal, 16)

        Divider().padding(.horizontal, 12).padding(.vertical, 8)
        actions
    }

    // MARK: - Account switcher (the hero — switching is the point)

    private func switcher(_ status: DaemonStatus) -> some View {
        HStack(spacing: 8) {
            ForEach(model.orderedProfiles) { p in
                AccountTile(p: p) { model.switchTo(p.name) }
            }
        }
    }

    // MARK: - Active account header

    private func header(_ p: ProfileStatus) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(p.name).font(.title2).bold()
            if p.isStale {
                Text("· \(p.fetchStatus ?? "stale")").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let tier = p.tier {
                Text(tier).font(.subheadline).foregroundStyle(.secondary)
            } else if p.provider != "anthropic" {
                Text(p.provider).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Usage sections

    @ViewBuilder
    private func usage(_ p: ProfileStatus) -> some View {
        if p.provider != "anthropic" {
            // Third-party / api-key: the daemon only reports up/down, no windows.
            availabilityRow(p).padding(.horizontal, 16)
        } else {
            VStack(spacing: 14) {
                UsageRow(label: "Session", window: p.fiveHour, threshold: p.fallback?.threshold)
                UsageRow(label: "Weekly", window: p.sevenDay, threshold: nil)
                UsageRow(label: "Fable", window: p.fableWeek, threshold: nil)
            }
            .padding(.horizontal, 16)
        }
    }

    private func availabilityRow(_ p: ProfileStatus) -> some View {
        let available = p.thirdParty?.available
        let (text, color): (String, Color) = {
            switch available {
            case .some(true): return ("Available", Theme.success)
            case .some(false): return ("Unavailable", Theme.danger)
            case .none: return ("No data yet", .secondary)
            }
        }()
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    // MARK: - Fallback chain (the signature element)

    private func chainSection(_ status: DaemonStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Fallback chain").font(.subheadline).fontWeight(.semibold)
                Spacer()
                Text(status.wrapOff ? "wrap-off on" : "stay on last")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            if status.fallbackChain.isEmpty {
                Text("None — add accounts below")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ChainStrip(status: status)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 1) {
            ActionRow(icon: "arrow.clockwise", title: "Refresh now") { model.refresh() }
            ActionRow(icon: "power", title: "Quit clauthbar") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("clauth daemon not running", systemImage: "moon.zzz")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("Start it with `clauth daemon` (or the LaunchAgent), then reopen.")
                .font(.caption).foregroundStyle(.tertiary)
            Divider().padding(.vertical, 6)
            ActionRow(icon: "power", title: "Quit clauthbar") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Components

/// A switchable account tile: name, active state, a tiny 5h meter. Filled with
/// the accent when active; tap to switch the global account.
private struct AccountTile: View {
    let p: ProfileStatus
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 5) {
                Text(p.name)
                    .font(.caption).fontWeight(p.active ? .semibold : .regular)
                    .lineLimit(1).minimumScaleFactor(0.8)
                UsageBar(
                    pct: p.fiveHourPct,
                    color: p.active ? Color.white.opacity(0.9) : Theme.usageColor(p.fiveHourPct),
                    height: 3
                )
            }
            .padding(.vertical, 7).padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .background(
                p.active ? Theme.accent : Color.primary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .foregroundStyle(p.active ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .help(p.active ? "Active account" : "Switch to \(p.name)")
    }
}

/// One usage window: bold label, a thin bar, then `X% used` / `resets in …`.
private struct UsageRow: View {
    let label: String
    let window: UsageWindow?
    let threshold: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline).fontWeight(.semibold)
            if let w = window {
                UsageBar(pct: w.utilizationPct, color: Theme.usageColor(w.utilizationPct, threshold: threshold ?? 100))
                HStack {
                    Text("\(Int(w.utilizationPct.rounded()))% used")
                        .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    if let hint = Theme.resetHint(w.resetsAt) {
                        Text(hint).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } else {
                UsageBar(pct: 0, color: Theme.track)
                Text("no data yet").font(.footnote).foregroundStyle(.tertiary)
            }
        }
    }
}

/// The fallback chain as capsule chips joined by arrows; the armed member (the
/// one auto-switch would rotate away from) glows in the accent.
private struct ChainStrip: View {
    let status: DaemonStatus

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(status.fallbackChain.enumerated()), id: \.offset) { i, name in
                if i > 0 {
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                }
                chip(for: name)
            }
        }
    }

    private func chip(for name: String) -> some View {
        let fb = status.profiles.first { $0.name == name }?.fallback
        let armed = fb?.armed ?? false
        return HStack(spacing: 4) {
            if armed { Image(systemName: "bolt.fill").font(.system(size: 9)) }
            Text(name).font(.caption).fontWeight(armed ? .semibold : .regular)
            Text("\(Int(fb?.threshold ?? 95))%")
                .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 3).padding(.horizontal, 8)
        .background(
            armed ? Theme.accent.opacity(0.18) : Color.primary.opacity(0.05),
            in: Capsule()
        )
        .foregroundStyle(armed ? Theme.accent : Color.primary)
    }
}

/// A full-width action row: SF Symbol + title, with a hover highlight.
struct ActionRow: View {
    let icon: String
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 16)
                Text(title)
                Spacer()
            }
            .padding(.vertical, 5).padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .background(
                hovering ? Color.primary.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
