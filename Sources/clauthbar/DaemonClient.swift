import Foundation

/// Reads `~/.clauth/status.json` and drives `~/.clauth/clauthd.sock`.
///
/// Display is a plain file read (the daemon rewrites status.json every tick, so
/// polling the file is fresh within a second and needs no connection). `switch`
/// and `refresh` prefer the socket for low latency and fall back to shelling
/// `clauth <name>` when the daemon (hence the socket) isn't running.
enum DaemonClient {
    static var clauthDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clauth")
    }
    static var statusURL: URL { clauthDir.appendingPathComponent("status.json") }
    static var socketPath: String { clauthDir.appendingPathComponent("clauthd.sock").path }

    // MARK: - Status (file)

    /// Read + decode status.json, or nil if absent/unparseable.
    static func readStatus() -> DaemonStatus? {
        guard let data = try? Data(contentsOf: statusURL) else { return nil }
        return try? JSONDecoder().decode(DaemonStatus.self, from: data)
    }

    /// mtime of status.json for cheap change detection.
    static func statusMtime() -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: statusURL.path)
        return attrs?[.modificationDate] as? Date
    }

    /// True when the daemon's control socket is present (a daemon is likely live).
    static var daemonSocketExists: Bool {
        FileManager.default.fileExists(atPath: socketPath)
    }

    // MARK: - Commands

    /// Switch the global active profile. Socket first, `clauth <name>` fallback.
    static func switchTo(_ profile: String) {
        if sendCommand(["cmd": "switch", "profile": profile]) != nil { return }
        shellClauth([profile])
    }

    /// Force a usage re-fetch (all profiles when `profile` is nil). Socket only —
    /// there's no `clauth refresh` CLI, and a missed manual refresh is harmless
    /// (the daemon refreshes on its own cadence).
    static func refresh(_ profile: String?) {
        var cmd: [String: Any] = ["cmd": "refresh"]
        if let profile { cmd["profile"] = profile }
        _ = sendCommand(cmd)
    }

    // MARK: - Socket

    /// Send one newline-delimited JSON command and parse the reply object.
    @discardableResult
    private static func sendCommand(_ command: [String: Any]) -> [String: Any]? {
        guard let payload = try? JSONSerialization.data(withJSONObject: command),
              let reply = sendRaw(payload),
              let obj = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
              obj["ok"] as? Bool == true
        else { return nil }
        return obj
    }

    /// Connect to the unix socket, write one line, read the reply. Returns nil on
    /// any failure (no socket, connect refused, short read) so callers can fall back.
    private static func sendRaw(_ payload: Data) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let dst = raw.bindMemory(to: CChar.self)
            for i in 0..<min(pathBytes.count, dst.count) {
                dst[i] = pathBytes[i]
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard connected == 0 else { return nil }

        var line = payload
        line.append(0x0A) // newline-delimited
        let wrote = line.withUnsafeBytes { write(fd, $0.baseAddress, line.count) }
        guard wrote > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &buffer, buffer.count)
        guard n > 0 else { return nil }
        return Data(buffer[0..<n])
    }

    // MARK: - Shell fallback

    /// Locate the `clauth` binary: PATH, then the standard cargo bin.
    private static func clauthBinary() -> String? {
        let cargo = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cargo/bin/clauth").path
        for candidate in ["/opt/homebrew/bin/clauth", "/usr/local/bin/clauth", cargo] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func shellClauth(_ args: [String]) {
        guard let bin = clauthBinary() else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = args
        try? proc.run()
    }
}
