import Foundation
import ServiceManagement

/// Registers ccsbar as a macOS login item so its monitoring surface returns
/// after a reboot (TECH-14 #42) — without it, a macOS update reboot silently
/// leaves the daemon running (its own LaunchAgent) but ccsbar gone, so the
/// operator loses every human-facing window into the daemon.
///
/// `SMAppService.mainApp` needs a real app bundle; bare `swift run` has no bundle
/// id, so every entry point no-ops there (like `Notifier`). Registration is
/// best-effort — a denied/failed register must NEVER block launch.
enum LoginItem {
    /// True only inside the real packaged app — the guard that keeps `swift run`
    /// AND `swift test` (which runs under the xctest tool's own bundle id) safe.
    static var isAvailable: Bool { AppBundle.isMainApp }

    /// Whether ccsbar is set to launch at login (false when unavailable, e.g.
    /// dev/test). `.requiresApproval` (macOS common on first register — the user
    /// must flip it on in System Settings › Login Items) counts as ON, else the
    /// panel Toggle would read false and snap back the instant the user enables it.
    static var isEnabled: Bool {
        guard isAvailable else { return false }
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    /// Register on first launch UNLESS the user has explicitly turned autostart off.
    /// Idempotent — `register()` when already enabled is a no-op per SMAppService.
    static func registerIfNeeded() {
        guard isAvailable else { return }
        // Only skip when the user explicitly opted out; a nil default means
        // first-launch → auto-register (the desired default).
        if UserDefaults.standard.object(forKey: userChoiceKey) as? Bool == false { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            NSLog("ccsbar: login-item registration failed: \(error.localizedDescription)")
        }
    }

    /// Explicit user toggle from the panel: persist the choice, then (un)register.
    /// Both are gated on availability — persisting a login-item choice where
    /// SMAppService can't act is meaningless, and keeps the no-op contract total.
    static func setEnabled(_ on: Bool) {
        guard isAvailable else { return }
        UserDefaults.standard.set(on, forKey: userChoiceKey)
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("ccsbar: login-item toggle failed: \(error.localizedDescription)")
        }
    }

    /// Persists the user's autostart choice; absent = first launch (auto-register).
    private static let userChoiceKey = "ccsbar.startAtLogin"
}
