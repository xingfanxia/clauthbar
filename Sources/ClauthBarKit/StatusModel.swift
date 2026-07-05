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
    }

    @Published private(set) var status: DaemonStatus?
    @Published private(set) var liveness: Liveness = .down
    /// A transient, human-readable error from the last command (TECH-11) — a daemon
    /// rejection or an unreachable daemon. Rendered as a banner; auto-cleared after
    /// a few seconds and on the next successful command ('errors must be loud').
    @Published private(set) var lastCommandError: String?
    /// True while a switch's socket command is in flight (M5/TECH-11). The tiles
    /// disable on it so a impatient double-tap can't fire two concurrent switches
    /// (two Keychain rewrites) — the settle ladder only hides latency, it doesn't
    /// prevent the second tap. Cleared once the outcome is known (~≤2s), before the
    /// settle ladder finishes, so re-selecting a different account stays responsive.
    @Published private(set) var switchInFlight = false
    @Published var showConfig = false

    /// The clauth version this clauthbar build targets. A daemon reporting a
    /// different `clauth_version` raises a SOFT skew badge (informational — the
    /// schema gate in TECH-4 handles hard read-format incompatibility). Bump this
    /// when clauthbar is validated against a new clauth release.
    static let expectedClauthVersion = "0.7.1"

    private var timer: Timer?
    private var lastMtime: Date?
    private var settleTask: Task<Void, Never>?
    private var errorClearTask: Task<Void, Never>?

    // Notification baseline (TECH-11) — set on the first observed status so the
    // initial load never fires a burst of "switched to X" notifications.
    private var hasNotifyBaseline = false
    private var lastNotifiedActive: String?
    private var lastNotifiedErrorAt: String?

    init() {
        Notifier.requestAuthorizationIfNeeded()
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        // Let the OS coalesce the 4s poll for power (TECH-14 #31) — a rebuildable
        // status read has no need to be punctual to the millisecond.
        timer?.tolerance = 1.0
    }

    /// Preview/snapshot init: inject a fixed status + liveness, no polling.
    init(preview: DaemonStatus?, liveness: Liveness = .ok) {
        self.status = preview
        self.liveness = liveness
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
        }

        if let err = s.lastError, err.at != lastNotifiedErrorAt {
            Notifier.post(title: "clauth auto-switch issue", body: err.message)
        }
    }

    var active: ProfileStatus? { status?.profiles.first { $0.active } }

    /// Active pinned first, then file order — the switcher's tile order.
    var orderedProfiles: [ProfileStatus] {
        (status?.profiles ?? []).sorted { a, b in a.active && !b.active }
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

    func switchTo(_ name: String) {
        guard !switchInFlight else { return } // ignore double-taps while one is in flight
        switchInFlight = true
        Task { [weak self] in
            let outcome = await Task.detached { DaemonClient.switchTo(name) }.value
            guard let self else { return }
            self.switchInFlight = false
            self.handle(outcome, expecting: { $0.activeProfile == name })
        }
    }
    func fallbackAdd(_ name: String) { run { DaemonClient.fallbackAdd(name) } }
    func fallbackRemove(_ name: String) { run { DaemonClient.fallbackRemove(name) } }
    func fallbackMove(_ name: String, up: Bool) { run { DaemonClient.fallbackMove(name, up: up) } }
    func setThreshold(_ name: String, _ value: Int) { run { DaemonClient.setThreshold(name, value) } }
    func setWrapOff(_ on: Bool) { run { DaemonClient.setWrapOff(on) } }
    func refresh() { run { DaemonClient.refresh(nil) } }

    /// Run a command's blocking socket I/O OFF the main actor (TECH-10 #25 — a
    /// switch parks the socket ~2s while the daemon holds its config lock across a
    /// Keychain rewrite; on @MainActor that's the beach-ball), then on the main
    /// actor surface any error LOUDLY and, on success, run the verification ladder
    /// so the panel reflects the change (TECH-11). Call sites stay synchronous.
    private func run(
        _ work: @escaping @Sendable () -> CommandOutcome,
        expecting predicate: (@Sendable (DaemonStatus) -> Bool)? = nil
    ) {
        Task { [weak self] in
            let outcome = await Task.detached(operation: work).value
            guard let self else { return }
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

    /// Verification ladder (TECH-11): the daemon applies queued edits on its next
    /// ~1s tick, but a switch also does a Keychain rewrite, so a single fixed re-read
    /// routinely lands before the change is visible (users then double-tap → dup
    /// switches). Re-read at 0.6/1.2/2.4/4.8s until `generated_at` advances AND the
    /// expected effect holds, then stop early. Cancels any in-flight ladder.
    private func settle(expecting predicate: (@Sendable (DaemonStatus) -> Bool)? = nil) {
        let baseline = status?.generatedAt
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            for delay in [0.6, 1.2, 2.4, 4.8] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled else { return }
                self.reload()
                if let s = self.status, s.generatedAt != baseline, predicate?(s) ?? true {
                    return // the change landed — stop re-reading
                }
            }
        }
    }
}
