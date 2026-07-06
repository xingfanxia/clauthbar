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
            .disabled(p.authBroken)
        }
        Button("Refresh \(p.name)") { model.refresh(p.name) }
            .disabled(!model.daemonReachable)

        // Browser reauth (AUTH-3) — for OAuth (anthropic) accounts only; third-party
        // api-key profiles have no login to renew. Offered generally, not just when
        // broken, so a flaky login can be refreshed proactively. The in-flight state
        // shows in the panel-top banner (global), so this is visible even when the
        // inspected card isn't the broken-account reauth surface.
        if p.provider == "anthropic" {
            Button(p.authBroken ? "Log in again (browser)" : "Re-authenticate (browser)") {
                model.inspect(p.name)
                model.reauth(p.name)
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
            }
            .disabled(!reachable)

            Button("Move up") { model.fallbackMove(p.name, up: true) }
                .disabled(!reachable || fb.position <= 1)
            Button("Move down") { model.fallbackMove(p.name, up: false) }
                .disabled(!reachable || fb.position >= status.fallbackChain.count)

            Button("Remove from chain") { model.requestRemove(p.name) }
                .disabled(!reachable)
        } else {
            Button("Add to chain") { model.fallbackAdd(p.name) }
                .disabled(!reachable)
        }
    }
}
