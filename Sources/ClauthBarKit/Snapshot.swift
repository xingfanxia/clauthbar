import AppKit
import SwiftUI

/// Headless render of `PanelView` (with mock data) to a PNG — a dev aid so the
/// panel's look can be reviewed without opening the menu bar. Invoked via
/// `clauthbar --snapshot <path>`; never part of the normal app run.
enum Snapshot {
    /// Back-compat: `--snapshot <path>` renders the healthy panel.
    @MainActor
    static func render(to path: String) { render(variant: "healthy", to: path) }

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

    /// Render a canonical CBAR-4 state (design §2) or a legacy liveness variant, and
    /// print the resolved state to stderr so the logic is verifiable without eyeballing
    /// the PNG. Canonical: `default` (inspection on active), `inspecting` (a non-active
    /// row inspected), `mid-switch` (pending), `daemon-dead` (frozen banner + dim).
    /// Legacy: `healthy`/`stale`/`schema2`/`skew`.
    @MainActor
    static func render(variant: String, to path: String) {
        guard let data = Fixtures.statusJSONData(),
              let mock = try? JSONDecoder().decode(DaemonStatus.self, from: data)
        else {
            FileHandle.standardError.write(Data("snapshot: failed to load/decode fixture\n".utf8))
            return
        }
        let nonActive = mock.profiles.first { !$0.active }?.name ?? mock.profiles.first?.name ?? ""

        // (status, liveness, inspected, phase) per variant.
        let (status, liveness, inspected, phase): (DaemonStatus?, StatusModel.Liveness, String?, SwitchMachine.Phase) = {
            switch variant {
            case "inspecting": return (mock, .ok, nonActive, .idle)
            case "mid-switch": return (mock, .ok, nonActive, .pending(target: nonActive))
            case "daemon-dead", "dead", "stale": return (mock, .stalled(since: "05:00"), nil, .idle)
            case "schema2": return (nil, .outOfDate(schema: 2), nil, .idle)
            case "skew": return (fixtureWithVersion("9.9.9", from: data) ?? mock, .ok, nil, .idle)
            default: return (mock, .ok, nil, .idle) // default / healthy
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
