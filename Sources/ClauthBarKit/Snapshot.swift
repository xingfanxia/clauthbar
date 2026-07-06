import AppKit
import SwiftUI

/// Headless render of `PanelView` (with mock data) to a PNG — a dev aid so the
/// panel's look can be reviewed without opening the menu bar. Invoked via
/// `clauthbar --snapshot <path>`; never part of the normal app run.
enum Snapshot {
    /// Back-compat: `--snapshot <path>` renders the healthy panel.
    @MainActor
    static func render(to path: String) { render(variant: "healthy", to: path) }

    /// Re-serialize the fixture with `generated_at` bumped to NOW, so a live-state
    /// render reads "live · updated now" instead of the fixture's fixed timestamp
    /// (which would show a misleading "frozen · updated Nd ago" on a hero image). Only
    /// the live variants use this; the dead/stale variants keep the old stamp on
    /// purpose. Falls back to the original data if the rewrite fails.
    private static func fixtureFreshened(from data: Data) -> Data {
        guard var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        dict["generated_at"] = fmt.string(from: Date())
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? data
    }

    /// Re-serialize the fixture with `clauth_version` swapped, for the skew variant.
    /// Fields are `let`, so this round-trips through a dictionary rather than mutating.
    private static func fixtureWithVersion(_ version: String, from data: Data) -> DaemonStatus? {
        guard var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        dict["clauth_version"] = version
        guard let bumped = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(DaemonStatus.self, from: bumped)
    }

    /// Re-serialize the fixture with every "…fable…" window dropped from each profile —
    /// simulates the Fable trial ending (the daemon stops reporting the window), to
    /// verify the row + detail card collapse gracefully to 7d only.
    private static func fixtureWithoutFable(from data: Data) -> DaemonStatus? {
        guard var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var profiles = dict["profiles"] as? [[String: Any]] else {
            // A silent `?? mock` fallback would render the fable-PRESENT fixture while
            // claiming to be `no-fable` — flag it rather than mislead.
            FileHandle.standardError.write(Data("snapshot[no-fable]: fixture parse failed — falling back to fable-present\n".utf8))
            return nil
        }
        profiles = profiles.map { p in
            var p = p
            if let windows = p["windows"] as? [[String: Any]] {
                p["windows"] = windows.filter {
                    !(($0["label"] as? String)?.lowercased().contains("fable") ?? false)
                }
            }
            return p
        }
        dict["profiles"] = profiles
        guard let stripped = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(DaemonStatus.self, from: stripped)
    }

    /// Re-serialize the fixture with the first non-active anthropic profile's weekly
    /// window pinned to 100% — the real-world "week spent" case (a session with 5h
    /// headroom but its rolling weekly cap hit). Returns the (status, name-it-bumped)
    /// so the caller can inspect exactly the exhausted row (never drifting to a
    /// different one). nil if no such profile / no `7d` window exists to bump.
    private static func fixtureExhausted(from data: Data) -> (DaemonStatus, String)? {
        guard var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var profiles = dict["profiles"] as? [[String: Any]],
              let idx = profiles.firstIndex(where: {
                  ($0["active"] as? Bool) != true && ($0["provider"] as? String) == "anthropic"
              })
        else {
            FileHandle.standardError.write(Data("snapshot[spent]: no non-active anthropic profile to exhaust\n".utf8))
            return nil
        }
        var p = profiles[idx]
        let name = (p["name"] as? String) ?? ""
        guard var windows = p["windows"] as? [[String: Any]],
              windows.contains(where: { ($0["label"] as? String) == "7d" }) else {
            FileHandle.standardError.write(Data("snapshot[spent]: \(name) has no 7d window to pin — spent state NOT exercised\n".utf8))
            return nil
        }
        windows = windows.map { w in
            var w = w
            if (w["label"] as? String) == "7d" { w["utilization_pct"] = 100 }
            return w
        }
        p["windows"] = windows
        profiles[idx] = p
        dict["profiles"] = profiles
        guard let bumped = try? JSONSerialization.data(withJSONObject: dict),
              let status = try? JSONDecoder().decode(DaemonStatus.self, from: bumped) else { return nil }
        return (status, name)
    }

    /// Re-serialize the fixture with the first non-active profile's `auth_status`
    /// pinned to `"broken"` — the AUTH-3 dropped-login case. Returns (status, name)
    /// so the caller inspects exactly the broken row, whose detail card then shows the
    /// reauth surface ("login expired · Log in again").
    private static func fixtureAuthBroken(from data: Data, active: Bool) -> (DaemonStatus, String)? {
        guard var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var profiles = dict["profiles"] as? [[String: Any]],
              // Only OAuth (anthropic) accounts ever go auth_broken — mark one of those,
              // never a third-party api-key row (which has no login to renew). `active`
              // selects whether to break the ACTIVE account (the urgent case: its running
              // sessions are already failing) or a non-active one.
              let idx = profiles.firstIndex(where: {
                  (($0["active"] as? Bool) == true) == active
                      && ($0["provider"] as? String ?? "anthropic") == "anthropic"
              })
        else {
            FileHandle.standardError.write(Data("snapshot[reauth]: no \(active ? "active" : "non-active") anthropic profile to break\n".utf8))
            return nil
        }
        var p = profiles[idx]
        let name = (p["name"] as? String) ?? ""
        p["auth_status"] = "broken"
        profiles[idx] = p
        dict["profiles"] = profiles
        guard let bumped = try? JSONSerialization.data(withJSONObject: dict),
              let status = try? JSONDecoder().decode(DaemonStatus.self, from: bumped) else { return nil }
        return (status, name)
    }

    /// Render a canonical CBAR-4 state (design §2) or a legacy liveness variant, and
    /// print the resolved state to stderr so the logic is verifiable without eyeballing
    /// the PNG. Canonical: `default` (inspection on active), `inspecting` (a non-active
    /// row inspected), `mid-switch` (pending), `daemon-dead` (frozen banner + dim).
    /// `config` opens the expanded Configure disclosure (§7). Legacy:
    /// `healthy`/`stale`/`schema2`/`skew`.
    @MainActor
    static func render(variant: String, to path: String) {
        // Dead/stale variants intentionally show an old timestamp; every other variant
        // is a LIVE state, so freshen `generated_at` to now for an honest "live" stamp.
        let staleVariants: Set<String> = ["daemon-dead", "dead", "stale", "schema2", "skew"]
        guard let rawData = Fixtures.statusJSONData() else {
            FileHandle.standardError.write(Data("snapshot: failed to load fixture\n".utf8))
            return
        }
        let data = staleVariants.contains(variant) ? rawData : fixtureFreshened(from: rawData)
        guard let mock = try? JSONDecoder().decode(DaemonStatus.self, from: data) else {
            FileHandle.standardError.write(Data("snapshot: failed to decode fixture\n".utf8))
            return
        }
        let nonActive = mock.profiles.first { !$0.active }?.name ?? mock.profiles.first?.name ?? ""
        let exhausted = fixtureExhausted(from: data)
        let broken = fixtureAuthBroken(from: data, active: false)
        let brokenActive = fixtureAuthBroken(from: data, active: true)

        // (status, liveness, inspected, phase) per variant.
        let (status, liveness, inspected, phase): (DaemonStatus?, StatusModel.Liveness, String?, SwitchMachine.Phase) = {
            switch variant {
            case "inspecting": return (mock, .ok, nonActive, .idle)
            case "config": return (mock, .ok, nil, .idle)
            case "remove-confirm": return (mock, .ok, nil, .idle)
            case "no-fable": return (fixtureWithoutFable(from: data) ?? mock, .ok, nil, .idle)
            case "spent": return (exhausted?.0 ?? mock, .ok, exhausted?.1 ?? nonActive, .idle)
            case "rename": return (mock, .ok, nonActive, .idle)
            case "reauth": return (broken?.0 ?? mock, .ok, broken?.1 ?? nonActive, .idle)
            // The ACTIVE account is the one broken — inspect it to prove the detail card
            // shows the reauth verb (not the "Active account" readout) for an active drop.
            case "reauth-active": return (brokenActive?.0 ?? mock, .ok, brokenActive?.1 ?? nonActive, .idle)
            case "mid-switch": return (mock, .ok, nonActive, .pending(target: nonActive))
            case "daemon-dead", "dead", "stale": return (mock, .stalled(since: "05:00"), nil, .idle)
            case "schema2": return (nil, .outOfDate(schema: 2), nil, .idle)
            case "skew": return (fixtureWithVersion("9.9.9", from: data) ?? mock, .ok, nil, .idle)
            // default / healthy: inspected=nil resolves to the ACTIVE account (the real
            // first-open path — StatusModel.inspected falls back to active), so this
            // renders the one card that carries the "pick another account above to
            // switch" hint without pinning a name.
            default: return (mock, .ok, nil, .idle)
            }
        }()
        let resolved: String
        switch liveness {
        case .ok: resolved = "ok"
        case .stalled(let s): resolved = "stalled(since: \(s)); daemonStalled=true"
        case .outOfDate(let n): resolved = "outOfDate(schema: \(n))"
        case .down: resolved = "down"
        }
        let model = StatusModel(preview: status, liveness: liveness, inspected: inspected, phase: phase)
        if variant == "config" { model.showConfig = true }
        // Panel-level armed-member removal confirm (§7): arm it on the first armed
        // chain member so the banner renders.
        if variant == "remove-confirm" {
            model.pendingRemoval = mock.profiles.first { $0.fallback?.armed == true }?.name
        }
        if variant == "rename" { model.renaming = nonActive }
        let skewNote = model.versionSkew.map { " skew=\($0)" } ?? ""
        let phaseNote = phase == .idle ? "" : " phase=\(phase)"
        let inspectNote = inspected.map { " inspected=\($0)" } ?? ""
        FileHandle.standardError.write(
            Data("snapshot[\(variant)]: liveness=\(resolved)\(inspectNote)\(phaseNote)\(skewNote)\n".utf8))

        let view = PanelView(model: model)
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(.dark)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("snapshot: render failed\n".utf8))
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        FileHandle.standardError.write(Data("snapshot: wrote \(path)\n".utf8))
    }
}
