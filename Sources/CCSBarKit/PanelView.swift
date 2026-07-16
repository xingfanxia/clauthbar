import AppKit
import SwiftUI

/// The menu-bar dropdown, hosted in `MenuBarExtra(.window)`. Since TABS-1 the
/// panel is a tab ROUTER (codexbar-style): global banners → the provider tab bar
/// (Overview / Claude / Codex) → the selected page → the shared actions rows.
/// The per-harness pages keep the CBAR-4 "Preflight" anatomy (design §2): strip →
/// account LIST (inspect-first) → detail card → chain rail → config disclosure.
/// Data comes from `status.json` via `StatusModel`; edits go to the socket.
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

    // MARK: - Populated panel: banners → tab bar → page → actions

    @ViewBuilder
    private func populated(_ status: DaemonStatus) -> some View {
        let dead = model.liveness.isStalled
        // Global banners: model-wide states that must be visible from ANY page —
        // a rejected config edit, the armed-member removal confirm, an in-flight
        // login, and the rename/add editors (TextFields need a stable focus home).
        if let error = model.lastCommandError {
            commandErrorBanner(error)
        }
        if let prompt = model.pendingRemovalPrompt {
            removalConfirmBanner(prompt)
        }
        if let flight = model.loginInFlight {
            LoginFlightBanner(flight: flight)
        }
        if let name = model.renaming {
            RenameBanner(model: model, name: name)
        }
        if let harness = model.addingHarness {
            AddAccountBanner(model: model, harness: harness)
        }
        ProviderTabBar(model: model)
        Divider().padding(.horizontal, 12).padding(.top, 6)
        switch model.tab {
        case .overview:
            OverviewPage(model: model, status: status, dead: dead)
        case .claude:
            claudePage(status, dead: dead)
        case .codex:
            codexPage(status, dead: dead)
        }
        if let skew = model.versionSkew {
            Text("daemon clauth \(skew); ccsbar targets \(StatusModel.expectedClauthVersion)")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.top, 6)
        }
        Divider().padding(.horizontal, 12).padding(.vertical, 8)
        actions(dead: dead)
    }

    // MARK: - Claude page (the pre-TABS-1 panel body, harness-scoped)

    @ViewBuilder
    private func claudePage(_ status: DaemonStatus, dead: Bool) -> some View {
        // Machine-wide Claude Code token usage (TOK-4) — ambient context ABOVE the
        // per-account strip. tokens.json is CLAUDE CODE telemetry, so the strip
        // lives on this page, not Overview. Present only when a snapshot exists
        // (startExpanded pins the hover-only detail open for headless snapshot
        // media, which can't hover).
        if model.machineTokens != nil {
            TokensStrip(model: model, startExpanded: model.isPreview)
            Divider().padding(.horizontal, 12)
        }
        StatusStrip(model: model)
        Divider().padding(.horizontal, 12)
        harnessBody(status, harness: .claude, dead: dead)
    }

    // MARK: - Codex page (TABS-1)

    @ViewBuilder
    private func codexPage(_ status: DaemonStatus, dead: Bool) -> some View {
        CodexStrip(model: model)
        Divider().padding(.horizontal, 12)
        harnessBody(status, harness: .codex, dead: dead)
    }

    /// The shared page body below the strip: accounts → detail → chain → config.
    /// With ZERO profiles on this harness, the accounts section's first-run door
    /// owns the whole page — a chain rail pointing at an empty Configure would be
    /// a dead-end hint, so it (and the disclosure) render only once accounts exist.
    @ViewBuilder
    private func harnessBody(_ status: DaemonStatus, harness: Harness, dead: Bool) -> some View {
        AccountsSection(model: model, status: status, harness: harness, dead: dead)
        if let inspected = model.inspected, inspected.harnessKind == harness {
            Divider().padding(.horizontal, 12).padding(.vertical, 6)
            DetailCard(model: model, p: inspected, dead: dead)
        }
        if !model.profiles(for: harness).isEmpty {
            Divider().padding(.horizontal, 12).padding(.vertical, 8)
            ChainRail(model: model, status: status, harness: harness, dead: dead)
            if model.showConfig {
                ConfigView(model: model, status: status, harness: harness)
                    .padding(.horizontal, 16).padding(.top, 6)
            }
        }
    }

    // MARK: - Actions (§2 — 24pt rows, shared across pages)

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
            ActionRow(icon: "power", title: "Quit ccsbar · daemon keeps running") { NSApp.terminate(nil) }
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

    // MARK: - Empty / out-of-date states

    private func outOfDateState(_ schema: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("ccsbar out of date", systemImage: "arrow.up.circle")
                .font(.subheadline).foregroundStyle(Theme.warning)
            Text("The daemon writes status.json schema \(schema); this ccsbar reads \(supportedSchema). Update ccsbar.")
                .font(.caption).foregroundStyle(.secondary)
            Divider().padding(.vertical, 6)
            ActionRow(icon: "power", title: "Quit ccsbar") { NSApp.terminate(nil) }
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
            ActionRow(icon: "power", title: "Quit ccsbar") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 16)
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
