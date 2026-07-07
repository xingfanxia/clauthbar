import SwiftUI

/// The canonical chain editor (design §7 — the inline Configure disclosure), upgraded
/// to Relay's hit-target standard: 28pt rows, 13pt labels, 22×22pt glyphs inside 28pt
/// targets, 10pt chevrons. The threshold menus carry a one-line legend so a number is
/// never misread as "switch TO here"; the wrap-off setting is an outcome-language
/// radio ("Stay on last account" / "Switch everything off") — the "wrap-off" jargon
/// is retired from all UI copy. All strings + presets come from `ChainEdit`.
///
/// Every control drives a daemon socket command through `StatusModel`, which surfaces
/// a pending shimmer while in flight and reverts loudly on a rejection (TECH-11).
struct ConfigView: View {
    @ObservedObject var model: StatusModel
    let status: DaemonStatus

    private let rowHeight: CGFloat = 28

    var body: some View {
        DisclosureGroup(isExpanded: $model.showConfig) {
            VStack(alignment: .leading, spacing: 8) {
                // Every control here needs a running daemon (socket-only commands).
                // With the daemon down, disable + dim them and say why — a silent
                // no-op is worse than a visibly-inert control (TECH-11).
                let reachable = model.daemonReachable
                if !reachable {
                    Label("Daemon not running — controls disabled", systemImage: "bolt.slash")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    // The armed-member removal confirm is rendered at the PANEL level
                    // (PanelView.removalConfirmBanner) so it's visible whether the
                    // remove came from this disclosure or the row context menu — the
                    // disclosure is collapsed by default.
                    //
                    // Rows follow CHAIN order (unlike the main ACCOUNTS list, which is
                    // fixed file order): this is the chain editor, so Move up/down must
                    // visibly reorder the rows. The order animates on `fallbackChain`.
                    ForEach(orderedConfigProfiles) { p in
                        row(for: p)
                    }
                    legends
                    Divider().padding(.vertical, 4)
                    wrapOffRadio
                }
                .animation(.easeInOut(duration: 0.2), value: status.fallbackChain)
                .disabled(!reachable)
                .opacity(reachable ? 1 : 0.45)
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Label("Configure", systemImage: "slider.horizontal.3")
                    .font(.body).fontWeight(.semibold)
                if model.configBusy {
                    ProgressView().controlSize(.small)
                    Text("Applying…").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .tint(Theme.accent)
    }

    /// Chain members first (in chain order), then non-members — see `ChainEdit`.
    private var orderedConfigProfiles: [ProfileStatus] {
        ChainEdit.chainOrdered(status.profiles, chain: status.fallbackChain)
    }

    // MARK: - Per-account row (28pt hit-target standard)

    @ViewBuilder
    private func row(for p: ProfileStatus) -> some View {
        HStack(spacing: 8) {
            Text(p.name)
                .font(.body).lineLimit(1).truncationMode(.tail)
                .frame(width: 84, alignment: .leading)

            if let fb = p.fallback {
                thresholdMenu(for: p, fb: fb)

                Spacer()

                lastResortToggle(p, on: fb.lastResort)
                moveButton(p, up: true, disabled: fb.position <= 1)
                moveButton(p, up: false, disabled: fb.position >= status.fallbackChain.count)
                glyphButton("minus.circle", tint: Theme.danger, help: "Remove from chain") {
                    model.requestRemove(p.name)
                }
            } else {
                Spacer()
                Button { model.fallbackAdd(p.name) } label: {
                    Label("Add", systemImage: "plus.circle")
                        .font(.body).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .help(ChainEdit.addHint)
            }
        }
        .frame(height: rowHeight)
    }

    // A capsule menu showing the current threshold; presets come from ChainEdit.
    private func thresholdMenu(for p: ProfileStatus, fb: FallbackInfo) -> some View {
        Menu {
            ForEach(ChainEdit.thresholdPresets, id: \.self) { v in
                Button(ChainEdit.thresholdLabel(v)) { model.setThreshold(p.name, v) }
            }
        } label: {
            HStack(spacing: 3) {
                Text(ChainEdit.currentThresholdLabel(fb.threshold)).monospacedDigit()
                Image(systemName: "chevron.down").font(.system(size: 10))
            }
            .font(.body)
            .padding(.vertical, 3).padding(.horizontal, 9)
            .frame(minHeight: rowHeight - 6)
            .background(Color.primary.opacity(0.07), in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help(ChainEdit.thresholdLegend)
    }

    private var legends: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(ChainEdit.thresholdLegend)
            Text(ChainEdit.lastResortLegend)
        }
        .font(.subheadline).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 2)
    }

    // A flag toggle for the member's exclusive last-resort flag (§7) — filled + accent
    // when on, hollow + secondary when off. Threshold-independent (set_last_resort).
    private func lastResortToggle(_ p: ProfileStatus, on: Bool) -> some View {
        glyphButton(on ? "flag.fill" : "flag",
                    tint: on ? Theme.accent : .secondary,
                    help: ChainEdit.lastResortLegend) {
            model.setLastResort(p.name, !on)
        }
    }

    private func moveButton(_ p: ProfileStatus, up: Bool, disabled: Bool) -> some View {
        glyphButton(up ? "chevron.up" : "chevron.down",
                    tint: disabled ? Color.primary.opacity(0.2) : .secondary,
                    help: up ? "Move earlier" : "Move later") {
            model.fallbackMove(p.name, up: up)
        }
        .disabled(disabled)
    }

    // A 22×22pt glyph inside a 28pt hit target (§7 hit-target standard).
    private func glyphButton(_ symbol: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(tint)
                .frame(width: rowHeight, height: rowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Wrap-off as an outcome-language radio (§7)

    private var wrapOffRadio: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("When every account is over its limit")
                .font(.body).fontWeight(.medium)
            radioOption(ChainEdit.stayOnLastLabel, detail: nil, selected: !status.wrapOff) {
                if status.wrapOff { model.setWrapOff(false) }
            }
            radioOption(ChainEdit.switchEverythingOffLabel,
                        detail: ChainEdit.switchEverythingOffDetail,
                        selected: status.wrapOff) {
                if !status.wrapOff { model.setWrapOff(true) }
            }
        }
    }

    private func radioOption(_ title: String, detail: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? Theme.accent : Color.secondary)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body)
                    if let detail {
                        Text(detail).font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
