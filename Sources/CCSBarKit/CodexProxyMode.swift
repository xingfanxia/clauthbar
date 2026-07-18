import Darwin
import Foundation

/// Codex "Proxy mode" (PROXY-1): whether plain `codex` routes through clauth's
/// CDX-5 localhost proxy (per-request account injection → clauth switches
/// apply to RUNNING sessions, and rate-limited requests rotate + replay).
///
/// The toggle is the USER's hand on `~/.codex/config.toml`: ON writes the
/// top-level `model_provider = "clauth"` (and ensures the provider-definition
/// block exists), OFF removes that one line — codex then falls back to its
/// built-in `openai` provider. The definition BLOCK is always left in place:
/// sessions started under proxy mode reference the provider by name and fail
/// to resume without it (observed 2026-07-18). clauth itself never edits this
/// file (its design charter); ccsbar edits it only on an explicit click.
///
/// The proxy LaunchAgent (`com.clauth.proxy`) is ensured loaded on ON but
/// deliberately NOT unloaded on OFF: sessions opted in via
/// `codex --profile proxy` (and pre-toggle sessions) still depend on it, and
/// an idle proxy's heartbeat goes stale on its own so the daemon's passive
/// usage leg resumes.
///
/// NOTE: config.toml is also managed by zylos (its own agent). If the toggle
/// snaps back OFF on the next panel open, zylos reverted the edit — that
/// arbitration belongs to the operator, not to ccsbar retry loops.
enum CodexProxyMode {
    static let proxyPort: UInt16 = 4517

    /// The provider-definition block appended when absent (mirrors
    /// `clauth proxy --print-config`, minus the top-level routing line).
    static let providerBlock = """
    [model_providers.clauth]
    name = "openai"
    base_url = "http://127.0.0.1:4517/backend-api/codex"
    wire_api = "responses"
    requires_openai_auth = true
    """

    // MARK: - Pure config transforms (unit-tested)

    /// Whether the config routes codex through clauth: a top-level
    /// (before the first `[table]` header) non-comment
    /// `model_provider = "clauth"` line.
    static func isRouted(config: String) -> Bool {
        topLevelProviderLine(config)?.value == "clauth"
    }

    /// Whether the `[model_providers.clauth]` definition exists (any depth).
    static func hasProviderBlock(config: String) -> Bool {
        config.split(separator: "\n", omittingEmptySubsequences: false)
            .contains { $0.trimmingCharacters(in: .whitespaces) == "[model_providers.clauth]" }
    }

    /// The routed/direct rewrite. ON: replace (or insert at top) the top-level
    /// `model_provider` line with `"clauth"`, and append the definition block
    /// when missing. OFF: drop the top-level line only when it points at
    /// clauth (a user-set third provider is not ours to remove); the
    /// definition block always stays.
    static func setRouting(config: String, on: Bool) -> String {
        var lines = config.components(separatedBy: "\n")
        let found = topLevelProviderLine(config)

        if on {
            if let found {
                lines[found.index] = "model_provider = \"clauth\""
            } else {
                lines.insert("model_provider = \"clauth\"", at: 0)
            }
            var out = lines.joined(separator: "\n")
            if !hasProviderBlock(config: out) {
                if !out.hasSuffix("\n") { out += "\n" }
                out += "\n" + providerBlock + "\n"
            }
            return out
        }

        if let found, found.value == "clauth" {
            lines.remove(at: found.index)
        }
        return lines.joined(separator: "\n")
    }

    /// First top-level (pre-table) non-comment `model_provider = "..."` line:
    /// its line index and unquoted value.
    private static func topLevelProviderLine(_ config: String) -> (index: Int, value: String)? {
        for (i, raw) in config.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { return nil } // first table header ends top level
            if line.hasPrefix("#") || line.isEmpty { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard key == "model_provider" else { continue }
            let value = line[line.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return (i, value)
        }
        return nil
    }

    // MARK: - IO

    static var configPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml")
    }

    /// Read the current routed state from disk (false when unreadable).
    static func routed() -> Bool {
        guard let text = try? String(contentsOf: configPath, encoding: .utf8) else { return false }
        return isRouted(config: text)
    }

    /// Apply the toggle: backup, transform, atomic-ish rewrite. Throws with a
    /// readable message for the row's error caption.
    static func apply(on: Bool) throws {
        let text = try String(contentsOf: configPath, encoding: .utf8)
        let backup = configPath.deletingLastPathComponent()
            .appendingPathComponent("config.toml.bak-ccsbar")
        try? text.write(to: backup, atomically: true, encoding: .utf8)
        try setRouting(config: text, on: on)
            .write(to: configPath, atomically: true, encoding: .utf8)
        if on { ensureProxyLoaded() }
    }

    /// Best-effort `launchctl bootstrap` of the proxy LaunchAgent — a no-op
    /// (non-zero exit, ignored) when it is already loaded or the plist is
    /// absent; the serving probe is the truth the row displays.
    static func ensureProxyLoaded() {
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.clauth.proxy.plist").path
        guard FileManager.default.fileExists(atPath: plist) else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["bootstrap", "gui/\(getuid())", plist]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
    }

    /// Whether anything is listening on the proxy port (loopback connect —
    /// instant on localhost either way). Call off the main thread.
    static func serving() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = proxyPort.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
