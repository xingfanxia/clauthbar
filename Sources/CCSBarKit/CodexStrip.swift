import SwiftUI

/// The CODEX page's exception surface (TABS-1) — the codex sibling of
/// `StatusStrip`, priority-ordered the same way: dead-daemon banner > switch
/// lifecycle (codex-harness switches only) > rate-limit card > active line.
///
/// Deliberately STATE, not prediction: the daemon publishes no codex forecast
/// (its `forecast` field is claude-only), and a client-side mirror of the codex
/// walk is exactly the drift the published claude forecast was built to kill —
/// so this strip reports what IS (active login, credential age, limiter verdict)
/// and leaves "what would happen next" to a future daemon-published field.
struct CodexStrip: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        Group {
            if model.liveness.isStalled {
                DeadDaemonBanner(model: model)
            } else if model.switchPhase != .idle, model.switchHarness == .codex {
                SwitchLifecycleRow(phase: model.switchPhase, currentName: model.activeCodex?.name)
            } else if let active = model.activeCodex {
                if let limited = Self.rateLimitLine(active) {
                    rateLimitCard(limited)
                } else {
                    activeLine(active)
                }
            } else if !model.profiles(for: .codex).isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                    Text("No active codex account — pick one below.").font(.callout)
                    Spacer(minLength: 0)
                }
            }
            // Zero codex profiles: no strip at all — the accounts section's
            // first-run door owns that state.
        }
        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 8)
    }

    // MARK: - Active line

    private func activeLine(_ active: ProfileStatus) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Active \(active.name) — codex uses this login")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Text(stampLine(active)).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    /// "login captured 2h ago · updated 3s ago" — the CREDENTIAL age (when the
    /// stored login was captured/adopted) is distinct from usage freshness, and
    /// naming it prevents reading a week-old capture as a week-old panel.
    private func stampLine(_ active: ProfileStatus) -> String {
        var parts: [String] = []
        if let captured = active.codexSnapshotAt, let d = Theme.parseISO(captured) {
            parts.append("login captured \(StatusModel.ago(Int(Date().timeIntervalSince(d))))")
        }
        parts.append(model.freshnessWord)
        return parts.joined(separator: " · ")
    }

    // MARK: - Rate-limit card

    /// The limiter verdict as user words, or nil when not limited.
    /// `codex_rate_limit_reached` is a TWO-window signal: `"primary"` = the 5h
    /// window rejected the last request, `"secondary"` = the weekly (7d) window.
    /// An unrecognized future value degrades to a generic line, never hides.
    ///
    /// LAPSE CROSS-CHECK (the daemon contract, status_json.rs: "Readers cross-check
    /// the named window's resets_at — a lapsed window clears the badge"): the
    /// verdict is a STICKY cached value, only overwritten on the next usage event,
    /// so after the named window's reset passes the daemon no longer considers the
    /// account blocked (its `codex_limiter_blocked` gates on window liveness) while
    /// the raw field still says "primary". Mirror that gate here — a recovered
    /// account must not wear a red limit card the daemon would ignore. The
    /// unrecognized case degrades the same way the daemon does: limited only while
    /// EITHER window is still live. `now` is injected for deterministic tests.
    static func rateLimitLine(
        _ p: ProfileStatus, now: Date = Date()
    ) -> (message: String, resetsAt: String?)? {
        func live(_ w: UsageWindow?) -> Bool {
            guard let iso = w?.resetsAt, let resets = Theme.parseISO(iso) else { return false }
            return resets > now
        }
        switch p.codexRateLimitReached {
        case nil:
            return nil
        case "primary":
            guard live(p.fiveHour) else { return nil }
            return ("\(p.name) hit its 5h window", p.fiveHour?.resetsAt)
        case "secondary":
            guard live(p.sevenDay) else { return nil }
            return ("\(p.name) hit its weekly window", p.sevenDay?.resetsAt)
        case .some:
            guard live(p.fiveHour) || live(p.sevenDay) else { return nil }
            return ("\(p.name) is rate-limited", nil)
        }
    }

    private func rateLimitCard(_ limited: (message: String, resetsAt: String?)) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11)).foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(limited.message) — auto-switch rotates at the session boundary")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                if let hint = Theme.resetHint(limited.resetsAt) {
                    Text(hint).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
