import AppKit

/// Owns the menu-bar `NSStatusItem` and its `NSMenu`. The menu is rebuilt from
/// `status.json` each time it opens (`menuNeedsUpdate`); a light timer refreshes
/// the glyph so the active account's 5h meter stays current without the menu open.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private var timer: Timer?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "gauge.with.dots.needle.bottom.50percent",
                accessibilityDescription: "clauth"
            ) ?? NSImage(systemSymbolName: "gauge.medium", accessibilityDescription: "clauth")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
        }

        refreshGlyph()
        timer = Timer.scheduledTimer(
            timeInterval: 5, target: self, selector: #selector(tick),
            userInfo: nil, repeats: true
        )
    }

    @objc private func tick() { refreshGlyph() }

    /// Update the menu-bar button: active account's 5h % as a compact label +
    /// tooltip. Dims nothing here (template image tints itself to the bar).
    private func refreshGlyph() {
        guard let status = DaemonClient.readStatus() else {
            statusItem.button?.title = ""
            statusItem.button?.toolTip = "clauth daemon not running"
            return
        }
        let active = status.profiles.first { $0.active }
        if let active {
            let pct = Int(active.fiveHourPct.rounded())
            statusItem.button?.title = " \(pct)%"
            let stale = active.isStale ? " (stale)" : ""
            statusItem.button?.toolTip = "\(active.name) — 5h \(pct)%\(stale)"
        } else {
            statusItem.button?.title = ""
            statusItem.button?.toolTip = "no active account"
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let status = DaemonClient.readStatus() else {
            let item = NSMenuItem(
                title: "clauth daemon not running", action: nil, keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
            addQuit(to: menu)
            return
        }

        // Active account pinned first, then the rest in file order.
        let ordered = status.profiles.sorted { a, b in a.active && !b.active }
        for profile in ordered {
            menu.addItem(accountItem(for: profile))
        }

        menu.addItem(.separator())
        let refresh = NSMenuItem(
            title: "Refresh now", action: #selector(refreshClicked), keyEquivalent: ""
        )
        refresh.target = self
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        menu.addItem(refresh)
        addQuit(to: menu)
    }

    // MARK: - Item builders

    private func accountItem(for p: ProfileStatus) -> NSMenuItem {
        let item = NSMenuItem(
            title: p.name, action: #selector(switchClicked(_:)), keyEquivalent: ""
        )
        item.target = self
        item.representedObject = p.name
        item.attributedTitle = accountTitle(for: p)
        item.state = p.active ? .on : .off
        return item
    }

    /// Two lines: `● name    tier` then `5h ████░░ 42%   ⚡ #1 @95`.
    private func accountTitle(for p: ProfileStatus) -> NSAttributedString {
        let title = NSMutableAttributedString()

        // Line 1 — dot + bold name + plan tier.
        let dot = p.active ? "● " : "○ "
        let dotColor: NSColor = p.active ? Theme.orange : .tertiaryLabelColor
        title.append(NSAttributedString(string: dot, attributes: [.foregroundColor: dotColor]))
        title.append(NSAttributedString(
            string: p.name,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: p.active ? Theme.orange : NSColor.labelColor,
            ]
        ))
        if let tier = p.tier {
            title.append(NSAttributedString(
                string: "   \(tier)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ))
        }

        // Line 2 — 5h bar + % + fallback/armed hint.
        let pct = p.fiveHourPct
        let barColor: NSColor
        if let fb = p.fallback {
            barColor = Theme.healthColor(pct, threshold: fb.threshold)
        } else {
            barColor = Theme.utilColor(pct)
        }
        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        title.append(NSAttributedString(string: "\n5h ", attributes: [
            .font: mono, .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        let barLine = NSMutableAttributedString(attributedString: Theme.bar(pct: pct, color: barColor))
        barLine.addAttribute(.font, value: mono, range: NSRange(location: 0, length: barLine.length))
        title.append(barLine)
        title.append(NSAttributedString(
            string: String(format: "  %.0f%%", pct),
            attributes: [.font: mono, .foregroundColor: NSColor.secondaryLabelColor]
        ))
        if let fb = p.fallback, fb.armed {
            title.append(NSAttributedString(
                string: "   ⚡ #\(fb.position) @\(Int(fb.threshold))",
                attributes: [.font: mono, .foregroundColor: Theme.sapphire]
            ))
        }
        if p.isStale {
            title.append(NSAttributedString(
                string: "   (\(p.fetchStatus ?? "stale"))",
                attributes: [.font: mono, .foregroundColor: Theme.warning]
            ))
        }
        return title
    }

    private func addQuit(to menu: NSMenu) {
        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit clauthbar", action: #selector(quitClicked), keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func switchClicked(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        DaemonClient.switchTo(name)
        // Give the daemon a beat to land the switch, then refresh the glyph.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.refreshGlyph()
        }
    }

    @objc private func refreshClicked() {
        DaemonClient.refresh(nil)
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }
}
