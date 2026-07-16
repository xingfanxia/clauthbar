import SwiftUI

/// The detail card for the inspected account (design §2). Three windows with reset
/// times, the forecast-driven chain-membership line, and THE one switch surface —
/// which renders differently for the active account (static state), an auth-broken
/// target (disabled login hint), a dead daemon (Switch via CLI), and the normal
/// arm-confirm → pending flow.
struct DetailCard: View {
    @ObservedObject var model: StatusModel
    let p: ProfileStatus
    let dead: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            // CAP-3: WHICH account this profile's login belongs to — the
            // 2026-07-12 double-poll went unseen because no surface showed it.
            if let email = p.accountEmail {
                Text(email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            // Codex profiles (provider "openai") carry the same {5h,7d} window array as
            // claude (INT-2), so they take the window path, not the third-party
            // availability card — mirrors AccountRow's gate.
            if p.provider == "anthropic" || p.isCodex {
                windows
            } else {
                thirdPartyDetail
            }
            if let line = model.chainLine(for: p) {
                chainLine(line)
            }
            switchSurface
        }
        .padding(.horizontal, 16)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(p.name).font(.title3).fontWeight(.semibold)
            Text("· \(p.tier ?? providerLabel)").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(dead ? "as of \(model.frozenAge)" : "Fresh · \(model.freshAge)")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    // MARK: - Windows

    private var windows: some View {
        VStack(spacing: 8) {
            windowRow("Session 5h", p.fiveHour, tick: p.fallback?.threshold)
            windowRow("Weekly 7d", p.sevenDay, tick: nil)
            // Fable is a limited-trial window — shown only while the daemon still
            // reports it (it drops out of status.json when the trial ends).
            if let fable = p.fableWeek {
                windowRow("Fable", fable, tick: nil)
            }
        }
    }

    private func windowRow(_ label: String, _ w: UsageWindow?, tick: Double?) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.body).fontWeight(.medium).frame(width: 88, alignment: .leading)
            UsageBar(
                pct: w?.utilizationPct ?? 0,
                color: dead ? Color.secondary.opacity(0.5) : Theme.usageColor(w?.utilizationPct ?? 0, threshold: tick ?? 100),
                height: 6, threshold: tick
            )
            Text(w.map { "\(Int($0.utilizationPct.rounded()))%" } ?? "—")
                .font(.body).monospacedDigit().frame(width: 40, alignment: .trailing)
            Text(dead ? "" : (Theme.resetHint(w?.resetsAt).map { String($0.dropFirst("resets in ".count)) } ?? ""))
                .font(.subheadline).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
        }
    }

    private var thirdPartyDetail: some View {
        let available = p.thirdParty?.available
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(available == true ? Theme.success : (available == false ? Theme.danger : Color.secondary))
                    .frame(width: 7, height: 7)
                Text(available == true ? "Available" : (available == false ? "Unavailable" : "No data yet"))
                    .font(.body)
            }
            if let host = p.baseUrl {
                Text(host).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private func chainLine(_ text: String) -> some View {
        // Flag for a last-resort member (matches its "last resort" copy), else the
        // sapphire bolt of a watched/rotating member — keyed on the explicit
        // `last_resort` flag, not threshold-100 (the two are independent now).
        let lastResort = p.fallback?.lastResort == true
        return HStack(alignment: .top, spacing: 5) {
            Image(systemName: lastResort ? "flag.fill" : "bolt.fill")
                .font(.system(size: 10))
                .foregroundStyle(lastResort ? Color.secondary : Theme.sapphire)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - The one switch surface (§2 / §3.5-3.8)

    @ViewBuilder private var switchSurface: some View {
        // A broken login OUTRANKS the active-state readout: an ACTIVE account whose
        // OAuth dropped is the most urgent reauth case (the running claude sessions are
        // already failing on it), so the recovery verb must show even when p.active —
        // otherwise the one account you can't switch away from hides its only fix.
        // Only OAuth (anthropic) accounts have a browser login to renew; the daemon
        // never marks a third-party api-key profile auth_broken, but guard anyway so the
        // reauth surface and the context-menu item agree on who can reauth.
        if p.authBroken && p.provider == "anthropic" {
            reauthSurface
        } else if p.active {
            activeState
        } else {
            // One button for both the live and offline paths so the arm-confirm cycle
            // works in BOTH: `switchTo` applies the live-session guard regardless of
            // daemon state (a CLI switch rewrites the Keychain too), and offline the
            // dispatch falls through to `clauth <name>`. Only the idle title differs.
            let offline = dead || !model.daemonReachable
            switchButton(idleTitle: offline ? "Switch via CLI (daemon offline)" : "Switch to \(p.name)")
        }
    }

    private var activeState: some View {
        VStack(spacing: 5) {
            HStack {
                Spacer()
                Label(p.hasLiveSession ? "Active account · live session attached" : "Active account",
                      systemImage: "checkmark.circle.fill")
                    .font(.subheadline).foregroundStyle(Theme.accent)
                Spacer()
            }
            .frame(height: 28)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1))
            // The active account has no switch verb — so name the path. This is the
            // one spot a first-time user looks for "how do I switch?" (the panel opens
            // with the active account inspected, i.e. on exactly this card).
            if model.listProfiles.count > 1 {
                Text("Pick another account above to switch to it.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    /// AUTH-3: the account's OAuth login dropped (`auth_broken`). Instead of a
    /// dead-end "run clauth login" hint, offer a one-click browser reauth — it
    /// re-mints tokens and clears the flag (works daemon-up or -down). Shows an
    /// in-flight state while the browser sign-in runs.
    private var reauthSurface: some View {
        let inFlight = model.reauthInFlight == p.name
        return VStack(spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 11)).foregroundStyle(Theme.danger)
                Text("This account's login expired — re-authenticate to use it again.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
            }
            Button {
                model.reauth(p.name)
            } label: {
                HStack {
                    Spacer()
                    if inFlight {
                        Text("Opening browser to sign in…")
                    } else {
                        Label("Log in again", systemImage: "person.crop.circle.badge.plus")
                    }
                    Spacer()
                }
                .font(.body).fontWeight(.semibold).frame(height: 28).foregroundStyle(.white)
                .background(Theme.actVerb.opacity(inFlight ? 0.5 : 1), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(model.reauthInFlight != nil)
            .help("Re-authenticate \(p.name) with a browser sign-in (runs `clauth login \(p.name)`).")
        }
    }

    private func switchButton(idleTitle: String) -> some View {
        let target = p.name
        let (title, tint): (String, Color) = {
            switch model.switchPhase {
            case .arming(let t) where t == target:
                return ("Confirm — live session on \(model.active?.name ?? "current")", Theme.danger)
            case .pending(let t) where t == target:
                return ("Switching to \(target)…", Theme.actVerb)
            default:
                return (idleTitle, Theme.actVerb)
            }
        }()
        let pending: Bool = { if case .pending(let t) = model.switchPhase, t == target { return true }; return false }()
        return verbButton(title: title, tint: tint, disabled: pending || otherSwitchBusy(target)) {
            // A second tap while arming THIS target confirms; otherwise (re)start.
            if case .arming(let t) = model.switchPhase, t == target { model.confirmArmedSwitch() }
            else { model.switchTo(target) }
        }
    }

    /// True when a DIFFERENT switch is in flight — this target's button disables.
    private func otherSwitchBusy(_ target: String) -> Bool {
        guard let inFlight = model.switchPhase.inFlightTarget else { return false }
        return inFlight != target
    }

    private func verbButton(title: String, tint: Color, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Spacer(); Text(title).font(.body).fontWeight(.semibold); Spacer() }
                .frame(height: 28).foregroundStyle(.white)
                .background(tint.opacity(disabled ? 0.5 : 1), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain).disabled(disabled)
        .keyboardShortcut(.return, modifiers: .command)
        .help("Rewrites the macOS Keychain credential — affects running claude sessions.")
    }

    private func disabledVerb(_ title: String) -> some View {
        HStack { Spacer(); Text(title).font(.subheadline); Spacer() }
            .frame(height: 28).foregroundStyle(.secondary)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    // clauth emits the provider's own display name (`anthropic` for OAuth, else a
    // recognised third-party provider's name), so we surface it verbatim.
    private var providerLabel: String { p.provider }
}
