import SwiftUI

/// The SINGLE exception surface (CBAR4-4, design §3.10), priority-ordered so
/// exceptional truth always appears in the same place: dead-daemon banner > switch
/// lifecycle > wrap-off card > zero-armed warning > forecast sentence.
struct StatusStrip: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        Group {
            if isDead {
                deadBanner
            } else if model.switchPhase != .idle {
                lifecycleRow
            } else if isWrapOff {
                wrapOffCard
            } else if model.autoSwitchIdle {
                zeroArmed
            } else if let sentence = model.forecastSentence {
                forecast(sentence)
            }
        }
        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 8)
    }

    // Dead = a frozen-but-present status (stalled); a never-written file is the
    // panel's empty state, handled a level up.
    private var isDead: Bool { model.liveness.isStalled }
    private var isWrapOff: Bool { (model.status?.activeProfile == nil) && model.status != nil }

    // MARK: - Dead-daemon banner (§3.12/§3.13)

    private var deadBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle().fill(Theme.danger).frame(width: 3).cornerRadius(1.5)
            VStack(alignment: .leading, spacing: 4) {
                Text("Daemon not responding — data frozen \(model.frozenAge)")
                    .font(.body).fontWeight(.semibold)
                Text("Auto-switch is NOT running.")
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Start daemon") { model.startDaemon() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Text("clauth daemon").font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("clauth daemon", forType: .string)
                    } label: { Image(systemName: "doc.on.doc").foregroundStyle(.secondary) }
                        // `.plain`, not `.borderless`: borderless chrome draws the □
                        // missing-image box under headless ImageRenderer (--snapshot).
                        .buttonStyle(.plain).help("Copy command")
                }
            }
        }
    }

    // MARK: - Switch lifecycle (§2 STATE 3)

    @ViewBuilder private var lifecycleRow: some View {
        HStack(spacing: 8) {
            switch model.switchPhase {
            case .arming(let target):
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.danger)
                Text("Confirm — live session on \(model.active?.name ?? "current"); switching to \(target)")
                    .font(.callout).foregroundStyle(.primary)
            case .pending(let target):
                ProgressView().controlSize(.small)
                Text("Switching to \(target)…").font(.callout)
            case .confirmed(let target, let viaCLI):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                Text(viaCLI ? "Switched to \(target) via CLI — auto-switch inactive until daemon starts"
                            : "Switched to \(target)")
                    .font(.callout)
            case .failed(let reason):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                Text(reason).font(.callout).fixedSize(horizontal: false, vertical: true)
            case .idle:
                EmptyView()
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Wrap-off card (§3.15)

    private var wrapOffCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "powersleep").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("All accounts switched off — chain spent.").font(.callout)
                if let eta = model.wrapOffResumeETA {
                    Text("Auto-resumes when a window \(eta.replacingOccurrences(of: "resets in", with: "resets in ≤"))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Zero-armed warning (§3.16)

    private var zeroArmed: some View {
        let chainEmpty = model.status?.fallbackChain.isEmpty ?? true
        return HStack(spacing: 8) {
            Image(systemName: "bolt.slash.fill").foregroundStyle(Theme.warning)
            if chainEmpty {
                Text("Auto-switch off — no fallback chain.").font(.callout)
                Spacer(minLength: 0)
                Button { model.showConfig = true } label: {
                    Text("Set up").font(.subheadline).fontWeight(.medium).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            } else {
                Text("Auto-switch idle — \(model.active?.name ?? "the active account") isn't armed.")
                    .font(.callout)
                Spacer(minLength: 0)
                if let name = model.active?.name {
                    Button { model.fallbackAdd(name) } label: {
                        Text("Add \(name)").font(.subheadline).fontWeight(.medium).foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Forecast sentence (§3.11)

    private func forecast(_ sentence: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "bolt.fill").font(.system(size: 11)).foregroundStyle(Theme.sapphire)
            VStack(alignment: .leading, spacing: 2) {
                Text(sentence).font(.callout).fixedSize(horizontal: false, vertical: true)
                Text(model.livenessStamp).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}
