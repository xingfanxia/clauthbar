import Foundation
import XCTest

@testable import CCSBarKit

/// TECH-14 (e) single-instance guard + (f) login-item automation. The system-bound
/// halves (NSRunningApplication enumeration, SMAppService registration) are
/// operator-verifiable in the packaged .app; here we pin the pure flock core and
/// the dev/test no-op guarantees.
final class AutostartTests: XCTestCase {
    // MARK: - Single-instance flock core (#33)

    func testFlockIsExclusiveAndReleases() {
        // A throwaway lock path — never the real ~/.clauth/ccsbar.lock.
        let path = NSTemporaryDirectory() + "ccsbar-test-\(getpid())-\(ObjectIdentifier(self).hashValue).lock"
        defer { unlink(path) }

        // First acquirer takes the exclusive lock.
        guard case .acquired(let fd) = SingleInstance.tryFlock(at: path) else {
            return XCTFail("first tryFlock must acquire")
        }
        // A second attempt (a distinct open file description) is blocked — this is
        // the "two ccsbars side by side" case the guard prevents.
        XCTAssertEqual(SingleInstance.tryFlock(at: path), .held)

        // Releasing (closing the fd) frees the slot for a later instance.
        close(fd)
        guard case .acquired(let fd2) = SingleInstance.tryFlock(at: path) else {
            return XCTFail("after release the lock must be re-acquirable")
        }
        close(fd2)
    }

    func testFlockUnavailableOnUnwritablePath() {
        // A path under a non-existent directory can't be opened → .unavailable,
        // which acquire() treats as "can't enforce, don't block the user".
        let path = "/ccsbar-nonexistent-dir-\(getpid())/x.lock"
        XCTAssertEqual(SingleInstance.tryFlock(at: path), .unavailable)
    }

    // MARK: - Login item no-op without a bundle (#42)

    func testLoginItemNoOpsOutsideTheApp() {
        // The test host is the xctest tool, NOT the packaged app, so the specific
        // bundle-id guard must make every entry point a safe no-op — SMAppService
        // must never be touched (it would throw / mutate real login-item state).
        XCTAssertNotEqual(Bundle.main.bundleIdentifier, AppBundle.mainAppID)
        XCTAssertFalse(LoginItem.isAvailable)
        XCTAssertFalse(LoginItem.isEnabled)
        // Must not touch SMAppService nor throw when unavailable.
        LoginItem.registerIfNeeded()
        XCTAssertFalse(LoginItem.isEnabled)
    }

    func testNotifierNoOpsOutsideTheApp() {
        // Same guard protects the notification path (regression: a generic
        // "any bundle id" check fired UNUserNotificationCenter under xctest).
        XCTAssertFalse(Notifier.isAvailable)
    }
}
