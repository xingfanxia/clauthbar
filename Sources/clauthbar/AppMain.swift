import AppKit

/// Entry point. Runs as an accessory (menu-bar-only, no Dock icon) so it works
/// as a bare `swift run` executable without an app bundle's `LSUIElement`.
@main
struct ClauthBarMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = StatusItemController()
    }
}
