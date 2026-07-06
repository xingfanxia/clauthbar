import AppKit
import SwiftUI

/// The menu-bar dropdown, hosted in `MenuBarExtra(.window)` — the CBAR-4 "Preflight"
/// panel (design §2): status strip → account LIST (inspect-first) → detail card of
/// the inspected account → chain rail → action rows. Browse freely (single click
/// inspects, zero daemon traffic); switch deliberately (the one verb in the detail
/// card). Data comes from `status.json` via `StatusModel`; edits go to the socket.
struct PanelView: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.liveness {
            case .outOfDate(let schema):
                outOfDateState(schema)
            case .down:
                emptyState
            case .ok, .stalled:
                if let status = model.status { populated(status) } else { emptyState }
            }
        }
        .frame(width: 340)
        .padding(.vertical, 12)
        .onAppear { if !model.isPreview { model.resetInspection() } }
    }

    // MARK: - Populated panel (STATE 1/2/3/4)

    @ViewBuilder
    private func populated(_ status: DaemonStatus) -> some View {
        let dead = model.liveness.isStalled
        // Config-command errors (a rejected chain edit) surface here; switch errors
        // live in the strip's lifecycle line.
        if let error = model.lastCommandError {
            commandErrorBanner(error)
        }
        // The armed-member removal confirm (§7) floats at the panel top so it's
        // visible from BOTH the context menu and the disclosure minus button,
        // without forcing the editor open.
        if let prompt = model.pendingRemovalPrompt {
            removalConfirmBanner(prompt)
        }
        // A browser reauth (AUTH-3) in flight — a GLOBAL indicator so the sign-in is
        // visible no matter which detail card is showing (the card's own in-flight
        // state only exists for a broken account; a proactive reauth of a healthy one
        // would otherwise run with no on-screen feedback).
        if let name = model.reauthInFlight {
            reauthBanner(name)
        }
        // The inline rename editor (context-menu "Rename…") floats at the panel top,
        // same as the removal confirm — a TextField needs a stable focus home.
        if let name = model.renaming {
            RenameBanner(model: model, name: name)
        }
        StatusStrip(model: model)
        Divider().padding(.horizontal, 12)
        accounts(status, dead: dead)
        if let inspected = model.inspected {
            Divider().padding(.horizontal, 12).padding(.vertical, 6)
            DetailCard(model: model, p: inspected, dead: dead)
        }
        Divider().padding(.horizontal, 12).padding(.vertical, 8)
        chainSection(status, dead: dead)
        if model.showConfig {
            ConfigView(model: model, status: status).padding(.horizontal, 16).padding(.top, 6)
        }
        Divider().padding(.horizontal, 12).padding(.vertical, 8)
        actions(dead: dead)
    }

    // MARK: - Accounts list (§2 — file order, inspect on click)

    @ViewBuilder
    private func accounts(_ status: DaemonStatus, dead: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ACCOUNTS")
                .font(.subheadline).fontWeight(.semibold).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.top, 4)
            let rows = ForEach(model.listProfiles) { p in
                AccountRow(
                    model: model,
                    p: p,
                    status: status,
                    inspected: model.isInspected(p.name),
                    dead: dead,
                    frozenStamp: dead ? "as of \(model.frozenAge)" : nil,
                    onInspect: { model.inspect(p.name) }
                )
                .padding(.horizontal, 8)
            }
            if model.listProfiles.count > 6 {
                ScrollView { VStack(spacing: 2) { rows } }.frame(maxHeight: 340)
            } else {
                rows
            }
        }
        // ↑/↓ move inspection (macOS 14 focus nav; degrades gracefully).
        .focusable()
        .onMoveCommand { direction in moveInspection(direction) }
    }

    private func moveInspection(_ direction: MoveCommandDirection) {
        let names = model.listProfiles.map(\.name)
        guard !names.isEmpty else { return }
        let current = model.inspected?.name ?? names[0]
        guard let i = names.firstIndex(of: current) else { return }
        switch direction {
        case .up: model.inspect(names[max(0, i - 1)])
        case .down: model.inspect(names[min(names.count - 1, i + 1)])
        default: break
        }
    }

    // MARK: - Chain rail (§2)

    private func chainSection(_ status: DaemonStatus, dead: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CHAIN").font(.subheadline).fontWeight(.semibold).foregroundStyle(.secondary)
                Spacer()
                Button("Edit") { model.showConfig.toggle() }
                    .buttonStyle(.borderless).controlSize(.small).disabled(dead)
            }
            if status.fallbackChain.isEmpty {
                Text("None — add accounts in Configure").font(.footnote).foregroundStyle(.secondary)
            } else {
                ChainStrip(status: status)
                Text(ChainEdit.whenSpentSummary(wrapOff: status.wrapOff))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            if let skew = model.versionSkew {
                Text("daemon clauth \(skew); clauthbar targets \(StatusModel.expectedClauthVersion)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .opacity(dead ? 0.6 : 1)
    }

    // MARK: - Actions (§2 — 24pt rows)

    private func actions(dead: Bool) -> some View {
        VStack(spacing: 1) {
            ActionRow(icon: "arrow.clockwise", title: "Refresh usage") { model.refresh() }
                .disabled(dead)
                .keyboardShortcut("r", modifiers: [])
            if LoginItem.isAvailable {
                Toggle(isOn: Binding(get: { LoginItem.isEnabled }, set: { LoginItem.setEnabled($0) })) {
                    HStack(spacing: 8) {
                        Image(systemName: "power.circle").frame(width: 16)
                        Text("Start at login"); Spacer()
                    }
                }
                .toggleStyle(.switch).controlSize(.mini)
                .padding(.vertical, 5).padding(.horizontal, 8)
            }
            ActionRow(icon: "power", title: "Quit clauthbar · daemon keeps running") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
                .help("The clauth daemon keeps running — auto-switch continues.")
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Armed-member removal confirm (§7)

    private func removalConfirmBanner(_ prompt: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            Text(prompt).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            // Cancel is pure local state — never gated on daemon reachability.
            Button("Cancel") { model.cancelRemoval() }.controlSize(.small)
            Button("Remove") { model.confirmRemoval() }.controlSize(.small).tint(Theme.danger)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12).padding(.bottom, 6)
    }

    // MARK: - Config-command error banner (TECH-11)

    private func commandErrorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.danger)
            Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12).padding(.bottom, 6)
    }

    // MARK: - Reauth-in-flight banner (AUTH-3)

    private func reauthBanner(_ name: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Signing in to \(name) — finish in your browser…")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.sapphire.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12).padding(.bottom, 6)
    }

    // MARK: - Empty / out-of-date states

    private func outOfDateState(_ schema: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("clauthbar out of date", systemImage: "arrow.up.circle")
                .font(.subheadline).foregroundStyle(Theme.warning)
            Text("The daemon writes status.json schema \(schema); this clauthbar reads \(supportedSchema). Update clauthbar.")
                .font(.caption).foregroundStyle(.secondary)
            Divider().padding(.vertical, 6)
            ActionRow(icon: "power", title: "Quit clauthbar") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 16)
    }

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

// MARK: - Chain chips

/// The fallback chain as capsule chips joined by arrows; the armed member glows in
/// sapphire (armed = auto-switch is watching it).
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
            Text(name).font(.callout).fontWeight(armed ? .semibold : .regular)
            Text("@\(Int(fb?.threshold ?? 95))")
                .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 3).padding(.horizontal, 8)
        .background(armed ? Theme.sapphire.opacity(0.18) : Color.primary.opacity(0.05), in: Capsule())
        .foregroundStyle(armed ? Theme.sapphire : Color.primary)
    }
}

// MARK: - Rename banner

/// The inline profile-rename editor: a TextField pre-filled with the current name,
/// live client-side validation (mirroring the daemon's rule), and Rename/Cancel.
/// Its own `@State` for the field + `@FocusState` so typing lands here on open.
private struct RenameBanner: View {
    @ObservedObject var model: StatusModel
    let name: String
    @State private var newName: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Rename \(name)").font(.subheadline).fontWeight(.medium)
            HStack(spacing: 6) {
                TextField("New name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(commit)
                Button("Cancel") { model.cancelRename() }.controlSize(.small)
                Button("Rename", action: commit).controlSize(.small)
                    .tint(Theme.accent)
                    .disabled(liveError != nil)
                    .keyboardShortcut(.return, modifiers: [])
            }
            if let err = liveError, !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(err).font(.caption).foregroundStyle(Theme.danger)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12).padding(.bottom, 6)
        .onAppear {
            newName = name
            focused = true
        }
    }

    /// Live validation echoing the daemon's rule (nil ⇒ valid).
    private var liveError: String? {
        StatusModel.renameValidationError(newName, old: name, existing: model.listProfiles.map(\.name))
    }

    private func commit() {
        guard liveError == nil else { return }
        model.commitRename(name, to: newName)
    }
}

// MARK: - Action row

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
                Text(title).font(.body).lineLimit(1)
                Spacer()
            }
            .padding(.vertical, 5).padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .background(hovering ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
