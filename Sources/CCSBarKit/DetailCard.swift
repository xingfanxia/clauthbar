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
            // CLA-SPLIT: sessions on this account run on a static setup-token
            // mint — surface it and its ~1yr horizon (WARNING inside 30 days,
            // DANGER + re-mint hint once expired). Read from the sidecar per
            // render; nothing shows for profiles without one. CLA-FEED: a
            // feed-enabled profile (status.json `session_feed`) renders its
            // hours-scale countdown as calm maintenance instead.
            if p.provider == "anthropic",
               let line = SessionToken.statusLine(
                   SessionToken.state(profile: p.name),
                   nowMs: Int64(Date().timeIntervalSince1970 * 1000),
                   fed: p.sessionFeed
               ) {
                Text(line.text)
                    .font(.caption)
                    .foregroundStyle(line.tone == .danger ? Theme.danger
                        : line.tone == .warning ? Theme.warning : .secondary)
                    .lineLimit(1)
            }
            // Codex profiles (provider "openai") carry %-windows (INT-2) so they
            // take a window path, not the third-party availability card — but
            // their window SET is dynamic (weekly-only since 2026-07, OpenAI
            // dropped the 5h limit), so codex renders only the windows that exist
            // instead of the fixed claude {5h, 7d} rows.
            if p.isCodex {
                codexWindows
            } else if p.provider == "anthropic" {
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

    /// Codex's dynamic window rows: only what exists. Weekly-only (the 2026-07
    /// OpenAI shape) shows ONE "Weekly 7d" row with its real multi-day reset —
    /// never a phantom "Session 5h —". The threshold tick renders only on a real
    /// 5h row (chain thresholds are 5h semantics).
    @ViewBuilder private var codexWindows: some View {
        VStack(spacing: 8) {
            if let five = p.fiveHour {
                windowRow("Session 5h", five, tick: p.fallback?.threshold)
            }
            if let seven = p.sevenDay {
                windowRow("Weekly 7d", seven, tick: nil)
            }
            if p.fiveHour == nil, p.sevenDay == nil {
                Text("No usage data yet — appears after the first codex turn.")
                    .font(.subheadline).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        // OAuth (anthropic) accounts renew via browser; codex profiles renew via the
        // codex PKCE browser flow (TABS-1). Third-party api-key profiles have no
        // login to renew — the daemon never marks them auth_broken, but guard anyway
        // so this surface and the context-menu item agree on who can reauth.
        if p.authBroken && (p.provider == "anthropic" || p.isCodex) {
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

    /// The harness's identity hue (TABS-1.1): terracotta claude, codex blue codex.
    /// Codex uses ONE hue for identity and verb — white on #0A60FF is already AA
    /// (5.1:1); terracotta needs the darkened `actVerb` for its verb fills.
    private var identity: Color { p.isCodex ? Theme.codex : Theme.accent }
    private var identityVerb: Color { p.isCodex ? Theme.codex : Theme.actVerb }

    private var activeState: some View {
        VStack(spacing: 5) {
            HStack {
                Spacer()
                Label(p.hasLiveSession ? "Active account · live session attached" : "Active account",
                      systemImage: "checkmark.circle.fill")
                    .font(.subheadline).foregroundStyle(identity)
                Spacer()
            }
            .frame(height: 28)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(identity.opacity(0.5), lineWidth: 1))
            // The active account has no switch verb — so name the path. This is the
            // one spot a first-time user looks for "how do I switch?" (the panel opens
            // with the active account inspected, i.e. on exactly this card). The count
            // is HARNESS-scoped (TABS-1): "above" means this page's list, and a
            // single-codex page must not point at claude rows it doesn't show.
            if model.profiles(for: p.harnessKind).count > 1 {
                Text("Pick another account above to switch to it.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    /// AUTH-3: the account's login dropped (`auth_broken`). Instead of a dead-end
    /// "run clauth login" hint, offer a one-click browser reauth — it re-mints
    /// tokens and clears the flag (works daemon-up or -down). Shows an in-flight
    /// state while the browser sign-in runs. TABS-1: a codex profile recovers via
    /// the codex PKCE browser flow (`--codex --browser`); the context menu also
    /// offers the instant re-capture path.
    private var reauthSurface: some View {
        let inFlight = model.reauthInFlight == p.name
        let cli = p.isCodex ? "clauth login \(p.name) --codex --browser" : "clauth login \(p.name)"
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
                model.reauth(p.name, codex: p.isCodex)
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
                .background(identityVerb.opacity(inFlight ? 0.5 : 1), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(model.reauthInFlight != nil)
            .help("Re-authenticate \(p.name) with a browser sign-in (runs `\(cli)`).")
        }
    }

    private func switchButton(idleTitle: String) -> some View {
        let target = p.name
        let (title, tint): (String, Color) = {
            switch model.switchPhase {
            case .arming(let t) where t == target:
                // Harness-matched current active (TABS-1): only claude arms today
                // (codex has no live-session signal), but the wording routes anyway.
                let current = model.activeProfile(for: p.harnessKind)?.name ?? "current"
                return ("Confirm — live session on \(current)", Theme.danger)
            case .pending(let t) where t == target:
                return ("Switching to \(target)…", identityVerb)
            default:
                return (idleTitle, identityVerb)
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
        // Name the real mechanism per harness (TABS-1). Codex must NOT claim it
        // affects running codex sessions: `clauth start` codex sessions run
        // isolated CODEX_HOMEs the shared-login rewrite can't strand.
        .help(p.isCodex
              ? "Rewrites ~/.codex/auth.json at the session boundary — isolated codex sessions (clauth start) are unaffected."
              : "Rewrites the macOS Keychain credential — affects running claude sessions.")
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
