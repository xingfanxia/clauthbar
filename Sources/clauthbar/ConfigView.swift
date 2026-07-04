import SwiftUI

/// The `Configure` disclosure: per-account fallback controls (threshold, reorder,
/// add/remove) plus a wrap-off toggle. Every control drives a daemon socket
/// command through `StatusModel`. Collapsed by default to keep the panel calm.
///
/// Controls are custom `.plain`-styled to match the panel's drawn capsules
/// (chain chips, tiles) rather than bridge to system `Menu`/`Toggle` chrome.
struct ConfigView: View {
    @ObservedObject var model: StatusModel
    let status: DaemonStatus

    private let thresholds = [50, 80, 90, 95, 100]

    var body: some View {
        DisclosureGroup(isExpanded: $model.showConfig) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(status.profiles) { p in
                    row(for: p)
                }
                Divider().padding(.vertical, 2)
                wrapOffRow
                Text("When the whole chain is spent: on switches every account off; off stays on the last.")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 10)
        } label: {
            Label("Configure", systemImage: "slider.horizontal.3")
                .font(.subheadline).fontWeight(.semibold)
        }
        .tint(Theme.accent)
    }

    @ViewBuilder
    private func row(for p: ProfileStatus) -> some View {
        HStack(spacing: 8) {
            Text(p.name)
                .font(.footnote).lineLimit(1)
                .frame(width: 64, alignment: .leading)

            if let fb = p.fallback {
                thresholdMenu(for: p, fb: fb)

                moveButton(p, up: true, disabled: fb.position <= 1)
                moveButton(p, up: false, disabled: fb.position >= status.fallbackChain.count)

                Spacer()

                iconButton("minus.circle", tint: .secondary, help: "Remove from chain") {
                    model.fallbackRemove(p.name)
                }
            } else {
                Spacer()
                Button { model.fallbackAdd(p.name) } label: {
                    Label("Add", systemImage: "plus.circle")
                        .font(.footnote).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .help("Add to fallback chain")
            }
        }
    }

    // A capsule menu showing the current threshold; picks from a small preset list.
    private func thresholdMenu(for p: ProfileStatus, fb: FallbackInfo) -> some View {
        Menu {
            ForEach(thresholds, id: \.self) { v in
                Button("\(v)%") { model.setThreshold(p.name, v) }
            }
        } label: {
            HStack(spacing: 2) {
                Text("\(Int(fb.threshold))%").monospacedDigit()
                Image(systemName: "chevron.down").font(.system(size: 7))
            }
            .font(.footnote)
            .padding(.vertical, 2).padding(.horizontal, 7)
            .background(Color.primary.opacity(0.07), in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help("Auto-switch when this account crosses the threshold")
    }

    private func moveButton(_ p: ProfileStatus, up: Bool, disabled: Bool) -> some View {
        iconButton(up ? "chevron.up" : "chevron.down",
                   tint: disabled ? Color.primary.opacity(0.2) : .secondary,
                   help: up ? "Move earlier" : "Move later") {
            model.fallbackMove(p.name, up: up)
        }
        .disabled(disabled)
    }

    private func iconButton(_ symbol: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(tint)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // Custom on/off pill (matches the chain-chip aesthetic; no system Toggle chrome).
    private var wrapOffRow: some View {
        HStack {
            Text("Wrap-off mode").font(.footnote)
            Spacer()
            Button { model.setWrapOff(!status.wrapOff) } label: {
                Text(status.wrapOff ? "On" : "Off")
                    .font(.caption).fontWeight(.semibold).monospacedDigit()
                    .padding(.vertical, 3).padding(.horizontal, 14)
                    .background(status.wrapOff ? Theme.accent : Color.primary.opacity(0.08), in: Capsule())
                    .foregroundStyle(status.wrapOff ? Color.white : Color.secondary)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Toggle wrap-off behavior when the whole chain is spent")
        }
    }
}
