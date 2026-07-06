import Foundation

/// Is this process the real, packaged ccsbar `.app`? The shared guard for every
/// system integration that needs a genuine app bundle (user notifications,
/// login-item registration).
///
/// A plain "has a bundle identifier" check is NOT enough: `swift test` runs under
/// the `xctest` tool, which carries its OWN bundle id, so a generic check would
/// wrongly fire the real `UNUserNotificationCenter` / `SMAppService` paths in
/// tests; `swift run` has no bundle id at all. Only the shipped `.app` carries this
/// exact identifier (`Scripts/Info.plist`), so gating on it makes those
/// integrations a true no-op in dev and tests while staying live in the app.
enum AppBundle {
    /// The packaged app's `CFBundleIdentifier` (must match `Scripts/Info.plist`).
    static let mainAppID = "com.xingfanxia.ccsbar"

    /// True only when running as the shipped `.app`.
    static var isMainApp: Bool { Bundle.main.bundleIdentifier == mainAppID }
}
