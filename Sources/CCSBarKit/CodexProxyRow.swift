import SwiftUI

/// The codex page's "Proxy mode" switch (PROXY-1): one row under the strip,
/// mirroring the panel's "Start at login" Toggle idiom. State is re-read from
/// disk on every panel open — if zylos (the config's other manager) reverts
/// the edit, the switch visibly snaps back instead of lying.
struct CodexProxyRow: View {
    @State private var routed = false
    @State private var serving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: Binding(get: { routed }, set: { setRouting($0) })) {
                HStack(spacing: 8) {
                    Image(systemName: "network").frame(width: 16)
                    Text("Proxy mode").font(.body)
                    Spacer()
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(captionStyle)
                }
            }
            .toggleStyle(.switch).controlSize(.mini)
            if let error {
                Text(error).font(.caption2).foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .help(
            """
            Route every codex session through clauth's local proxy (port 4517).

            ON — in-session hot-swap: the account is injected per request, so a \
            clauth account switch applies to RUNNING codex sessions instantly, and \
            a rate-limited request rotates to the next pool account and replays \
            before codex notices.
            OFF — codex talks to OpenAI directly; account switches need a codex \
            restart to take effect.

            Takes effect for newly started sessions (a running session keeps the \
            provider it launched with; `codex --profile proxy` opts one in \
            manually). If the switch snaps back OFF by itself, zylos — which also \
            manages ~/.codex/config.toml — reverted the edit; arbitrate there.
            """
        )
        .onAppear(perform: refresh)
    }

    private var caption: String {
        if routed { return serving ? "serving :4517" : "proxy not running" }
        return serving ? "direct · proxy idle" : "direct"
    }

    private var captionStyle: Color {
        if routed && !serving { return Theme.warning }
        return .secondary
    }

    private func refresh() {
        routed = CodexProxyMode.routed()
        error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let up = CodexProxyMode.serving()
            DispatchQueue.main.async { serving = up }
        }
    }

    private func setRouting(_ on: Bool) {
        do {
            try CodexProxyMode.apply(on: on)
            routed = on
            error = nil
        } catch {
            self.error = "config.toml edit failed: \(error.localizedDescription)"
        }
        // Re-probe: ON may have just bootstrapped the LaunchAgent.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.6) {
            let up = CodexProxyMode.serving()
            DispatchQueue.main.async { serving = up }
        }
    }
}
