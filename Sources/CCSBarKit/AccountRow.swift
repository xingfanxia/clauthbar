import SwiftUI

/// One account in the CBAR-4 list (design §2 row anatomy). Rows never reorder; only
/// the terracotta ✓ badge and the inspection ring move. Single click INSPECTS (pure
/// view state, zero daemon traffic). In the dead state rows dim to 60%, bars go
/// greyscale, and every stamp becomes "as of Xm ago".
struct AccountRow: View {
    @ObservedObject var model: StatusModel
    let p: ProfileStatus
    let status: DaemonStatus
    let inspected: Bool
    let dead: Bool
    let frozenStamp: String? // "as of 4m ago" when dead, else nil
    let onInspect: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            // WHICH login this profile holds (CAP-3), a dim caption indented
            // under the name — the list-row sibling of DetailCard's email line
            // (and ccu's). Only OAuth profiles carry account_email, so no
            // provider gate is needed.
            if let email = p.accountEmail {
                Text(email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 18)
                    .padding(.top, -3)
            }
            // Codex profiles publish `provider == "openai"` but carry the same
            // {5h,7d} window array as claude (INT-2), so they take the %-bar path,
            // not the third-party availability line. Only genuine api-key providers
            // (no %-windows) get thirdPartyLine.
            if p.provider != "anthropic" && !p.isCodex {
                thirdPartyLine
            } else {
                fiveHourRow
                secondaryRow
            }
        }
        .padding(.vertical, 7).padding(.horizontal, 10)
        .background(
            // Inspected owns the 0.08 fill + ring; a bare hover gets a lighter 0.045
            // wash — a quieter cousin of ActionRow's 0.08 hover — so rows read as
            // clickable without masquerading as inspected.
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.primary.opacity(inspected ? 0.08 : (hovering ? 0.045 : 0)))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Color.primary.opacity(inspected ? 0.18 : 0), lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onInspect)
        .onHover { hovering = $0 }
        .contextMenu { AccountContextMenu(model: model, p: p, status: status) }
        .opacity(dead ? 0.6 : 1)
        .help(
            "\(p.name) · \(p.tier ?? p.provider)"
                + (p.accountEmail.map { " · \($0)" } ?? "")
                + " — click to inspect"
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(voiceOver)
    }

    // MARK: - Header (badge + name + tier + badge cluster)

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: p.active ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12))
                .foregroundStyle(p.active ? Theme.accent : Color.secondary)
            // A spent account's name mutes — a pre-attentive "this one's unavailable".
            Text(p.name).font(.body).fontWeight(.semibold).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(rowSpentTag != nil ? Color.secondary : Color.primary)
            if let tier = p.tier {
                Text(tier).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            } else if p.provider != "anthropic" {
                Text(providerLabel).font(.subheadline).foregroundStyle(.secondary)
            }
            // INT-2: a small "codex" harness tag so a user seeing TWO checkmarked rows
            // (one claude-active, one codex-active) reads them as two independent slots,
            // not a duplicate-active bug. Mirrors the tier/provider caption's altitude.
            if p.isCodex {
                Text("codex")
                    .font(.system(size: 10)).fontWeight(.medium)
                    .padding(.vertical, 1).padding(.horizontal, 5)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Spacer(minLength: 4)
            // The badges keep their intrinsic width (higher layout priority); a long
            // name is the sole truncation sink, so a wide cluster never clips to
            // "watchi…" on the fixed 340pt panel.
            badgeCluster.layoutPriority(1)
        }
    }

    /// The spent badge to show in THIS row — suppressed on frozen data (`dead`) so a
    /// stale 100% can't assert "spent" while the rotation engine already treats the
    /// window as reset. `ProfileStatus.spentTag` stays the pure "at cap on last read".
    private var rowSpentTag: String? { dead ? nil : p.spentTag }

    @ViewBuilder private var badgeCluster: some View {
        HStack(spacing: 5) {
            // A dead login gets a WORDED danger pill, not an icon-only glyph: its
            // fetches surface as RateLimited/Cached (the 429 mask), and an icon
            // beside a "RateLimited" text lost that fight — the operator read the
            // text and chased a rate limit while the real fix was a re-login
            // (observed 2026-07-12).
            if p.authBroken {
                Label("login expired", systemImage: "exclamationmark.shield.fill")
                    .font(.system(size: 10)).fontWeight(.medium).fixedSize()
                    .padding(.vertical, 1).padding(.horizontal, 5)
                    .background(Theme.danger.opacity(0.18), in: Capsule())
                    .foregroundStyle(Theme.danger)
                    .help("Login expired — clauth login \(p.name)")
            }
            // Exhausted: a 5h or weekly window is at its cap → the account can't be
            // used until it resets. A danger pill naming the spent window (§5 danger).
            if let tag = rowSpentTag {
                Text(tag)
                    .font(.system(size: 10)).fontWeight(.medium).fixedSize()
                    .padding(.vertical, 1).padding(.horizontal, 5)
                    .background(Theme.danger.opacity(0.18), in: Capsule())
                    .foregroundStyle(Theme.danger)
                    .help("This account has hit a usage limit — unavailable until it resets")
            }
            // "watching" (not a bare bolt): auto-switch is watching this account and
            // will rotate away from it at its threshold (sapphire = the armed hue, §5).
            if p.fallback?.armed == true {
                Label("watching", systemImage: "bolt.fill")
                    .font(.system(size: 10)).fontWeight(.medium).foregroundStyle(Theme.sapphire).fixedSize()
                    .help("Auto-switch is watching this account — it rotates away at the threshold")
            }
            if p.fallback?.lastResort == true {
                Image(systemName: "flag.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    .help(ChainEdit.lastResortLegend)
            }
            if p.hasLiveSession {
                Text("in use").font(.system(size: 10)).foregroundStyle(.secondary)
                    .help("A claude session is attached to this account")
            }
            // Suppressed while the login is broken: the stale fetch status is a
            // CONSEQUENCE of the dead login (its 429/cached reads), and showing
            // both makes the transient-looking one win attention.
            if !p.authBroken, p.isStale, let fs = p.fetchStatus {
                Text(fs).font(.system(size: 10)).foregroundStyle(Theme.warning)
            }
        }
    }

    // MARK: - 5h hero row

    private var fiveHourRow: some View {
        let pct = p.fiveHourPct
        return VStack(spacing: 3) {
            UsageBar(
                pct: pct,
                color: dead ? Color.secondary.opacity(0.5) : Theme.usageColor(pct, threshold: p.fallback?.threshold ?? 100),
                height: 6,
                threshold: p.fallback?.threshold
            )
            HStack {
                Text("5h").font(.caption).foregroundStyle(.tertiary)
                Text("\(Int(pct.rounded()))%").font(.body).fontWeight(.semibold).monospacedDigit()
                Spacer()
                Text(stamp(p.fiveHour?.resetsAt)).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 7d / Fable secondary row (half-width bars + shared weekly reset)

    private var secondaryRow: some View {
        HStack(spacing: 10) {
            miniBar("7d", p.sevenDay?.utilizationPct)
            // Fable is a limited-trial window — render it only while the daemon still
            // reports it. The trial window simply drops out of status.json when it
            // ends, so `fableWeek` goes nil (no hardcoded end date), and the row
            // collapses to 7d + the weekly reset without a dangling "Fb —".
            if let fable = p.fableWeek {
                miniBar("Fb", fable.utilizationPct)
            }
            // A SINGLE weekly reset countdown (7d and Fable share the weekly
            // boundary), right-aligned to mirror the 5h row's "resets in …".
            if let stamp = weeklyResetStamp {
                Text(stamp).font(.subheadline).foregroundStyle(.secondary).fixedSize()
            }
        }
    }

    /// The shared weekly reset, suppressed when the data is frozen — the 5h line
    /// already carries the "as of Xm ago" stamp, and a frozen countdown would read as
    /// live. Prefers the 7d window's reset, falling back to Fable's (they share the
    /// weekly boundary) so a row never loses the timer if only one window carries it.
    private var weeklyResetStamp: String? {
        dead ? nil : Theme.resetHint(p.sevenDay?.resetsAt ?? p.fableWeek?.resetsAt)
    }

    private func miniBar(_ label: String, _ pct: Double?) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.tertiary)
            UsageBar(pct: pct ?? 0, color: dead ? Color.secondary.opacity(0.5) : Theme.usageColor(pct ?? 0), height: 4)
                .frame(maxWidth: .infinity)
            Text(pct.map { "\(Int($0.rounded()))%" } ?? "—").font(.callout).monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Third-party line (never %-bars)

    private var thirdPartyLine: some View {
        let available = p.thirdParty?.available
        let (text, color): (String, Color) = {
            switch available {
            case .some(true): return ("Available", Theme.success)
            case .some(false): return ("Unavailable", Theme.danger)
            case .none: return ("No data yet", .secondary)
            }
        }()
        return HStack(spacing: 6) {
            Circle().fill(dead ? Color.secondary : color).frame(width: 7, height: 7)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
            if let checked = stampChecked(p.fetchedAt) {
                Text("· \(checked)").font(.subheadline).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Helpers

    // clauth emits the provider's own display name (`anthropic` for OAuth, else a
    // recognised third-party provider's name), so we surface it verbatim.
    private var providerLabel: String { p.provider }

    private func stamp(_ iso: String?) -> String {
        if let frozenStamp { return frozenStamp }
        return Theme.resetHint(iso) ?? "—"
    }

    private func stampChecked(_ iso: String?) -> String? {
        if let frozenStamp { return frozenStamp }
        guard let iso, let d = Theme.parseISO(iso) else { return nil }
        return "checked \(StatusModel.ago(Int(Date().timeIntervalSince(d))))"
    }

    private var voiceOver: String {
        var parts = [p.name]
        // INT-2: name the harness so assistive tech hears the two-slots distinction
        // the visual "codex" tag conveys.
        if p.isCodex { parts.append("codex") }
        if p.active { parts.append("active account") }
        if let tier = p.tier { parts.append(tier) }
        // Parity with the hover tooltip: WHICH account this profile holds is
        // CAP-3's whole point — assistive tech must hear it too.
        if let email = p.accountEmail { parts.append(email) }
        // Order mirrors the visual badge cluster: spent pill, then the watching chip.
        if let tag = rowSpentTag { parts.append("\(tag) — hit a usage limit") }
        if p.fallback?.armed == true { parts.append("armed, watching") }
        // Codex rows carry the same 5h window as claude (INT-2), so they read the
        // session-usage percent too.
        if p.provider == "anthropic" || p.isCodex {
            parts.append("session \(Int(p.fiveHourPct.rounded())) percent used")
        }
        return parts.joined(separator: ", ")
    }
}
