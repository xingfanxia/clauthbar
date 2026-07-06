import AppKit

/// Guards against two ccsbars running at once (TECH-14 #33). The README ships
/// two run modes, so the guard has two mechanisms: a packaged `.app` has a bundle
/// id, so the OS can enumerate running copies; bare `swift run` has no bundle id,
/// so it falls back to an advisory `flock` on `~/.clauth/ccsbar.lock`.
///
/// `acquire()` returns false when another instance already owns the slot (the
/// caller should then exit). For the packaged case it calls `activate()` on the
/// existing instance first — this is a best-effort nicety, NOT a panel-open: the
/// app is `LSUIElement` with no window, so the surviving instance simply keeps its
/// one menu-bar item and the duplicate bows out. (`LSMultipleInstancesProhibited`
/// in Info.plist makes LaunchServices refuse the second launch deterministically;
/// this guard covers `open -n` and `swift run`, which that key doesn't gate.)
enum SingleInstance {
    /// The outcome of an advisory `flock` attempt, kept explicit so the caller can
    /// tell "another instance holds it" (bow out) from "couldn't even open the lock
    /// file" (a filesystem hiccup must NOT block the user's app).
    enum FlockResult: Equatable {
        case acquired(Int32) // we hold the lock; keep the fd open for its lifetime
        case held            // another process holds it
        case unavailable     // couldn't open the lock file at all
    }

    /// True when this is the sole instance (and, for `swift run`, now holds the
    /// lock for the process lifetime). MUST be called on the app path only, not the
    /// `--snapshot` dev render (which is expected to run alongside a live app).
    @MainActor
    static func acquire() -> Bool {
        // NB: this intentionally branches on "has ANY bundle id" (OS enumeration
        // works regardless of which id), NOT AppBundle.isMainApp — unlike Notifier/
        // LoginItem. acquire() is only ever called on the real app path (never in
        // tests), so the xctest-id case can't arise here.
        if let bundleID = Bundle.main.bundleIdentifier {
            return acquireByBundle(bundleID)
        }
        return acquireByFlock()
    }

    /// Packaged `.app`: if another process shares our bundle id, nudge it to the
    /// front and bow out. Compared by pid so we never mistake ourselves for the
    /// "other" instance.
    @MainActor
    private static func acquireByBundle(_ bundleID: String) -> Bool {
        let mine = NSRunningApplication.current.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != mine }
        guard let existing = others.first else { return true }
        existing.activate()
        return false
    }

    /// `swift run` (no bundle id): take an exclusive advisory lock. Held for the
    /// process lifetime via `lockFD`; a filesystem failure to open the lock file
    /// must not block startup (we can't enforce, so we proceed).
    @MainActor
    private static func acquireByFlock() -> Bool {
        let dir = DaemonClient.clauthDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("ccsbar.lock").path
        switch tryFlock(at: path) {
        case .acquired(let fd):
            lockFD = fd
            return true
        case .held:
            return false
        case .unavailable:
            return true
        }
    }

    /// The fd for the advisory lock. The lock is held because the fd is simply never
    /// closed (fds aren't ref-counted by Swift); this field retains it so the intent
    /// is explicit and an explicit-release path could `close(lockFD)` later. Do NOT
    /// add a `close(lockFD)` as "cleanup" — that would RELEASE the lock. Written
    /// once, on the main actor, at startup.
    @MainActor private static var lockFD: Int32 = -1

    /// Pure `flock` core (static-free so a test can drive it with a throwaway path):
    /// open the lock file and take an exclusive non-blocking advisory lock.
    nonisolated static func tryFlock(at path: String) -> FlockResult {
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return .unavailable }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return .held
        }
        return .acquired(fd)
    }
}
