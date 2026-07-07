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
    /// resort); see `lastResortLabel`.
    static let thresholdPresets = [50, 80, 90, 95, 100]

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

    /// "+ Add" clarifies it adds an EXISTING profile; account creation is a separate
    /// `clauth login` (§7 — the disclosure must not imply it creates accounts).
    static let addHint = "Adds an existing clauth profile to the chain (create accounts with `clauth login`)."

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
        let otherArmed = status.profiles.contains { $0.name != name && ($0.fallback?.armed ?? false) }
        return otherArmed ? .armedMember : .disablesAutoSwitch
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
