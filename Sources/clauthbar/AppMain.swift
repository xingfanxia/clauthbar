import SwiftUI

/// Process entry. Normally runs the menu-bar app; `--snapshot <path>` renders the
/// panel to a PNG and exits (a dev aid, see `Snapshot`).
@main
struct Entry {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Snapshot.render(to: args[i + 1])
            return
        }
        ClauthBarApp.main()
    }
}

/// A menu-bar-only SwiftUI app (`LSUIElement` in Info.plist keeps it out of the
/// Dock). `MenuBarExtra(.window)` gives a translucent SwiftUI panel — the same
/// style CodexBar uses — instead of a plain `NSMenu`.
struct ClauthBarApp: App {
    @StateObject private var model = StatusModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu-bar item: a gauge glyph + the active account name + its 5h %, so the
/// active account is legible at a glance. Shows "—" (not a misleading 0%) when the
/// active account has no 5h data yet.
private struct MenuBarLabel: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
            if let active = model.active {
                Text(active.name)
                if let five = active.fiveHour {
                    Text("\(Int(five.utilizationPct.rounded()))%").monospacedDigit()
                } else {
                    Text("—")
                }
            }
        }
    }
}
