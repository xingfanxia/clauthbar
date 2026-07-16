import AppKit
import SwiftUI

/// The right-click context menu carried by every account row (design §7 — the FAST
/// PATH). Native `NSMenu` metrics give the full chain-edit vocabulary at free 13/24pt
/// without opening the Configure disclosure: switch, per-account refresh, add/remove,
/// reorder, the "Leave chain at ▸" preset submenu, and copy-name. 80% of edits never
/// open an editor.
///
/// Rendered inside `.contextMenu { AccountContextMenu(...) }`, so the body is menu
/// items, not chrome. Commands route through `StatusModel` (same socket path as the
/// disclosure); removal goes through `requestRemove` so the armed-member confirm fires.
struct AccountContextMenu: View {
    @ObservedObject var model: StatusModel
    let p: ProfileStatus
    let status: DaemonStatus

    var body: some View {
        // Switch — hidden for the active account (nothing to switch to) and disabled
        // for an auth-broken target (a revoked login must never be a switch target).
        if !p.active {
            // Honest about the CLI-fallback path when the daemon is down (matches
            // DetailCard) — a switch still works via `clauth <name>`, but auto-switch
            // stays inactive until the daemon restarts.
            // Broken accounts can't be a switch target; the "Log in again" item below
            // owns the recovery CTA, so this just states the state (no dead-end CLI hint).
            let switchTitle = p.authBroken ? "Login expired"
                : model.daemonReachable ? "Switch to \(p.name)"
                : "Switch to \(p.name) via CLI (daemon offline)"
            Button(switchTitle) {
                // Inspect FIRST so a live-session arm surfaces its Confirm button in
                // the detail card (the arm-confirm affordance is keyed to the
                // inspected profile) — otherwise a context-menu switch that arms
                // would strand the confirm and silently time out.
                model.inspect(p.name)
                model.switchTo(p.name)
            }
            // Disabled while ANY switch is in flight (matching DetailCard's gate):
            // the machine ignores a mid-pending request, so an enabled item whose
            // tap silently no-ops reads as broken.
            .disabled(p.authBroken || model.switchInFlight)
        }
        Button("Refresh \(p.name)") { model.refresh(p.name) }
            .disabled(!model.daemonReachable)

        // Reauth (AUTH-3) — for OAuth (anthropic) accounts and codex profiles;
        // third-party api-key profiles have no login to renew. Offered generally,
        // not just when broken, so a flaky login can be refreshed proactively. The
        // in-flight state shows in the panel-top banner (global), so this is
        // visible even when the inspected card isn't the reauth surface.
        if p.provider == "anthropic" {
            Button(p.authBroken ? "Log in again (browser)" : "Re-authenticate (browser)") {
                model.inspect(p.name)
                model.reauth(p.name)
            }
            .disabled(model.reauthInFlight != nil)
        } else if p.isCodex {
            // TABS-1: a codex profile has TWO recovery doors — a fresh PKCE browser
            // sign-in, or the instant re-capture of whatever login codex currently
            // holds (useful after signing in inside codex itself).
            Button(p.authBroken ? "Log in again (browser)" : "Re-authenticate (browser)") {
                model.inspect(p.name)
                model.reauth(p.name, codex: true, mode: .browser)
            }
            .disabled(model.reauthInFlight != nil)
            Button("Re-capture from codex login") {
                model.inspect(p.name)
                model.reauth(p.name, codex: true, mode: .capture)
            }
            .disabled(model.reauthInFlight != nil)
        }

        // Rename the profile (socket-only — needs a live daemon). Opens the inline
        // rename banner; any provider can be renamed.
        Button("Rename…") { model.beginRename(p.name) }
            .disabled(!model.daemonReachable)

        Divider()

        // Chain membership + ordering (socket-only — need a live daemon).
        chainItems

        Divider()

        Button("Copy account name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(p.name, forType: .string)
        }
    }

    @ViewBuilder private var chainItems: some View {
        let reachable = model.daemonReachable
        if let fb = p.fallback {
            Menu("Leave chain at") {
                ForEach(ChainEdit.thresholdPresets, id: \.self) { v in
                    Button {
                        model.setThreshold(p.name, v)
                    } label: {
                        // A checkmark on the current threshold (NSMenu shows it inline).
                        if Int(fb.threshold) == v {
                            Label(ChainEdit.thresholdLabel(v), systemImage: "checkmark")
                        } else {
                            Text(ChainEdit.thresholdLabel(v))
                        }
                    }
                }
                Divider()
                // Free-typed percent — the field lives in the Configure
                // disclosure, so this arms it and opens the panel there.
                Button(ChainEdit.customLabel) {
                    model.beginThresholdEdit(
                        .fiveHour(p.name), current: "\(Int(fb.threshold))")
                }
            }
            .disabled(!reachable)

            // Toggle the exclusive last-resort flag (clauth set_last_resort) — a
            // checkmark shows the current state. Independent of the threshold above.
            Button {
                model.setLastResort(p.name, !fb.lastResort)
            } label: {
                if fb.lastResort {
                    Label(ChainEdit.lastResortLabel, systemImage: "checkmark")
                } else {
                    Text(ChainEdit.lastResortLabel)
                }
            }
            .disabled(!reachable)

            Button("Move up") { model.fallbackMove(p.name, up: true) }
                .disabled(!reachable || fb.position <= 1)
            // The tail bound is the profile's OWN harness's chain (TABS-1) — a
            // codex member's position indexes codex_fallback_chain, and the claude
            // chain's length would wrongly enable/disable it.
            Button("Move down") { model.fallbackMove(p.name, up: false) }
                .disabled(!reachable || fb.position >= status.chain(for: p.harnessKind).count)

            Button("Remove from chain") { model.requestRemove(p.name) }
                .disabled(!reachable)
        } else {
            Button("Add to chain") { model.fallbackAdd(p.name) }
                .disabled(!reachable)
        }
    }
}
