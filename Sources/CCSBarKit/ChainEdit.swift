import Foundation

/// The shared vocabulary for the two config surfaces (design §7) — the right-click
/// context menu AND the inline Configure disclosure both read from here so the
/// preset list, the threshold legend, and the removal-confirm copy have exactly
/// ONE source of truth (they were duplicated string literals before).
///
/// The "wrap-off" jargon is deliberately absent from every user-facing string here
/// (§7): the setting is rendered as outcome language ("stay on last account" /
/// "switch everything off"), never the internal flag name.
enum ChainEdit {
    /// The auto-switch threshold presets offered in both surfaces (§7) — the 5h
    /// utilization at which auto-switch LEAVES the account. Independent of the
    /// last-resort flag (a member can leave at 80% and still be the chain's last
    /// resort); see `lastResortLabel`. "Custom…" beside them accepts any whole
    /// percent in `fiveHourCustomRange`.
    static let thresholdPresets = [50, 80, 90, 95, 100]

    /// Legal band for a CUSTOM 5h threshold — mirrors the daemon socket's
    /// `set_threshold` validation (0…100) exactly, so the field rejects
    /// precisely what the socket would.
    static let fiveHourCustomRange = 0...100

    /// Parse a typed custom 5h threshold: a whole percent inside
    /// `fiveHourCustomRange` (the socket takes integers from this surface).
    /// `nil` = keep the field open with the invalid treatment.
    static func parseFiveHourThreshold(_ raw: String) -> Int? {
        guard let v = Int(raw.trimmingCharacters(in: .whitespaces)),
              fiveHourCustomRange.contains(v) else { return nil }
        return v
    }

    /// The chain-wide weekly (7d) line presets (clauth `set_weekly_threshold`).
    /// 100 reproduces the old hard-cap behavior (leave only once the API
    /// already refuses).
    static let weeklyPresets: [Double] = [90, 95, 98, 100]

    /// The default weekly line a daemon that predates the field is running
    /// (clauth `DEFAULT_WEEKLY_SWITCH_PCT`).
    static let defaultWeeklyLine: Double = 98

    /// Legal band for a custom weekly line — mirrors the daemon socket's
    /// `set_weekly_threshold` validation (50…100) exactly.
    static let weeklyCustomRange: ClosedRange<Double> = 50...100

    /// Parse a typed custom weekly line: a percent (decimals allowed) inside
    /// `weeklyCustomRange`. `nil` = keep the field open, invalid treatment.
    static func parseWeeklyLine(_ raw: String) -> Double? {
        guard let v = Double(raw.trimmingCharacters(in: .whitespaces)),
              v.isFinite, weeklyCustomRange.contains(v) else { return nil }
        return v
    }

    /// Label for a weekly value — no trailing `.0` on whole percents.
    static func weeklyLabel(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(value))%" : "\(value)%"
    }

    /// The one-line legend under the weekly control: what the number MEANS.
    static let weeklyLegend = "Auto-switch treats an account past this share of its weekly (7d) window as spent — it leaves early instead of bricking for days at 100%."

    /// The menu/editor affordance label for a free-typed value (§7).
    static let customLabel = "Custom…"

    /// Chain members first — ordered by their index in `chain` (the `fallbackChain`
    /// name array, the SAME source the chain-rail chips and the detail-card ordinal
    /// read, so all three chain-order surfaces agree by construction) — then any
    /// non-members (the "Add" rows) in file order. The config editor renders rows in
    /// this order, unlike the main ACCOUNTS list's fixed file order, so Move up/down
    /// visibly reorders the list. A member somehow absent from `chain` sorts last
    /// among members (stable → file order). Pure, so it's unit-tested.
    static func chainOrdered(_ profiles: [ProfileStatus], chain: [String]) -> [ProfileStatus] {
        let members = profiles
            .filter { $0.fallback != nil }
            .sorted { (chain.firstIndex(of: $0.name) ?? .max) < (chain.firstIndex(of: $1.name) ?? .max) }
        let nonMembers = profiles.filter { $0.fallback == nil }
        return members + nonMembers
    }

    /// The menu label for a threshold preset — a plain percentage. "Last resort" is
    /// no longer a threshold value; it is the independent `last_resort` flag (see
    /// `lastResortLabel`), so 100 reads as a normal "leave at 100%" threshold.
    static func thresholdLabel(_ value: Int) -> String {
        "\(value)%"
    }

    /// The compact label for a member's CURRENT threshold (the disclosure's value chip).
    static func currentThresholdLabel(_ threshold: Double) -> String {
        "\(Int(threshold))%"
    }

    /// The chain rail's one-line "when spent" summary — same outcome language as the
    /// wrap-off radio so a third surface can't drift from the editor (§7).
    static func whenSpentSummary(wrapOff: Bool) -> String {
        wrapOff ? "when spent: switch everything off" : "when spent: stay on last account"
    }

    /// The CODEX chain rail's when-spent line (TABS-1). Codex has NO wrap-off —
    /// the daemon rotates the codex slot at the session boundary when the active
    /// login hits a limiter window, and simply stays put when every member is
    /// limited — so the claude wrap-off wording would describe a behavior codex
    /// never performs.
    static let codexWhenSpentSummary =
        "when limited: rotates at the session boundary; stays put when all are limited"

    /// The one-line legend under the threshold controls (§7): says what the number
    /// MEANS so "95%" isn't read as "switch TO this at 95%".
    static let thresholdLegend = "Auto-switch LEAVES this account at this 5h usage."

    /// The per-member last-resort toggle label (§7). `last_resort` is an explicit,
    /// threshold-independent flag (clauth `set_last_resort`): the walk parks on this
    /// member once nothing else has headroom, even while it's over its own limit.
    static let lastResortLabel = "Last resort"

    /// The one-line legend for the last-resort flag — kept consistent with
    /// ForecastEngine's CONTRACT (the walk's exclusive last-resort pass). Reused as
    /// the tooltip on the config toggle and the row's flag badge (one source of truth).
    static let lastResortLegend = "Last resort: the chain parks here when nothing else has headroom — even while this account is over its own limit."

    /// "+ Add" clarifies it adds an EXISTING profile; creating a brand-new account is
    /// the separate "Add account…" affordance at the foot of the ACCOUNTS list (§7 —
    /// the chain disclosure must not imply it creates accounts).
    static let addHint = "Adds an existing clauth profile to the chain (create a new account with \u{201C}Add account\u{2026}\u{201D} in the ACCOUNTS list)."

    /// The wrap-off radio, in outcome language (§7). `off == false` (stay) is the
    /// first/default option.
    static let stayOnLastLabel = "Stay on last account"
    static let switchEverythingOffLabel = "Switch everything off"
    static let switchEverythingOffDetail = "Credentials cleared; resumes automatically when a window resets."

    /// Whether removing `name` from the chain needs an inline confirm, and the exact
    /// consequence copy to show (§7 + the Watchtower graft). `nil` ⇒ remove freely —
    /// it isn't an armed member, so nothing auto-switch depends on leaves.
    ///
    /// Pure over the status so it's unit-testable and both surfaces agree.
    static func removalConsequence(of name: String, in status: DaemonStatus) -> RemovalConsequence? {
        guard let p = status.profiles.first(where: { $0.name == name }),
              p.fallback?.armed == true else { return nil }
        // Armed is per-harness daemon-side (each harness arms against ITS active
        // slot), so the "auto-switch continues on the others" consequence is only
        // true of SAME-harness armed members — a claude armed member does nothing
        // for a codex chain whose sole armed member is being removed (TABS-1).
        let otherArmed = status.profiles.contains {
            $0.name != name && $0.harnessKind == p.harnessKind && ($0.fallback?.armed ?? false)
        }
        return otherArmed ? .armedMember : .disablesAutoSwitch
    }
}

/// Client-side name check for the "Add account…" flow, mirroring clauth's
/// `validate_profile_name` (clauth `src/actions.rs`) EXACTLY so the panel rejects
/// precisely the names the CLI would: trimmed and non-empty; every char an ASCII
/// alphanumeric or one of `- _ . @ +`; not starting with `.`; and no
/// CASE-INSENSITIVE collision with an existing profile.
///
/// WHY the collision is pre-blocked here rather than deferred to the CLI: `clauth
/// login <existing>` silently RE-AUTHENTICATES that profile — its interactive
/// "overwrite?" confirm never fires for ccsbar's non-TTY spawn — so an un-blocked
/// duplicate would quietly reauth someone else's account instead of erroring. The
/// hint therefore routes a duplicate to that account's "Log in again" instead.
/// When no profiles are known (daemon down, no snapshot), the caller passes an
/// empty `existing` so the collision check is skipped and clauth stays the
/// authority (a non-zero exit surfaces through the failure copy).
///
/// Pure over its inputs, so it's unit-tested without a daemon or a real login.
enum AddAccountValidation {
    /// clauth's RESERVED subcommand names (src/actions.rs) — `clauth <reserved>`
    /// would run the subcommand instead of switching, so the CLI refuses them
    /// case-insensitively. Mirrored here for instant inline feedback (the CLI
    /// still enforces authoritatively on spawn).
    static let reservedNames: Set<String> = [
        "daemon", "status", "doctor", "which", "start", "login", "delete",
        "fallback", "proxy", "resume", "run", "mcp", "__complete", "mcp-await-job",
    ]

    /// The exact reason `name` is unusable, or nil when it's valid.
    static func error(_ name: String, existing: [String]) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Name can't be empty." }
        if reservedNames.contains(trimmed.lowercased()) {
            return "'\(trimmed)' is a clauth command name — pick another."
        }
        // `is_ascii_alphanumeric()` in clauth — ASCII digits/letters only (NOT the
        // Unicode-wide `Character.isLetter`), plus the same five punctuation chars.
        let charsetOK = trimmed.allSatisfy { c in
            if let a = c.asciiValue,
               (a >= 48 && a <= 57) || (a >= 65 && a <= 90) || (a >= 97 && a <= 122) {
                return true
            }
            return c == "-" || c == "_" || c == "." || c == "@" || c == "+"
        }
        if !charsetOK || trimmed.hasPrefix(".") {
            return "Use only letters, digits, '-', '_', '.', '@', or '+', and don't start with '.'."
        }
        if existing.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return "'\(trimmed)' already exists — use Log in again on that account."
        }
        return nil
    }
}

/// The consequence of removing an armed chain member — drives the inline confirm
/// copy so it's truthful about whether auto-switch actually stops.
enum RemovalConsequence: Equatable, Sendable {
    /// The last armed member — removing it stops auto-switch entirely.
    case disablesAutoSwitch
    /// Armed, but other armed members remain — auto-switch continues on them.
    case armedMember

    var prompt: String {
        switch self {
        case .disablesAutoSwitch: return "This disables auto-switch — remove anyway?"
        case .armedMember: return "This account is armed for auto-switch — remove anyway?"
        }
    }
}
