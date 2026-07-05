import Foundation

/// The switch lifecycle as a PURE reducer (CBAR4-3, design §2 STATE 3). Kept
/// side-effect-free so every path — arm-confirm, instant refusal, accepted-then-
/// dropped timeout, socket-observed confirm, CLI-exit confirm — is unit-tested
/// without a live daemon; `StatusModel` owns the effects (fire the command, arm
/// the 5s/6s timers, re-read status.json, auto-dismiss the transient).
enum SwitchMachine {
    /// Where a user-initiated switch is in its lifecycle.
    enum Phase: Equatable, Sendable {
        case idle
        /// Awaiting the user's confirm because the CURRENT account has a live session
        /// (a Keychain rewrite would strand it — guard the asset the op destroys).
        case arming(target: String)
        /// Command accepted by the daemon; awaiting its next tick to LAND the switch
        /// (confirmed by observing `active_profile`, or the 6s accepted-then-dropped
        /// timeout).
        case pending(target: String)
        /// The switch landed. `viaCLI` ⇒ the daemon was dead and `clauth` did it, so
        /// auto-switch stays inactive until the daemon starts (design §8 label).
        case confirmed(target: String, viaCLI: Bool)
        /// Refused / unreachable / timed out — surfaced loudly, then auto-dismissed.
        case failed(reason: String)

        /// A switch is busy (blocks a second tap) while arming or pending.
        var isBusy: Bool {
            switch self {
            case .arming, .pending: return true
            case .idle, .confirmed, .failed: return false
            }
        }

        /// The target of an in-flight switch (arming/pending), else nil.
        var inFlightTarget: String? {
            switch self {
            case .arming(let t), .pending(let t): return t
            default: return nil
            }
        }
    }

    /// Everything that can move the machine.
    enum Event: Equatable, Sendable {
        case requestSwitch(target: String, currentHasLiveSession: Bool)
        case confirmArm                                  // user confirmed the live-session arm
        case cancel                                      // user dismissed / Esc
        case dispatched(DaemonClient.SwitchDispatch)     // the command result
        case observedActive(String?)                     // a status.json read landed
        case armTimedOut                                 // 5s in arming with no confirm
        case pendingTimedOut                             // 6s in pending with no landing
        case dismiss                                     // clear a transient confirmed/failed
    }

    static func reduce(_ phase: Phase, _ event: Event) -> Phase {
        switch event {
        case .requestSwitch(let target, let live):
            // Never interrupt an in-flight (pending) switch; from idle/arming/
            // confirmed/failed a new request (re)starts the flow.
            if case .pending = phase { return phase }
            return live ? .arming(target: target) : .pending(target: target)

        case .confirmArm:
            if case .arming(let t) = phase { return .pending(target: t) }
            return phase

        case .cancel:
            return .idle

        case .dispatched(let dispatch):
            guard case .pending = phase else { return phase }
            switch dispatch {
            case .accepted:
                return phase // stay pending — await observedActive / timeout
            case .confirmedByCLI:
                if case .pending(let t) = phase { return .confirmed(target: t, viaCLI: true) }
                return phase
            case .refused(_, let message):
                return .failed(reason: message)
            case .unreachable:
                return .failed(reason: "clauth daemon not reachable — is it running?")
            }

        case .observedActive(let active):
            if case .pending(let t) = phase, active == t {
                return .confirmed(target: t, viaCLI: false)
            }
            return phase

        case .armTimedOut:
            if case .arming = phase { return .idle }
            return phase

        case .pendingTimedOut:
            if case .pending = phase {
                return .failed(reason: "the switch didn’t take — the daemon may be busy")
            }
            return phase

        case .dismiss:
            switch phase {
            case .confirmed, .failed: return .idle
            default: return phase
            }
        }
    }
}
