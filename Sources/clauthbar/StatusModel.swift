import SwiftUI

/// Polls `~/.clauth/status.json` on a timer and publishes it to the panel + the
/// menu-bar label. Also the one place that fires switch/config commands at the
/// daemon (via `DaemonClient`) and schedules a quick re-read so the UI reflects
/// the change once the daemon's next tick lands it (~1s).
@MainActor
final class StatusModel: ObservableObject {
    @Published private(set) var status: DaemonStatus?
    @Published var showConfig = false

    private var timer: Timer?

    init() {
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    /// Preview/snapshot init: inject a fixed status, no polling.
    init(preview: DaemonStatus) {
        self.status = preview
    }

    func reload() { status = DaemonClient.readStatus() }

    var active: ProfileStatus? { status?.profiles.first { $0.active } }

    /// Active pinned first, then file order — the switcher's tile order.
    var orderedProfiles: [ProfileStatus] {
        (status?.profiles ?? []).sorted { a, b in a.active && !b.active }
    }

    // MARK: - Commands (fire, then re-read once the daemon lands it)

    func switchTo(_ name: String) { DaemonClient.switchTo(name); settle() }
    func fallbackAdd(_ name: String) { DaemonClient.fallbackAdd(name); settle() }
    func fallbackRemove(_ name: String) { DaemonClient.fallbackRemove(name); settle() }
    func fallbackMove(_ name: String, up: Bool) { DaemonClient.fallbackMove(name, up: up); settle() }
    func setThreshold(_ name: String, _ value: Int) { DaemonClient.setThreshold(name, value); settle() }
    func setWrapOff(_ on: Bool) { DaemonClient.setWrapOff(on); settle() }
    func refresh() { DaemonClient.refresh(nil); settle() }

    /// The daemon applies queued edits on its next ~1s tick; re-read shortly after
    /// so the panel updates without waiting for the 4s poll.
    private func settle() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.reload() }
    }
}
