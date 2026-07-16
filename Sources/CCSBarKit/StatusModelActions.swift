import SwiftUI

/// How a `clauth login` spawn acquires the credential (TABS-1). The distinction is
/// user-facing: a browser flow needs the user to go finish a sign-in, a capture is
/// an instant no-browser copy of the login codex already holds — the in-flight
/// banner must not send the user hunting for a browser window that never opened.
enum LoginMode: Equatable, Sendable {
    /// Browser OAuth/PKCE sign-in (claude always; codex `--codex --browser`).
    case browser
    /// Codex-only: capture the live `~/.codex/auth.json` verbatim (`--codex`).
    case capture
}

/// One in-flight `clauth login` spawn: which profile, acquired how. Single-flight
/// across ALL login surfaces (reauth + both add flows) — one login at a time.
struct LoginFlight: Equatable, Sendable {
    let name: String
    let mode: LoginMode
}

/// The command/action half of `StatusModel` (TABS-1 decomposition): config edits,
/// refreshes, login (reauth + add-account), rename, chain removal, and the
/// run/handle/settle plumbing they share. Stored properties stay in the class
/// declaration; this file is same-type extensions only.
extension StatusModel {
    // Each config command carries a predicate for its ACTUAL effect so the settle
    // ladder stops re-reading only once the change has landed — not on the next
    // unrelated ~1s status write (which would drop detection onto the slow 4s poll).
    // TABS-1: membership predicates check BOTH chains — the daemon routes a codex
    // profile's edit into `codex_fallback_chain`, and chains never share a name, so
    // the union is exact for either harness.
    func fallbackAdd(_ name: String) {
        run({ DaemonClient.fallbackAdd(name) },
            expecting: { $0.fallbackChain.contains(name) || $0.codexFallbackChain.contains(name) })
    }
    func fallbackRemove(_ name: String) {
        run({ DaemonClient.fallbackRemove(name) },
            expecting: { !$0.fallbackChain.contains(name) && !$0.codexFallbackChain.contains(name) })
    }
    func fallbackMove(_ name: String, up: Bool) {
        let baseline = status?.fallbackChain ?? []
        let codexBaseline = status?.codexFallbackChain ?? []
        run({ DaemonClient.fallbackMove(name, up: up) },
            expecting: { $0.fallbackChain != baseline || $0.codexFallbackChain != codexBaseline })
    }
    func setThreshold(_ name: String, _ value: Int) {
        run({ DaemonClient.setThreshold(name, value) },
            expecting: { $0.profiles.first { $0.name == name }?.fallback?.threshold == Double(value) })
    }
    /// Toggle a chain member's exclusive last-resort flag (clauth `set_last_resort`).
    /// Threshold-independent — a member can leave at 80% and still be the last resort.
    /// Against an OLD daemon that lacks the socket command the reply is `ok:false`
    /// ("unknown cmd"), which surfaces as a loud error banner like any rejected edit.
    func setLastResort(_ name: String, _ on: Bool) {
        run({ DaemonClient.setLastResort(name, on) },
            expecting: { $0.profiles.first { $0.name == name }?.fallback?.lastResort == on })
    }
    func setWrapOff(_ on: Bool) {
        run({ DaemonClient.setWrapOff(on) }, expecting: { $0.wrapOff == on })
    }
    /// Set the chain-wide weekly (7d) exhaustion line (clauth
    /// `set_weekly_threshold`). Same old-daemon contract as `setLastResort`:
    /// an unknown cmd surfaces as a loud error banner, never a silent no-op.
    func setWeeklyThreshold(_ value: Double) {
        run({ DaemonClient.setWeeklyThreshold(value) },
            expecting: { ($0.weeklySwitchThreshold ?? ChainEdit.defaultWeeklyLine) == value })
    }

    /// Open the inline custom-threshold editor, seeded with the current value.
    /// Also expands the Configure disclosure — the field lives there, so a
    /// context-menu "Custom…" lands the user in front of it.
    func beginThresholdEdit(_ target: ThresholdEditTarget, current: String) {
        showConfig = true
        thresholdDraft = current
        thresholdEdit = target
    }

    /// Commit the typed custom value. Invalid input keeps the field open with
    /// the inline invalid treatment (the parse helpers are the single gate,
    /// mirroring the socket's validation) — no toast, no silent clamp.
    func commitThresholdEdit() {
        guard let target = thresholdEdit else { return }
        switch target {
        case .fiveHour(let name):
            guard let v = ChainEdit.parseFiveHourThreshold(thresholdDraft) else { return }
            setThreshold(name, v)
        case .weekly:
            guard let v = ChainEdit.parseWeeklyLine(thresholdDraft) else { return }
            setWeeklyThreshold(v)
        }
        thresholdEdit = nil
    }

    func cancelThresholdEdit() {
        thresholdEdit = nil
    }
    // Refreshes are usage re-fetches, not config edits — no "Applying…" shimmer.
    // (Explicit `work:`-position arg, not a trailing closure, so it can't bind to
    // the optional `expecting` closure param instead.)
    func refresh() { run({ DaemonClient.refresh(nil) }, shimmer: false) }
    /// Force a usage re-fetch for one account (context-menu "Refresh <name>", §7).
    func refresh(_ name: String) { run({ DaemonClient.refresh(name) }, shimmer: false) }

    /// Re-authenticate a dropped account (AUTH-3) through `clauth login`. Spawns OFF
    /// the main actor — a browser flow blocks until the sign-in finishes — while the
    /// detail card shows an in-flight state. On success the CLI cleared `auth_broken`
    /// and wrote fresh tokens, so we nudge a refresh to surface it without waiting
    /// for the next poll. Only one login runs at a time. TABS-1: `codex` + `mode`
    /// pick the CLI shape — claude is always a browser OAuth; a codex profile can be
    /// re-signed-in via browser PKCE (`--codex --browser`) or re-captured from the
    /// live `~/.codex/auth.json` (`--codex`, instant). `run` is injected so the
    /// outcome routing is testable without spawning.
    func reauth(
        _ name: String,
        codex: Bool = false,
        mode: LoginMode = .browser,
        run: (@Sendable (String) async -> CommandOutcome)? = nil
    ) {
        guard loginInFlight == nil else { return } // one login at a time
        let runner = run ?? { await DaemonClient.login($0, codex: codex, browser: mode == .browser) }
        loginInFlight = LoginFlight(name: name, mode: codex ? mode : .browser)
        lastCommandError = nil
        errorClearTask?.cancel()
        Task { [weak self] in
            let outcome = await runner(name)
            guard let self else { return }
            self.loginInFlight = nil
            if let message = Self.loginFailureMessage(outcome, name: name, codex: codex, mode: mode) {
                self.showError(message)
            } else if self.daemonReachable {
                // The CLI already cleared auth_broken + wrote fresh tokens; nudge a
                // refresh so status.json reflects it promptly. SKIP when the daemon is
                // down — the login still succeeded, but a socket refresh would surface a
                // false "daemon unreachable" error; the next daemon tick picks it up.
                self.refresh(name)
            }
        }
    }

    // MARK: - Add a brand-new account ("Add account…" → inline banner → login)

    /// Open the inline add-account editor for a harness (a name field + the
    /// harness's sign-in verbs — claude: browser; codex: capture OR browser).
    func beginAddAccount(_ harness: Harness = .claude) { addingHarness = harness }
    /// Dismiss the inline add-account editor without signing in.
    func cancelAddAccount() { addingHarness = nil }

    /// Sign in a BRAND-NEW account through the same self-contained browser OAuth flow
    /// as reauth. Since clauth v0.8.0 `clauth login <name>` CREATES the profile when
    /// `name` is new, so this reuses the exact launcher AND the single-login in-flight
    /// guard (`reauthInFlight`) — only one browser sign-in runs at a time across BOTH
    /// flows. The name is pre-validated against clauth's rule INCLUDING a
    /// case-insensitive collision pre-block: `clauth login <existing>` would silently
    /// re-authenticate that profile (no TTY confirm fires for our non-TTY spawn), so an
    /// already-taken name must be refused here, not spawned. On success clauth wrote the
    /// new profile to config; the daemon reloads config on the external change, so we
    /// inspect the newcomer (pure view state) and — when the socket is reachable — nudge
    /// a refresh so it surfaces without waiting for the 4s poll. Chain membership is
    /// deliberately NOT touched — the CHAIN section's add-picker owns that. `run` is
    /// injected so outcome routing is testable without spawning `clauth login`.
    func addAccount(
        _ name: String,
        codex: Bool = false,
        mode: LoginMode = .browser,
        run: (@Sendable (String) async -> CommandOutcome)? = nil
    ) {
        guard loginInFlight == nil else { return } // one login at a time
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        // Fast client-side feedback — the banner already disables Sign-in on an
        // invalid name; this re-check catches programmatic callers. The AUTHORITATIVE
        // collision guard is `--new` in the spawn below (`DaemonClient.login`):
        // this snapshot-based check is a TOCTOU against clauth's real config, so a
        // duplicate that slips past it gets a loud non-zero exit, never a silent
        // reauth of someone else's account. Names are GLOBAL across harnesses in
        // clauth config, so the collision check spans both lists.
        if let error = AddAccountValidation.error(trimmed, existing: listProfiles.map(\.name)) {
            showError(error)
            return
        }
        let runner = run ?? {
            await DaemonClient.login($0, newOnly: true, codex: codex, browser: mode == .browser)
        }
        addingHarness = nil
        loginInFlight = LoginFlight(name: trimmed, mode: codex ? mode : .browser)
        lastCommandError = nil
        errorClearTask?.cancel()
        Task { [weak self] in
            let outcome = await runner(trimmed)
            guard let self else { return }
            self.loginInFlight = nil
            if let message = Self.loginFailureMessage(outcome, name: trimmed, codex: codex, mode: mode) {
                self.showError(message)
                return
            }
            // Success: clauth wrote the new profile. Inspect the newcomer (pure view
            // state, zero daemon traffic) so it's the focused row the moment it lands,
            // and — only when the socket is reachable — nudge a refresh so status.json
            // reflects the external config change promptly. SKIP the socket refresh when
            // the daemon is down (the login still succeeded; the next tick surfaces it)
            // to avoid a false "daemon unreachable" banner.
            self.inspect(trimmed)
            if self.daemonReachable { self.refresh() }
        }
    }

    /// The user-facing error for a login outcome (reauth OR add-account), or nil on
    /// success. ONE source of truth for all flows, including the "run it in a
    /// terminal" fallback hint — which must name the exact CLI shape that failed
    /// (`--codex [--browser]` for codex), and a codex CAPTURE failure must not read
    /// as a browser sign-in problem. Pure so the copy is unit-tested without
    /// spawning `clauth login`.
    nonisolated static func loginFailureMessage(
        _ outcome: CommandOutcome, name: String, codex: Bool = false, mode: LoginMode = .browser
    ) -> String? {
        let cli = "clauth login \(name)"
            + (codex ? " --codex" : "")
            + (codex && mode == .browser ? " --browser" : "")
        switch outcome {
        case .ok:
            return nil
        case .daemonError(_, let message):
            if codex && mode == .capture {
                return "Couldn't capture the codex login (\(message)). Is codex signed in? Or run `\(cli)` in a terminal."
            }
            return "Sign-in didn't complete (\(message)). Try again, or run `\(cli)` in a terminal."
        case .unreachable:
            return "Couldn't find the clauth binary. Run `\(cli)` in a terminal."
        }
    }

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

    // MARK: - Rename a profile (context-menu "Rename…" → inline banner)

    /// Open the inline rename editor for `name`.
    func beginRename(_ name: String) { renaming = name }
    func cancelRename() { renaming = nil }

    /// Commit a rename. Validates the new name client-side for instant feedback (the
    /// daemon re-validates authoritatively); an invalid/taken name surfaces a loud
    /// error and does NOT fire the socket. On accept, the settle ladder waits for the
    /// renamed profile to appear in status.json.
    func commitRename(_ old: String, to new: String) {
        let existing = listProfiles.map(\.name)
        if let error = Self.renameValidationError(new, old: old, existing: existing) {
            renaming = nil
            showError(error)
            return
        }
        let trimmed = new.trimmingCharacters(in: .whitespaces)
        renaming = nil
        run({ DaemonClient.rename(old, to: trimmed) },
            expecting: { $0.profiles.contains { $0.name == trimmed } })
    }

    /// Client-side name check mirroring the daemon's `validate_profile_name`: non-empty,
    /// charset (letters/digits/`-`/`_`/`.`, not leading `.`), and no collision with a
    /// DIFFERENT existing profile (a case-only self-rename is allowed). Returns nil when
    /// valid. Pure/`nonisolated` so it's unit-tested without a daemon.
    nonisolated static func renameValidationError(_ new: String, old: String, existing: [String]) -> String? {
        let trimmed = new.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Name can't be empty." }
        let ok = trimmed.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
        if !ok || trimmed.hasPrefix(".") {
            return "Use only letters, digits, '-', '_', or '.', and don't start with '.'."
        }
        if existing.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame
            && $0.caseInsensitiveCompare(old) != .orderedSame })
        {
            return "A profile named '\(trimmed)' already exists."
        }
        return nil
    }

    // MARK: - Shared command plumbing (run → handle → settle)

    /// Run a command's blocking socket I/O OFF the main actor (TECH-10 #25 — a
    /// switch parks the socket ~2s while the daemon holds its config lock across a
    /// Keychain rewrite; on @MainActor that's the beach-ball), then on the main
    /// actor surface any error LOUDLY and, on success, run the verification ladder
    /// so the panel reflects the change (TECH-11). Call sites stay synchronous.
    func run(
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

    /// Verification ladder for CONFIG commands (TECH-11): re-read `status.json` until
    /// `generated_at` advances AND the command's `expecting` effect actually holds,
    /// then stop. The predicate is load-bearing — WITHOUT it the ladder would stop on
    /// the next unrelated ~1s status write (the daemon rewrites every tick), often
    /// BEFORE the edit lands, dropping detection onto the slow 4s poll (the "3s lag").
    /// Cadence is front-loaded (cumulative ≈ 0.15/0.35/0.6/0.95/1.45/2.15/3.15/4.45s)
    /// so it catches the daemon's write promptly — sub-second once the daemon applies
    /// config ops immediately. Never declares failure; cancels any in-flight ladder.
    private func settle(expecting predicate: (@Sendable (DaemonStatus) -> Bool)? = nil) {
        let baseline = status?.generatedAt
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            for sleep in [0.15, 0.2, 0.25, 0.35, 0.5, 0.7, 1.0, 1.3] {
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
