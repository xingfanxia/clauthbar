import SwiftUI

/// Polls `~/.clauth/status.json` on a timer and publishes it to the panel + the
/// menu-bar label. Also the one place that fires switch/config commands at the
/// daemon (via `DaemonClient`) and schedules a quick re-read so the UI reflects
/// the change once the daemon's next tick lands it (~1s).
///
/// TABS-1 decomposition: this file owns the STORED STATE, polling, and derived
/// display; the switch-machine effects live in `StatusModelSwitch.swift` and the
/// command/login/config actions in `StatusModelActions.swift` (same-type
/// extensions). Properties those files mutate are module-internal by necessity —
/// views must still treat them as read-only.
@MainActor
final class StatusModel: ObservableObject {
    /// Daemon liveness the panel must render distinctly (TECH-4). `.ok` shows the
    /// live panel; `.stalled` overlays a banner on the (last-known) content;
    /// `.outOfDate` and `.down` are separate empty states — never a fresh-looking
    /// panel over a dead daemon.
    enum Liveness: Equatable, Sendable {
        case ok
        case stalled(since: String)
        case outOfDate(schema: Int)
        case down

        /// A frozen-but-present status (the dead-daemon banner case with content to
        /// dim), distinct from `.down` (never written) and `.outOfDate` (schema).
        var isStalled: Bool { if case .stalled = self { return true }; return false }
    }

    @Published private(set) var status: DaemonStatus?
    @Published private(set) var liveness: Liveness = .down
    /// The selected provider page (TABS-1). Persisted manually through UserDefaults
    /// — NOT @AppStorage, which is a SwiftUI DynamicProperty and never publishes
    /// from inside an ObservableObject (the panel would silently stop re-rendering
    /// on tab taps). Changing tabs resets inspection: it's per-page view state.
    @Published var tab: ProviderTab {
        didSet {
            // Inspection is per-page view state — always reset on a page change
            // (didSet doesn't fire for the init assignment, so injected preview
            // inspection survives). Persistence is real-app only.
            if oldValue != tab { inspectedName = nil }
            guard !isPreview else { return }
            UserDefaults.standard.set(tab.rawValue, forKey: ProviderTab.persistenceKey)
        }
    }
    /// A transient, human-readable error from the last command (TECH-11) — a daemon
    /// rejection or an unreachable daemon. Rendered as a banner; auto-cleared after
    /// a few seconds and on the next successful command ('errors must be loud').
    /// (Internal set: mutated by the Actions/Switch extension files.)
    @Published var lastCommandError: String?
    /// The user-initiated switch lifecycle (CBAR4-3) — drives the panel's
    /// arm-confirm / pending / confirmed / failed states. The pure transitions live
    /// in `SwitchMachine`; `StatusModelSwitch.swift` owns the effects.
    @Published var switchPhase: SwitchMachine.Phase = .idle
    /// A transient "rotated to X" flash (8s) when the daemon auto-switched the active
    /// account with no local pending switch (CBAR4-3 rotation heartbeat) — the hero
    /// feature's only in-panel proof it fired.
    @Published private(set) var rotationFlash: String?
    @Published var showConfig = false
    /// Which threshold field is inline-editing a CUSTOM value, if any — armed by
    /// the "Custom…" affordance on either config surface. The context menu arms
    /// it too (it also opens the Configure disclosure, where the field lives).
    @Published var thresholdEdit: ThresholdEditTarget?
    /// The in-flight text of the custom-threshold field.
    @Published var thresholdDraft = ""
    /// The chain member awaiting the inline removal confirm (CBAR4-5 §7 — removing
    /// an ARMED member requires an explicit "remove anyway?"). `nil` ⇒ no confirm
    /// pending. Copy comes from `ChainEdit.removalConsequence`.
    @Published var pendingRemoval: String?
    /// The profile currently being renamed — drives the inline rename banner (a
    /// TextField + confirm). `nil` ⇒ no rename in progress. Set by the context-menu
    /// "Rename…" item, cleared on commit/cancel.
    @Published var renaming: String?
    /// Count of config socket round-trips in flight (CBAR4-5 §7 pending shimmer) —
    /// the disclosure shows an honest "Applying…" while > 0. Cleared as each
    /// command's reply lands (the settle ladder then updates the view).
    @Published var configInFlight = 0
    /// The login currently in flight (`clauth login …`), or nil. Mode-aware (TABS-1):
    /// a browser sign-in shows "finish in your browser…" while a codex CAPTURE — an
    /// instant, no-browser copy of the live codex login — must not claim a browser is
    /// involved. SHARED by reauth AND add-account (one login at a time, all flows).
    @Published var loginInFlight: LoginFlight?
    /// The in-flight login's profile name — the pre-TABS-1 surface every gate and
    /// test reads; kept as an alias so "is a login running" checks stay one idiom.
    var reauthInFlight: String? { loginInFlight?.name }
    /// Which harness the open inline "Add account…" editor targets, or nil when
    /// closed (TABS-1: each harness page has its own add row; the codex editor
    /// offers capture + browser, the claude editor browser only).
    @Published var addingHarness: Harness?
    /// Whether the inline add editor is open (pre-TABS-1 alias over `addingHarness`).
    var addingAccount: Bool { addingHarness != nil }
    /// The machine-wide token snapshot (TOK-4) from `~/.clauth/tokens.json`, or nil
    /// when the file is missing / a newer schema / corrupt. Read inside the existing
    /// poll (no second timer); a nil hides the strip but NEVER blanks the panel.
    @Published private(set) var machineTokens: MachineTokens?

    /// A switch is in flight (arming or pending) — tiles disable to block a second
    /// concurrent switch (M5/TECH-11), now derived from the phase.
    var switchInFlight: Bool { switchPhase.isBusy }

    /// A config command's socket round-trip is in flight — drives the pending
    /// shimmer (§7).
    var configBusy: Bool { configInFlight > 0 }

    /// The clauth version this ccsbar build targets. A daemon reporting a
    /// different `clauth_version` raises a SOFT skew badge (informational — the
    /// schema gate in TECH-4 handles hard read-format incompatibility). Bump this
    /// when ccsbar is validated against a new clauth release. Bumped WITH the
    /// fixture's `clauth_version` (they must move together or every snapshot grows
    /// a spurious skew badge).
    static let expectedClauthVersion = "0.11.0"

    private var timer: Timer?
    private var lastMtime: Date?
    private var lastTokensMtime: Date?
    // Task handles the extension files (Switch/Actions) own — internal so the
    // same-type extensions in sibling files can drive them; views never touch these.
    var settleTask: Task<Void, Never>?
    var errorClearTask: Task<Void, Never>?
    // Switch-machine effect tasks (CBAR4-3).
    var switchDispatchTask: Task<Void, Never>?
    var switchObserveTask: Task<Void, Never>?
    var armTimeoutTask: Task<Void, Never>?
    var pendingTimeoutTask: Task<Void, Never>?
    /// When the current pending switch entered `.pending` — the elapsed-time
    /// anchor for `SwitchMachine.shouldExtendPending`'s hard ceiling.
    var pendingSince: Date?
    var switchDismissTask: Task<Void, Never>?
    /// The harness of the in-flight switch target (TABS-1): the confirm ladder
    /// observes THIS harness's active slot, and the lifecycle row renders on the
    /// matching strip only (no cross-tab bleed). Set by `switchTo` before the
    /// phase publishes; meaningless while `.idle`.
    var switchHarness: Harness = .claude
    private var rotationClearTask: Task<Void, Never>?

    // Notification baseline (TECH-11) — set on the first observed status so the
    // initial load never fires a burst of "switched to X" notifications.
    private var hasNotifyBaseline = false
    private var lastNotifiedActive: String?
    private var lastNotifiedErrorAt: String?

    /// True for the snapshot/preview init — the panel skips its open-reset of
    /// inspection so an injected inspecting/mid-switch state survives the render.
    let isPreview: Bool

    init() {
        isPreview = false
        tab = UserDefaults.standard.string(forKey: ProviderTab.persistenceKey)
            .flatMap(ProviderTab.init(rawValue:)) ?? .overview
        Notifier.requestAuthorizationIfNeeded()
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        // Let the OS coalesce the 4s poll for power (TECH-14 #31) — a rebuildable
        // status read has no need to be punctual to the millisecond.
        timer?.tolerance = 1.0
    }

    /// Preview/snapshot init: inject a fixed status + liveness (+ optional inspection,
    /// switch phase, and PAGE for the canonical-state snapshots), no polling, no
    /// UserDefaults traffic. `tab` defaults to `.claude` so every pre-TABS-1 snapshot
    /// variant keeps rendering the page it was designed around.
    init(preview: DaemonStatus?, liveness: Liveness = .ok,
         inspected: String? = nil, phase: SwitchMachine.Phase = .idle,
         tokens: MachineTokens? = nil, tab: ProviderTab = .claude) {
        self.isPreview = true
        self.tab = tab
        self.status = preview
        self.liveness = liveness
        self.inspectedName = inspected
        self.switchPhase = phase
        self.machineTokens = tokens
    }

    /// The active account is only trustworthy when live — the menu-bar glyph dims
    /// otherwise so a frozen % never reads as current.
    var isHealthy: Bool { liveness == .ok }

    func reload() {
        // The machine-token strip reads its OWN file on its OWN mtime gate, BEFORE the
        // status republish gate below — otherwise an unchanged status.json (the early
        // return) would freeze the token numbers even as tokens.json advances.
        reloadTokens()
        // Republish gate (TECH-14 #31): when status.json hasn't changed, skip the
        // re-decode and don't churn @Published — but STILL recompute liveness,
        // because a file that stopped advancing is exactly the stalled case (its
        // age grows with wall-clock even though the bytes don't).
        let mtime = DaemonClient.statusMtime()
        if let mtime, mtime == lastMtime, let s = status {
            let next = Self.staleness(of: s, mtime: mtime)
            if next != liveness { liveness = next }
            return
        }
        lastMtime = mtime

        switch DaemonClient.readStatus() {
        case .ok(let s):
            status = s
            liveness = Self.staleness(of: s, mtime: mtime)
            maybeNotify(s)
        case .schemaUnsupported(let n):
            // Distinct from "down": the daemon IS writing, we just can't read its
            // format. Drop the (unparsed) content and show the out-of-date state.
            status = nil
            liveness = .outOfDate(schema: n)
        case .fileMissing, .decodeFailed:
            status = nil
            liveness = .down
        }
    }

    /// Read the machine-token snapshot on its own mtime gate (TOK-4). Runs every poll
    /// tick from `reload()`; skips the re-decode when tokens.json is unchanged. Every
    /// failure mode degrades QUIETLY to `nil` (strip hidden) — a missing file (no
    /// daemon snapshot yet), a newer schema (ccsbar out of date), or a corrupt write
    /// must never blank or error the panel. `readTokens()` already logs a decode
    /// failure via the os.Logger; the others are benign, so they stay silent.
    private func reloadTokens() {
        let mtime = DaemonClient.tokensMtime()
        if let mtime, mtime == lastTokensMtime, machineTokens != nil { return }
        lastTokensMtime = mtime
        switch DaemonClient.readTokens() {
        case .ok(let t):
            machineTokens = t
        case .fileMissing, .schemaUnsupported, .decodeFailed:
            // Guard the nil re-assignment: with no tokens file (mtime nil), the gate
            // above can't short-circuit, so an unguarded `= nil` would fire
            // objectWillChange every 4s tick and re-render the open panel for nothing.
            if machineTokens != nil { machineTokens = nil }
        }
    }

    /// A daemon that dies AFTER writing status.json freezes the file `Fresh`; the
    /// only truth is age. Maps the graded `LivenessLadder` (CBAR4-2) onto the panel
    /// Liveness: `.dead` (≥15s of no ticking) → `.stalled`; `.live`/`.syncing`
    /// (<15s) → `.ok`, so a momentary stall shows the last-known content, not the
    /// red banner. The 15s threshold is keyed to the 1s write cadence — NOT
    /// `refresh_interval_ms` (the ~90s refetch), which let a dead daemon read fresh
    /// for minutes before this fix.
    private static func staleness(of s: DaemonStatus, mtime: Date?) -> Liveness {
        let now = Date()
        let genAge = Theme.parseISO(s.generatedAt).map { now.timeIntervalSince($0) }
        let mtimeAge = mtime.map { now.timeIntervalSince($0) }
        switch LivenessLadder.freshness(generatedAtAge: genAge, statusMtimeAge: mtimeAge) {
        case .live, .syncing:
            return .ok
        case .dead:
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            let written = Theme.parseISO(s.generatedAt) ?? now
            return .stalled(since: f.string(from: written))
        }
    }

    /// Post a local notification for the events worth learning about while away
    /// (TECH-11): an UNATTENDED switch (last_switch.trigger != "user") that changed
    /// the active account, and a NEW auto-switch error. The first observed status
    /// only sets the baseline — no notification burst on launch. A user's own tap
    /// is not notified (they just performed it).
    private func maybeNotify(_ s: DaemonStatus) {
        defer {
            lastNotifiedActive = s.activeProfile
            lastNotifiedErrorAt = s.lastError?.at
            hasNotifyBaseline = true
        }
        guard hasNotifyBaseline else { return }

        if s.activeProfile != lastNotifiedActive,
           let now = s.activeProfile,
           s.lastSwitch?.trigger != "user" {
            let reason = s.lastSwitch?.trigger == "wrap_off" ? " (chain spent)" : ""
            Notifier.post(title: "clauth switched to \(now)", body: "Auto-switch\(reason).")
            // Rotation heartbeat (CBAR4-3): flash it in the panel too — but only when
            // there's no local switch in flight (that path shows its own confirm).
            if !switchInFlight { flashRotation(to: now) }
        }

        if let err = s.lastError, err.at != lastNotifiedErrorAt {
            Notifier.post(title: "clauth auto-switch issue", body: err.message)
        }
        // INT-2: codex-slot rotation (active_codex_profile changing) is deliberately
        // NOT notified for now — the daemon has no codex-specific last_switch trigger
        // to distinguish a user tap from an auto-switch, so we'd risk a spurious
        // "switched" toast on every codex adopt. Add a lastNotifiedActiveCodex baseline
        // here when the codex slot gets its own switch-provenance field.
    }

    /// The active CLAUDE profile (INT-2). Since codex arrived, `active` is ambiguous —
    /// a codex profile and a claude profile can BOTH be `active` (two independent
    /// slots). This is the claude slot specifically.
    var activeClaude: ProfileStatus? { status?.profiles.first { $0.active && !$0.isCodex } }

    /// The active CODEX profile (INT-2), or nil on codex-less installs. The codex
    /// slot's truth, independent of the claude slot above.
    var activeCodex: ProfileStatus? { status?.profiles.first { $0.active && $0.isCodex } }

    /// The active account for every EXISTING consumer (forecast, chain line, switch
    /// confirm, menu-bar %) — all claude-rotation machinery, so `active` points at the
    /// claude slot to preserve behavior. Codex-slot readers use `activeCodex`.
    var active: ProfileStatus? { activeClaude }

    /// Accounts in STABLE FILE ORDER — the CBAR-4 list never reorders (design §2:
    /// "rows never reorder; the terracotta ✓ badge moves"). Only the active badge
    /// and the inspection ring move, so the eye keeps its place.
    var listProfiles: [ProfileStatus] { status?.profiles ?? [] }

    /// Harness-scoped account lists (TABS-1) — each provider page lists only its
    /// own harness's profiles, in the same stable file order.
    func profiles(for harness: Harness) -> [ProfileStatus] {
        listProfiles.filter { $0.harnessKind == harness }
    }

    /// The harness's active slot as a full profile (TABS-1): `activeClaude` /
    /// `activeCodex` behind one switchable accessor for the tab bar + strips.
    func activeProfile(for harness: Harness) -> ProfileStatus? {
        harness == .codex ? activeCodex : activeClaude
    }

    // MARK: - Inspection (CBAR4-4 — browse freely, switch deliberately)

    /// The account the detail card is showing. `nil` ⇒ follow the active account.
    /// A single click INSPECTS (pure view state, zero daemon traffic); opening the
    /// panel resets inspection to the active account.
    @Published var inspectedName: String?

    /// The inspected profile — the explicit selection, else the CURRENT PAGE's
    /// active account, else that harness's first CHAIN member (design §3.1: reset
    /// to active, or the chain head when the active slot is null, e.g. wrap-off),
    /// else the page's first row. Tab-aware since TABS-1: the Codex page's detail
    /// card must never default to a claude profile it doesn't list (Overview keeps
    /// the claude resolution — it has no detail card, but the menu-bar machinery
    /// still reads claude truth through here-adjacent paths).
    var inspected: ProfileStatus? {
        if let name = inspectedName, let p = status?.profiles.first(where: { $0.name == name }) {
            return p
        }
        let harness = tab.harness ?? .claude
        if let slot = activeProfile(for: harness) { return slot }
        if let s = status, let head = s.chain(for: harness).first,
           let p = s.profiles.first(where: { $0.name == head }) {
            return p
        }
        return profiles(for: harness).first
    }

    func inspect(_ name: String) { inspectedName = name }

    /// Reset inspection to the active account (called when the panel opens).
    func resetInspection() { inspectedName = nil }

    /// True when `name` is the row the detail card is currently targeting.
    func isInspected(_ name: String) -> Bool { inspected?.name == name }

    // MARK: - Forecast (drives the status strip + detail chain line)

    /// The daemon's predicted next auto-switch target — the single choke point every
    /// "would switch to X" string resolves through. Prefers the daemon's OWN
    /// published forecast (clauth 81c00a2+): it is computed by the exact
    /// `fallback::next_target` walk the switch decision runs, so it cannot drift the
    /// way a client-side mirror silently did when upstream changed the walk
    /// semantics. Falls back to the local `ForecastEngine` mirror only for older
    /// daemons whose status.json lacks the `forecast` field. `now` is read here for
    /// the mirror's clock; the view refreshes on the poll/1s cadence.
    var forecast: ForecastEngine.Outcome {
        guard let s = status else { return .none }
        if let published = s.forecast { return published.outcome }
        return ForecastEngine.nextTarget(s, now: Date())
    }

    /// Non-empty chain with zero armed members, or an empty chain — auto-switch is
    /// idle (design §3.16). Drives the amber zero-armed strip + the label bolt.slash.
    var autoSwitchIdle: Bool {
        guard let s = status else { return false }
        let armed = s.profiles.contains { $0.fallback?.armed == true }
        return s.fallbackChain.isEmpty || !armed
    }

    /// Wrap-off ETA (design §3.15): the soonest a chain member's live window resets,
    /// so an all-off state can promise "auto-resumes when a window resets (≤ …)".
    var wrapOffResumeETA: String? {
        guard let s = status else { return nil }
        let now = Date()
        let resets: [Date] = s.fallbackChain
            .compactMap { name in s.profiles.first { $0.name == name } }
            .compactMap { $0.fiveHour?.resetsAt }
            .compactMap { Theme.parseISO($0) }
            .filter { $0 > now }
        guard let soonest = resets.min() else { return nil }
        return Theme.resetHintText(secondsRemaining: Int(soonest.timeIntervalSince(now)))
    }

    /// The forecast sentence for the status strip (design §2/§3.11), worded as a
    /// PREDICTION by the pure engine. nil when there's no active account to watch.
    var forecastSentence: String? {
        guard let active else { return nil }
        switch forecast {
        case .switchTo(let target):
            let at = active.fallback.map { " at \(Int($0.threshold))%" } ?? ""
            return "Watching \(active.name) — would switch to \(target)\(at)"
        case .off:
            return "Watching \(active.name) — would switch everything off when spent"
        case .none:
            return "Watching \(active.name) — no rotation target"
        }
    }

    /// The strip's second line under the forecast: "now 62% · live · updated 3s ago"
    /// (design §2 STATE 1). The now% is the active account's 5h; the freshness word
    /// comes off the same generated_at age the liveness ladder uses.
    var livenessStamp: String {
        var parts: [String] = []
        if let pct = active?.fiveHour?.utilizationPct { parts.append("now \(Int(pct.rounded()))%") }
        parts.append(freshnessWord)
        if let age = generatedAtAge { parts.append("updated \(Self.ago(Int(age)))") }
        return parts.joined(separator: " · ")
    }

    /// "live" / "syncing…" / "frozen" from the generated_at age (the liveness ladder).
    var freshnessWord: String {
        switch generatedAtAge.map({ LivenessLadder.freshness(ageSeconds: $0) }) ?? .dead {
        case .live: return "live"
        case .syncing: return "syncing…"
        case .dead: return "frozen"
        }
    }

    /// Coarse frozen-age for the dead banner ("4m ago"), from generated_at.
    var frozenAge: String { generatedAtAge.map { Self.ago(Int($0)) } ?? "a while ago" }

    /// Short age WITHOUT " ago" ("3s"/"2m"/"1h") for the live detail "Fresh · 3s"
    /// stamp (design §4). We're only asked for this in the live panel, so it never
    /// renders the self-contradictory "Fresh · frozen".
    var freshAge: String {
        guard let age = generatedAtAge else { return "now" }
        let s = Int(max(0, age))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }

    private var generatedAtAge: Double? {
        status.flatMap { Theme.parseISO($0.generatedAt) }.map { Date().timeIntervalSince($0) }
    }

    /// Coarse "N{s,m,h,d} ago" from a positive second count.
    static func ago(_ secs: Int) -> String {
        if secs < 60 { return "\(max(0, secs))s ago" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86_400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86_400)d ago"
    }

    /// Best-effort spawn of `clauth daemon` for the dead-banner recovery button
    /// (design §3.13). The durable autostart is the operator's LaunchAgent (which
    /// also re-parents/supervises it); this just relights it in-session. Surfaces a
    /// loud hint if the binary can't be found (so the button isn't a silent no-op).
    func startDaemon() {
        Task { [weak self] in
            let launched = await Task.detached { DaemonClient.startDaemon() }.value
            guard let self, !launched else { return }
            self.showError("Couldn't find the clauth binary — run `clauth daemon` yourself.")
        }
    }

    /// The detail-card chain-membership line for an inspected account (design §2):
    /// "⚡ 1st in chain · watched now — would rotate to cl-ax at 95%…" / "⚑ 2nd in
    /// chain · last resort — parks here when nothing else has headroom". nil for a
    /// non-chain account. Keyed on the explicit `last_resort` flag (clauth
    /// set_last_resort), NOT threshold-100 — the two are independent now.
    ///
    /// TABS-1: the ordinal comes from `fallback.position`, which the daemon computes
    /// against the profile's OWN harness's chain — so codex members get real
    /// ordinals too. `position` is 1-BASED on the wire (status_json.rs emits
    /// `pos + 1`), so it feeds `ordinal` directly, NO `+ 1`. The "would rotate to"
    /// forecast clause stays claude-only: the daemon publishes no codex forecast,
    /// and a client-side mirror is the drift the published forecast exists to kill.
    func chainLine(for p: ProfileStatus) -> String? {
        guard let fb = p.fallback else { return nil }
        let ordinal = Self.ordinal(fb.position)
        let threshold = fb.threshold
        if fb.lastResort {
            return "\(ordinal) in chain · last resort — parks here when nothing else has headroom"
        }
        if p.active, !p.isCodex, case .switchTo(let target) = forecast {
            return "\(ordinal) in chain · watched now — would rotate to \(target) at \(Int(threshold))% of the 5h window"
        }
        return "\(ordinal) in chain · leaves at \(Int(threshold))% of the 5h window"
    }

    /// 1 → "1st", 2 → "2nd", 3 → "3rd", 11–13 → "…th", etc.
    nonisolated static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 100, n % 10) {
        case (11, _), (12, _), (13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    /// True when the daemon is demonstrably alive — a fresh status read AND the
    /// control socket present. Configure controls (which need a running daemon) are
    /// disabled otherwise (TECH-11) — a silent no-op is worse than a disabled
    /// control. Gating on `liveness == .ok` (not just the socket FILE) means a
    /// crashed daemon that left a stale socket still disables the controls, and the
    /// gate is reactive to the poll (M4/TECH-11).
    var daemonReachable: Bool { liveness == .ok && DaemonClient.daemonSocketExists }

    /// A soft version-skew signal (TECH-11): the daemon's clauth version when it
    /// differs from what this ccsbar build targets, else nil.
    var versionSkew: String? {
        guard let v = status?.clauthVersion, v != Self.expectedClauthVersion else { return nil }
        return v
    }

    // MARK: - Shared effect utilities (used by the Switch/Actions extension files)

    /// A main-actor timer that survives cancellation checks — the switch machine's
    /// arm/pending/dismiss deadlines. Passes `self` in so call sites stay terse.
    func after(_ seconds: Double, _ action: @escaping @MainActor (StatusModel) -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            action(self)
        }
    }

    /// Flash a transient "rotated to X" note for ~8s (CBAR4-3 rotation heartbeat).
    private func flashRotation(to name: String) {
        rotationFlash = name
        rotationClearTask?.cancel()
        rotationClearTask = after(8) { $0.rotationFlash = nil }
    }

    /// Publish a transient error banner, auto-cleared after ~6s.
    func showError(_ message: String) {
        lastCommandError = message
        errorClearTask?.cancel()
        errorClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, !Task.isCancelled else { return }
            self.lastCommandError = nil
        }
    }
}

/// The two custom-threshold fields the Configure disclosure can inline-edit
/// (§7): a member's 5h leave-at percent, or the chain-wide weekly line.
enum ThresholdEditTarget: Equatable {
    case fiveHour(String)
    case weekly
}
