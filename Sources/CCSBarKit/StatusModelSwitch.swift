import SwiftUI

/// The switch-machine EFFECTS half of `StatusModel` (TABS-1 decomposition — the
/// pure transitions live in `SwitchMachine`; this file owns dispatch, timers, and
/// status.json observation). Split from StatusModel.swift, which had grown past
/// the repo's file-size gate; stored properties stay in the class declaration.
extension StatusModel {
    /// Begin a switch. Feeds the state machine a request; the effects (arm timer,
    /// off-main dispatch, status.json observation, timeouts) follow the phase in
    /// `enter(_:)`. Harness-aware (TABS-1): the target's own harness decides which
    /// active slot the confirm ladder observes and which strip shows the lifecycle.
    func switchTo(_ name: String) {
        // Resolve the target's harness. An unknown name (shouldn't happen from the
        // UI — rows come from listProfiles) defaults to claude and lets the daemon's
        // authoritative rejection surface loudly, never a silent local drop.
        switchHarness = listProfiles.first { $0.name == name }?.harnessKind ?? .claude
        // Guard the CURRENT account's live session (design §3.7): if it has one, a
        // Keychain rewrite would strand it, so the machine arms for a confirm.
        // CLAUDE ONLY: status.json's has_live_session is computed by the claude-only
        // session counter (always false for codex), and `clauth start` codex
        // sessions run isolated CODEX_HOMEs a switch of the shared ~/.codex login
        // can't strand — there is nothing for a codex confirm to protect, so a
        // codex switch goes straight to pending.
        let live = switchHarness == .claude && (activeClaude?.hasLiveSession ?? false)
        dispatch(.requestSwitch(target: name, currentHasLiveSession: live))
    }

    /// User confirmed the live-session arm (CBAR4-4 wires the button here).
    func confirmArmedSwitch() { dispatch(.confirmArm) }
    /// Dismiss a transient confirmed/failed banner (or cancel an arm).
    func dismissSwitch() { dispatch(.cancel) }

    /// Advance the switch machine and run the entry effects for a NEW phase only.
    func dispatch(_ event: SwitchMachine.Event) {
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
            pendingSince = Date()
            armPendingDeadline(target, in: 6)
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

    /// Arm the pending deadline. When it fires, take one last look before
    /// declaring failure — a switch that landed after the final observe read
    /// still confirms rather than false-failing. And when the daemon's own
    /// queue STILL holds this target (it defers a mid-fetch target and retries
    /// itself — the daemon log shows "deferring switch to 'x': target is
    /// mid-fetch"), keep waiting on a 2s re-check cadence up to the machine's
    /// 30s hard ceiling: the common case is a brand-new account whose first
    /// usage poll outlives a blind 6s timeout.
    private func armPendingDeadline(_ target: String, in seconds: Double) {
        pendingTimeoutTask?.cancel()
        pendingTimeoutTask = after(seconds) { model in
            model.reload()
            // Observe the TARGET harness's active slot (TABS-1): a codex switch
            // lands in active_codex_profile — watching active_profile would never
            // confirm it and false-fail every codex switch at the timeout.
            model.dispatch(.observedActive(model.status?.activeName(for: model.switchHarness)))
            guard case .pending = model.switchPhase else { return } // confirmed above
            let elapsed = Date().timeIntervalSince(model.pendingSince ?? .distantPast)
            if SwitchMachine.shouldExtendPending(
                daemonPending: model.status?.pendingSwitch,
                target: target,
                elapsed: elapsed
            ) {
                model.armPendingDeadline(target, in: 2)
                return
            }
            model.dispatch(.pendingTimedOut)
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
                // Same harness routing as the deadline check: read the slot the
                // target actually lands in.
                self.dispatch(.observedActive(self.status?.activeName(for: self.switchHarness)))
                if case .pending = self.switchPhase {} else { return }
            }
        }
    }

    func cancelSwitchTimers(keepDismiss: Bool = false) {
        switchDispatchTask?.cancel()
        switchObserveTask?.cancel()
        armTimeoutTask?.cancel()
        pendingTimeoutTask?.cancel()
        if !keepDismiss { switchDismissTask?.cancel() }
    }
}
