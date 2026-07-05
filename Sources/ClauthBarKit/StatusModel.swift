import SwiftUI

/// Polls `~/.clauth/status.json` on a timer and publishes it to the panel + the
/// menu-bar label. Also the one place that fires switch/config commands at the
/// daemon (via `DaemonClient`) and schedules a quick re-read so the UI reflects
/// the change once the daemon's next tick lands it (~1s).
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
    /// A transient, human-readable error from the last command (TECH-11) — a daemon
    /// rejection or an unreachable daemon. Rendered as a banner; auto-cleared after
    /// a few seconds and on the next successful command ('errors must be loud').
    @Published private(set) var lastCommandError: String?
    /// The user-initiated switch lifecycle (CBAR4-3) — drives the panel's
    /// arm-confirm / pending / confirmed / failed states. The pure transitions live
    /// in `SwitchMachine`; this model owns the effects (dispatch, timers, observe).
    @Published private(set) var switchPhase: SwitchMachine.Phase = .idle
    /// A transient "rotated to X" flash (8s) when the daemon auto-switched the active
    /// account with no local pending switch (CBAR4-3 rotation heartbeat) — the hero
    /// feature's only in-panel proof it fired.
    @Published private(set) var rotationFlash: String?
    @Published var showConfig = false
    /// The chain member awaiting the inline removal confirm (CBAR4-5 §7 — removing
    /// an ARMED member requires an explicit "remove anyway?"). `nil` ⇒ no confirm
    /// pending. Copy comes from `ChainEdit.removalConsequence`.
    @Published var pendingRemoval: String?
    /// Count of config socket round-trips in flight (CBAR4-5 §7 pending shimmer) —
    /// the disclosure shows an honest "Applying…" while > 0. Cleared as each
    /// command's reply lands (the settle ladder then updates the view).
    @Published private(set) var configInFlight = 0

    /// A switch is in flight (arming or pending) — tiles disable to block a second
    /// concurrent switch (M5/TECH-11), now derived from the phase.
    var switchInFlight: Bool { switchPhase.isBusy }

    /// A config command's socket round-trip is in flight — drives the pending
    /// shimmer (§7).
    var configBusy: Bool { configInFlight > 0 }

    /// The clauth version this clauthbar build targets. A daemon reporting a
    /// different `clauth_version` raises a SOFT skew badge (informational — the
    /// schema gate in TECH-4 handles hard read-format incompatibility). Bump this
    /// when clauthbar is validated against a new clauth release.
    static let expectedClauthVersion = "0.7.1"

    private var timer: Timer?
    private var lastMtime: Date?
    private var settleTask: Task<Void, Never>?
    private var errorClearTask: Task<Void, Never>?
    // Switch-machine effect tasks (CBAR4-3).
    private var switchDispatchTask: Task<Void, Never>?
    private var switchObserveTask: Task<Void, Never>?
    private var armTimeoutTask: Task<Void, Never>?
    private var pendingTimeoutTask: Task<Void, Never>?
    private var switchDismissTask: Task<Void, Never>?
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
        Notifier.requestAuthorizationIfNeeded()
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        // Let the OS coalesce the 4s poll for power (TECH-14 #31) — a rebuildable
        // status read has no need to be punctual to the millisecond.
        timer?.tolerance = 1.0
    }

    /// Preview/snapshot init: inject a fixed status + liveness (+ optional inspection
    /// and switch phase for the canonical-state snapshots), no polling.
    init(preview: DaemonStatus?, liveness: Liveness = .ok,
         inspected: String? = nil, phase: SwitchMachine.Phase = .idle) {
        self.isPreview = true
        self.status = preview
        self.liveness = liveness
        self.inspectedName = inspected
        self.switchPhase = phase
    }

    /// The active account is only trustworthy when live — the menu-bar glyph dims
    /// otherwise so a frozen % never reads as current.
    var isHealthy: Bool { liveness == .ok }

    func reload() {
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
    }

    var active: ProfileStatus? { status?.profiles.first { $0.active } }

    /// Accounts in STABLE FILE ORDER — the CBAR-4 list never reorders (design §2:
    /// "rows never reorder; the terracotta ✓ badge moves"). Only the active badge
    /// and the inspection ring move, so the eye keeps its place.
    var listProfiles: [ProfileStatus] { status?.profiles ?? [] }

    // MARK: - Inspection (CBAR4-4 — browse freely, switch deliberately)

    /// The account the detail card is showing. `nil` ⇒ follow the active account.
    /// A single click INSPECTS (pure view state, zero daemon traffic); opening the
    /// panel resets inspection to the active account.
    @Published var inspectedName: String?

    /// The inspected profile — the explicit selection, else the active account, else
    /// the first CHAIN member (design §3.1: reset to active, or the chain head when
    /// active_profile is null, e.g. wrap-off), else the first row.
    var inspected: ProfileStatus? {
        if let name = inspectedName, let p = status?.profiles.first(where: { $0.name == name }) {
            return p
        }
        if let active { return active }
        if let s = status, let head = s.fallbackChain.first,
           let p = s.profiles.first(where: { $0.name == head }) {
            return p
        }
        return status?.profiles.first
    }

    func inspect(_ name: String) { inspectedName = name }

    /// Reset inspection to the active account (called when the panel opens).
    func resetInspection() { inspectedName = nil }

    /// True when `name` is the row the detail card is currently targeting.
    func isInspected(_ name: String) -> Bool { inspected?.name == name }

    // MARK: - Forecast (drives the status strip + detail chain line)

    /// The daemon's predicted next auto-switch target (pure `ForecastEngine` mirror
    /// of fallback.rs). `now` is read here; the view refreshes on the poll/1s clock.
    var forecast: ForecastEngine.Outcome {
        guard let s = status else { return .none }
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
    /// chain · last resort — parks here even at 100%". nil for a non-chain account.
    func chainLine(for p: ProfileStatus) -> String? {
        guard let s = status, let idx = s.fallbackChain.firstIndex(of: p.name) else { return nil }
        let ordinal = Self.ordinal(idx + 1)
        let threshold = p.fallback?.threshold ?? 95
        if threshold >= 100 {
            return "\(ordinal) in chain · last resort — chain parks here even at 100%"
        }
        if p.active, case .switchTo(let target) = forecast {
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
    /// differs from what this clauthbar build targets, else nil.
    var versionSkew: String? {
        guard let v = status?.clauthVersion, v != Self.expectedClauthVersion else { return nil }
        return v
    }

    // MARK: - Commands (fire off-main, surface the outcome, verify the effect)

    /// Begin a switch. Feeds the state machine a request; the effects (arm timer,
    /// off-main dispatch, status.json observation, timeouts) follow the phase in
    /// `enter(_:)`. The live-session arm-confirm (CBAR4-3 machine, CBAR4-4 UI) is
    /// staged: until the confirm button lands (CBAR4-4) we go straight to pending.
    func switchTo(_ name: String) {
        // Guard the CURRENT account's live session (design §3.7): if it has one, a
        // Keychain rewrite would strand it, so the machine arms for a confirm.
        let live = active?.hasLiveSession ?? false
        dispatch(.requestSwitch(target: name, currentHasLiveSession: live))
    }

    /// User confirmed the live-session arm (CBAR4-4 wires the button here).
    func confirmArmedSwitch() { dispatch(.confirmArm) }
    /// Dismiss a transient confirmed/failed banner (or cancel an arm).
    func dismissSwitch() { dispatch(.cancel) }

    /// Advance the switch machine and run the entry effects for a NEW phase only.
    private func dispatch(_ event: SwitchMachine.Event) {
        let before = switchPhase
        let after = SwitchMachine.reduce(before, event)
        guard after != before else { return }
        switchPhase = after
        enter(after)
    }

    /// Effects on entering a switch phase (the impure half of the machine).
    private func enter(_ phase: SwitchMachine.Phase) {
        switch phase {
        case .idle:
            cancelSwitchTimers()
        case .arming:
            armTimeoutTask?.cancel()
            armTimeoutTask = after(5) { $0.dispatch(.armTimedOut) }
        case .pending(let target):
            // (A stale dismiss timer from a prior confirmed/failed may still be
            // pending here; not cancelled deliberately — a `.dismiss` in `pending`
            // reduces to a no-op, so it can't clear a later banner.)
            armTimeoutTask?.cancel()
            fireSwitch(target)
            observeSwitch(target)
            pendingTimeoutTask?.cancel()
            // At the 6s deadline, take ONE last look before declaring failure — a
            // switch that landed after the final observe read (or during a contended
            // Keychain rewrite) still confirms rather than false-failing.
            pendingTimeoutTask = after(6) { model in
                model.reload()
                model.dispatch(.observedActive(model.status?.activeProfile))
                model.dispatch(.pendingTimedOut) // no-op if the line above confirmed
            }
        case .confirmed:
            cancelSwitchTimers(keepDismiss: true)
            lastCommandError = nil
            errorClearTask?.cancel()
            switchDismissTask?.cancel()
            switchDismissTask = after(2) { $0.dispatch(.dismiss) }
        case .failed(let reason):
            cancelSwitchTimers(keepDismiss: true)
            showError(reason) // reuse the TECH-11 banner
            switchDismissTask?.cancel()
            switchDismissTask = after(6) { $0.dispatch(.dismiss) }
        }
    }

    /// Fire the switch command OFF the main actor (TECH-10 #25 beach-ball), then feed
    /// the classified dispatch back into the machine.
    private func fireSwitch(_ target: String) {
        switchDispatchTask?.cancel()
        switchDispatchTask = Task { [weak self] in
            let dispatch = await Task.detached { DaemonClient.switchTo(target) }.value
            guard let self, !Task.isCancelled else { return }
            self.dispatch(.dispatched(dispatch))
        }
    }

    /// Re-read status.json on a backoff ladder, feeding each observed `active_profile`
    /// to the machine so a socket-accepted switch confirms as soon as the daemon's
    /// tick lands it. The values are PER-ITERATION sleeps; reads land at cumulative
    /// t ≈ 0.5/1.2/2.2/3.5/5.1s — all inside the 6s pending deadline, so the switch
    /// is observed here before the timeout's final check. Stops once it leaves pending.
    private func observeSwitch(_ target: String) {
        switchObserveTask?.cancel()
        switchObserveTask = Task { [weak self] in
            for sleep in [0.5, 0.7, 1.0, 1.3, 1.6] {
                try? await Task.sleep(for: .seconds(sleep))
                guard let self, !Task.isCancelled else { return }
                self.reload()
                self.dispatch(.observedActive(self.status?.activeProfile))
                if case .pending = self.switchPhase {} else { return }
            }
        }
    }

    /// A main-actor timer that survives cancellation checks — the switch machine's
    /// arm/pending/dismiss deadlines. Passes `self` in so call sites stay terse.
    private func after(_ seconds: Double, _ action: @escaping @MainActor (StatusModel) -> Void) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            action(self)
        }
    }

    private func cancelSwitchTimers(keepDismiss: Bool = false) {
        switchDispatchTask?.cancel()
        switchObserveTask?.cancel()
        armTimeoutTask?.cancel()
        pendingTimeoutTask?.cancel()
        if !keepDismiss { switchDismissTask?.cancel() }
    }

    func fallbackAdd(_ name: String) { run { DaemonClient.fallbackAdd(name) } }
    func fallbackRemove(_ name: String) { run { DaemonClient.fallbackRemove(name) } }
    func fallbackMove(_ name: String, up: Bool) { run { DaemonClient.fallbackMove(name, up: up) } }
    func setThreshold(_ name: String, _ value: Int) { run { DaemonClient.setThreshold(name, value) } }
    func setWrapOff(_ on: Bool) { run { DaemonClient.setWrapOff(on) } }
    // Refreshes are usage re-fetches, not config edits — no "Applying…" shimmer.
    // (Explicit `work:`-position arg, not a trailing closure, so it can't bind to
    // the optional `expecting` closure param instead.)
    func refresh() { run({ DaemonClient.refresh(nil) }, shimmer: false) }
    /// Force a usage re-fetch for one account (context-menu "Refresh <name>", §7).
    func refresh(_ name: String) { run({ DaemonClient.refresh(name) }, shimmer: false) }

    // MARK: - Chain removal with the armed-member confirm (CBAR4-5 §7)

    /// Remove `name` from the chain, but if it's an ARMED member first raise the
    /// inline confirm (a removal that stops auto-switch must be deliberate). Both the
    /// context menu and the disclosure route removals through here.
    func requestRemove(_ name: String) {
        guard let s = status, ChainEdit.removalConsequence(of: name, in: s) != nil else {
            fallbackRemove(name)
            return
        }
        pendingRemoval = name
    }

    /// The confirm copy for the pending removal, or nil when none is pending.
    var pendingRemovalPrompt: String? {
        guard let name = pendingRemoval, let s = status else { return nil }
        return ChainEdit.removalConsequence(of: name, in: s)?.prompt
    }

    func confirmRemoval() {
        guard let name = pendingRemoval else { return }
        pendingRemoval = nil
        fallbackRemove(name)
    }

    func cancelRemoval() { pendingRemoval = nil }

    /// Run a command's blocking socket I/O OFF the main actor (TECH-10 #25 — a
    /// switch parks the socket ~2s while the daemon holds its config lock across a
    /// Keychain rewrite; on @MainActor that's the beach-ball), then on the main
    /// actor surface any error LOUDLY and, on success, run the verification ladder
    /// so the panel reflects the change (TECH-11). Call sites stay synchronous.
    private func run(
        _ work: @escaping @Sendable () -> CommandOutcome,
        shimmer: Bool = true,
        expecting predicate: (@Sendable (DaemonStatus) -> Bool)? = nil
    ) {
        if shimmer { configInFlight += 1 }
        Task { [weak self] in
            let outcome = await Task.detached(operation: work).value
            guard let self else { return }
            if shimmer { self.configInFlight = max(0, self.configInFlight - 1) }
            self.handle(outcome, expecting: predicate)
        }
    }

    /// On the main actor, react to a command's outcome (shared by `run` and the
    /// bespoke `switchTo` path): clear the error + run the settle ladder on success,
    /// surface the error banner LOUDLY on a rejection or an unreachable daemon.
    private func handle(_ outcome: CommandOutcome, expecting predicate: (@Sendable (DaemonStatus) -> Bool)?) {
        switch outcome {
        case .ok:
            lastCommandError = nil
            errorClearTask?.cancel()
            settle(expecting: predicate)
        case .daemonError(_, let message):
            showError(message)
        case .unreachable:
            showError("clauth daemon not reachable — is it running?")
        }
    }

    /// Flash a transient "rotated to X" note for ~8s (CBAR4-3 rotation heartbeat).
    private func flashRotation(to name: String) {
        rotationFlash = name
        rotationClearTask?.cancel()
        rotationClearTask = after(8) { $0.rotationFlash = nil }
    }

    /// Publish a transient error banner, auto-cleared after ~6s.
    private func showError(_ message: String) {
        lastCommandError = message
        errorClearTask?.cancel()
        errorClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, !Task.isCancelled else { return }
            self.lastCommandError = nil
        }
    }

    /// Verification ladder for CONFIG commands (TECH-11): the daemon applies queued
    /// edits on its next ~1s tick, so a single fixed re-read routinely lands before
    /// the change is visible. Re-read on a backoff (PER-ITERATION sleeps; cumulative
    /// t ≈ 0.6/1.8/4.2/9.0s) until `generated_at` advances AND the expected effect
    /// holds, then stop early. Unlike the switch ladder this never declares failure,
    /// so the longer tail is fine. Cancels any in-flight ladder.
    private func settle(expecting predicate: (@Sendable (DaemonStatus) -> Bool)? = nil) {
        let baseline = status?.generatedAt
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            for sleep in [0.6, 1.2, 2.4, 4.8] {
                try? await Task.sleep(for: .seconds(sleep))
                guard let self, !Task.isCancelled else { return }
                self.reload()
                if let s = self.status, s.generatedAt != baseline, predicate?(s) ?? true {
                    return // the change landed — stop re-reading
                }
            }
        }
    }
}
