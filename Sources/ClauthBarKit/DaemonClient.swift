import Foundation
import os

/// The outcome of reading `status.json` — distinguishes the states the panel must
/// render differently (TECH-4): a live snapshot, no file yet, an unsupported
/// schema (clauthbar out of date), or a corrupt/partial decode.
enum StatusRead: Sendable {
    case ok(DaemonStatus)
    case fileMissing
    case schemaUnsupported(Int)
    case decodeFailed
}

/// The outcome of a daemon command (TECH-11). The three cases must NOT collapse to
/// one nil: a daemon *rejection* (`ok:false` with an `error_code`) is authoritative
/// and must NOT trigger the daemon-ABSENCE shell fallback, and it carries an error
/// the UI is obligated to surface ('errors must be loud').
enum CommandOutcome: Sendable, Equatable {
    /// Accepted (`ok:true`), or the CLI fallback exited 0.
    case ok
    /// The daemon replied `ok:false` — a real rejection (unknown_profile, busy,
    /// auth_broken, invalid_value), or the CLI fallback exited non-zero.
    case daemonError(code: String, message: String)
    /// No daemon reachable (no socket / transport failure) AND no working CLI —
    /// nothing applied the command.
    case unreachable

    var errorMessage: String? {
        if case .daemonError(_, let message) = self { return message }
        return nil
    }
}

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

    private static let log = Logger(subsystem: "com.clauth.clauthbar", category: "daemon-client")

    // MARK: - Status (file)

    /// Read status.json into one of four outcomes (TECH-4). The schema is probed
    /// BEFORE the full decode so a future schema bump reads as "clauthbar out of
    /// date", not "no daemon"; a genuine decode failure (corrupt/partial write) is
    /// logged (not silently swallowed) and reported distinctly from a missing file.
    static func readStatus() -> StatusRead {
        guard let data = try? Data(contentsOf: statusURL) else { return .fileMissing }
        if let probe = try? JSONDecoder().decode(SchemaProbe.self, from: data),
           probe.schema != supportedSchema {
            return .schemaUnsupported(probe.schema)
        }
        do {
            return .ok(try JSONDecoder().decode(DaemonStatus.self, from: data))
        } catch {
            log.error("status.json decode failed: \(error.localizedDescription, privacy: .public)")
            return .decodeFailed
        }
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

    /// How a switch dispatch resolved (CBAR4-3). The `accepted` vs `confirmedByCLI`
    /// split is load-bearing: a socket `accepted` still needs the daemon's next tick
    /// to LAND it (observe status.json), whereas a CLI switch is confirmed by its
    /// EXIT CODE and status.json will NOT move (only the daemon writes that file, and
    /// here it's dead) — watching mtime would false-fail the exact case (design §8).
    enum SwitchDispatch: Equatable, Sendable {
        case accepted                                 // socket ok — daemon applies on its next tick
        case confirmedByCLI                           // daemon unreachable; shelled `clauth` exited 0
        case refused(code: String, message: String)   // daemon rejected, or the CLI exited non-zero
        case unreachable                              // no socket AND no working CLI — nothing applied
    }

    /// Switch the global active profile. Socket first; on an UNREACHABLE daemon fall
    /// back to `clauth <name>` (the CLI does the switch itself). A daemon *rejection*
    /// (`ok:false`) is authoritative and does NOT fall back — falling back there would
    /// fire the daemon-absence path against a present daemon and hide the real error.
    static func switchTo(_ profile: String) -> SwitchDispatch {
        switchTo(profile, send: { sendCommand($0) }, cli: { shellClauth([profile]) })
    }

    /// Testable seam for the fallback POLICY (the feature's headline invariant): a
    /// daemon *rejection* returns `.refused` and must NOT shell — only an UNREACHABLE
    /// daemon (no socket / never delivered) falls back to the CLI. `send`/`cli` are
    /// injected in tests (`cli` asserts it's never reached on a rejection).
    static func switchTo(
        _ profile: String,
        send: ([String: Any]) -> CommandOutcome,
        cli: () -> CommandOutcome
    ) -> SwitchDispatch {
        switch send(["cmd": "switch", "profile": profile]) {
        case .ok:
            return .accepted
        case .daemonError(let code, let message):
            return .refused(code: code, message: message)
        case .unreachable:
            switch cli() {
            case .ok: return .confirmedByCLI
            case .daemonError(let code, let message): return .refused(code: code, message: message)
            case .unreachable: return .unreachable
            }
        }
    }

    /// Force a usage re-fetch (all profiles when `profile` is nil). Socket only —
    /// there's no `clauth refresh` CLI, and a missed manual refresh is harmless
    /// (the daemon refreshes on its own cadence).
    @discardableResult
    static func refresh(_ profile: String?) -> CommandOutcome {
        var cmd: [String: Any] = ["cmd": "refresh"]
        if let profile { cmd["profile"] = profile }
        return sendCommand(cmd)
    }

    // MARK: - Fallback configuration (socket only — needs a running daemon)

    /// Append a profile to the fallback chain.
    @discardableResult
    static func fallbackAdd(_ profile: String) -> CommandOutcome {
        sendCommand(["cmd": "fallback_add", "profile": profile])
    }

    /// Remove a profile from the fallback chain.
    @discardableResult
    static func fallbackRemove(_ profile: String) -> CommandOutcome {
        sendCommand(["cmd": "fallback_remove", "profile": profile])
    }

    /// Move a chain member one slot up (`up: true`) or down.
    @discardableResult
    static func fallbackMove(_ profile: String, up: Bool) -> CommandOutcome {
        sendCommand(["cmd": "fallback_move", "profile": profile, "dir": up ? "up" : "down"])
    }

    /// Set a profile's 5h auto-switch threshold (0…100).
    @discardableResult
    static func setThreshold(_ profile: String, _ value: Int) -> CommandOutcome {
        sendCommand(["cmd": "set_threshold", "profile": profile, "value": value])
    }

    /// Toggle wrap-off mode (switch every account off once the chain is spent).
    @discardableResult
    static func setWrapOff(_ on: Bool) -> CommandOutcome {
        sendCommand(["cmd": "set_wrap_off", "value": on])
    }

    /// Rename a profile. The daemon validates the new name (charset + collision)
    /// synchronously and returns `ok:false` with a reason on rejection; on accept it
    /// renames the profile dir + every reference and re-links the credential mirror if
    /// the account is active (same tokens → the live session is untouched).
    @discardableResult
    static func rename(_ old: String, to new: String) -> CommandOutcome {
        sendCommand(["cmd": "rename", "profile": old, "new_name": new])
    }

    // MARK: - Socket

    /// The transport-level result of one socket round-trip, kept DISTINCT from the
    /// application-level `CommandOutcome` (M1/TECH-11): `sendCommand` must tell "no
    /// daemon" (safe for `switchTo` to shell-fallback) apart from "daemon was there
    /// but went quiet" (must NOT fall back — it likely already applied the command).
    private enum RawReply {
        /// Never connected: no socket file, connect refused, or the command couldn't
        /// even be written (nothing was delivered → safe to fall back).
        case noSocket
        /// Connected AND wrote the command, but got no usable reply before the read
        /// deadline (a switch can hold the daemon's lock across a ~3s Keychain rewrite,
        /// longer than the 2s read timeout). The daemon very likely applied it.
        case connectedNoReply
        /// Got a line back to classify.
        case reply(Data)
    }

    /// Send one newline-delimited JSON command and classify the reply (TECH-11).
    private static func sendCommand(_ command: [String: Any]) -> CommandOutcome {
        guard let payload = try? JSONSerialization.data(withJSONObject: command) else {
            return .unreachable
        }
        switch sendRaw(payload) {
        case .noSocket:
            return .unreachable
        case .connectedNoReply:
            // We reached the daemon and delivered the command; a missing reply is NOT
            // absence. Returning .unreachable here would let switchTo shell `clauth`,
            // DOUBLE-applying an already-applied switch (two Keychain rewrites, two
            // logout storms). Surface it loudly instead — errors must be loud.
            return .daemonError(
                code: "no_reply",
                message: "the daemon didn't confirm in time — it may still be applying the change"
            )
        case .reply(let data):
            return classifyReply(data)
        }
    }

    /// Pure classification of a raw socket reply into a [`CommandOutcome`] (split
    /// from the socket I/O so the ok / reject / unreachable branching is testable):
    /// `ok:true` → `.ok`; `ok:false` → `.daemonError(error_code, error)`; a nil,
    /// non-object, or unparseable reply → `.unreachable` (transport failure).
    static func classifyReply(_ reply: Data?) -> CommandOutcome {
        guard let reply,
              let obj = try? JSONSerialization.jsonObject(with: reply) as? [String: Any]
        else { return .unreachable }
        // Tolerate `"ok": true` OR a truthy `"ok": 1` — the daemon emits a real JSON
        // bool today, but a serializer swap must not turn a success into a spurious
        // error banner (defensive; M6/TECH-11).
        let ok = (obj["ok"] as? Bool) ?? (obj["ok"] as? NSNumber)?.boolValue
        if ok == true { return .ok }
        let code = obj["error_code"] as? String ?? "unknown"
        let message = obj["error"] as? String ?? "the daemon rejected the command"
        return .daemonError(code: code, message: message)
    }

    /// Per-call socket read/write deadline. A switch can hold the daemon's config
    /// lock across a ~3s `/usr/bin/security` Keychain rewrite; without a timeout a
    /// tile tap would block the caller for that whole window (and unboundedly if an
    /// "Always Allow" ACL prompt stalls). 2s bounds it (TECH-10 #25).
    private static let ioTimeout = timeval(tv_sec: 2, tv_usec: 0)
    /// Cap on a single reply so a misbehaving peer can't grow the buffer without
    /// limit; the daemon's replies are tens of bytes.
    private static let maxReplyBytes = 1 << 20

    /// Connect to the unix socket, write one line, read the reply. Distinguishes
    /// never-reached (`.noSocket`) from reached-but-silent (`.connectedNoReply`) so
    /// `sendCommand` can keep a reply-timeout from triggering the shell fallback
    /// (M1/TECH-11). MUST be called off the main actor (see `StatusModel`): the
    /// connect/write/read are blocking, and this is the beach-ball source #25.
    private static func sendRaw(_ payload: Data) -> RawReply {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .noSocket }
        defer { close(fd) }

        // Never let a write to a peer-closed fd raise SIGPIPE (fatal on macOS with
        // no handler) — surface it as an EPIPE return we already treat as failure.
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        // Bound every blocking read/write so a stuck daemon can't wedge the caller.
        var tv = ioTimeout
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString // includes the trailing NUL
        // Refuse rather than silently truncate: a path that doesn't fit sun_path
        // (incl. its NUL) would connect to the WRONG socket (M7/TECH-11). Not
        // reachable for ~/.clauth/clauthd.sock, but truncation is a nasty failure.
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            return .noSocket
        }
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
        guard connected == 0 else { return .noSocket }

        var line = payload
        line.append(0x0A) // newline-delimited
        // Loop until the whole payload is written — a single write() may be partial.
        let wroteAll = line.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return false }
            var sent = 0
            while sent < line.count {
                let n = write(fd, base + sent, line.count - sent)
                if n <= 0 { return false } // EPIPE / timeout / error
                sent += n
            }
            return true
        }
        // A failed write means the command was never delivered — the daemon didn't
        // apply anything, so a shell fallback here is safe (no double-apply).
        guard wroteAll else { return .noSocket }

        // Read until the newline terminator or EOF — one read() may not carry the
        // whole reply. Bounded by maxReplyBytes and the recv timeout.
        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while response.count < maxReplyBytes {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { break } // EOF, timeout, or error
            response.append(contentsOf: chunk[0..<n])
            if chunk[0..<n].contains(0x0A) { break } // reply is one line
        }
        // Reached the daemon and delivered the command; an empty read is "went
        // quiet", NOT absence — sendCommand surfaces it instead of falling back.
        return response.isEmpty ? .connectedNoReply : .reply(response)
    }

    // MARK: - Shell fallback

    /// Spawn `clauth daemon` for the dead-banner [Start daemon] button (design
    /// §3.13). Best-effort — returns whether a binary was found to launch. The
    /// spawn is a CHILD of clauthbar (not fully detached); the durable, supervised
    /// relaunch is the operator's LaunchAgent, so this is an in-session relight, not
    /// a substitute for it.
    @discardableResult
    static func startDaemon() -> Bool {
        guard let bin = clauthBinary() else { return false }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["daemon"]
        do { try proc.run(); return true } catch { return false }
    }

    /// Locate the `clauth` binary: PATH, then the standard cargo bin.
    private static func clauthBinary() -> String? {
        let cargo = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cargo/bin/clauth").path
        for candidate in ["/opt/homebrew/bin/clauth", "/usr/local/bin/clauth", cargo] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Re-authenticate `name` via the self-contained browser OAuth flow
    /// (`clauth login <name>`): opens the browser, binds a loopback listener, PKCE.
    /// Awaits the process through its termination handler — no parked thread while the
    /// (potentially long) browser sign-in runs. On exit 0 the CLI has written fresh
    /// tokens and cleared the account's `auth_broken` flag; the daemon reflects that on
    /// its next status.json write. Works with the daemon up OR down — a pure CLI login,
    /// no socket needed. The caller's in-flight window is bounded by clauth's own
    /// `LOGIN_TIMEOUT_SECS` (180s in `oauth_login.rs`), so no client-side timeout is
    /// needed. Exit 0 → `.ok`; non-zero / timed-out → `.daemonError`; no binary → `.unreachable`.
    static func reauth(_ name: String) async -> CommandOutcome {
        guard let bin = clauthBinary() else { return .unreachable }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["login", name]
        return await withCheckedContinuation { (cont: CheckedContinuation<CommandOutcome, Never>) in
            proc.terminationHandler = { p in
                let status = p.terminationStatus
                cont.resume(returning: status == 0
                    ? .ok
                    : .daemonError(code: "cli_failed", message: "clauth login exited \(status)"))
            }
            do {
                try proc.run()
            } catch {
                // Never started → the termination handler won't fire; resume here once.
                proc.terminationHandler = nil
                cont.resume(returning: .daemonError(
                    code: "cli_failed", message: "could not run clauth: \(error.localizedDescription)"))
            }
        }
    }

    /// Run `clauth <args>` and report its outcome by exit status (TECH-11). Blocking
    /// (waits for exit) — only reached from the off-main-actor command path, and a
    /// switch's Keychain write is a couple seconds at most. Exit 0 → `.ok`; non-zero
    /// or spawn failure → `.daemonError`; no binary at all → `.unreachable`.
    private static func shellClauth(_ args: [String]) -> CommandOutcome {
        guard let bin = clauthBinary() else {
            return .unreachable
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = args
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
                ? .ok
                : .daemonError(code: "cli_failed", message: "clauth exited \(proc.terminationStatus)")
        } catch {
            return .daemonError(code: "cli_failed", message: "could not run clauth: \(error.localizedDescription)")
        }
    }
}
