# clauthbar

A native macOS menu-bar companion for [clauth](https://github.com/xingfanxia/clauth)
— glance at every Claude Code account's 5-hour usage and switch with one click,
without opening the TUI.

clauthbar is a thin UI over clauth's daemon: it reads `~/.clauth/status.json`
(written every tick by `clauth daemon`) for display and drives
`~/.clauth/clauthd.sock` (with a `clauth <name>` shell fallback) to switch. It
owns no credentials and runs no network of its own.

## Requirements

- macOS 14+ (Sonoma), Swift 6 toolchain (Xcode 16+).
- `clauth` installed and the daemon running:
  ```sh
  # from the clauth repo
  dist/macos/daemon-install.sh      # LaunchAgent (runs at login), or:
  clauth daemon                     # foreground, for a quick try
  ```
  Without a running daemon, `status.json` goes stale and the menu shows
  "clauth daemon not running".

## Run (development)

```sh
swift run          # launches as a menu-bar accessory (no Dock icon)
```

A gauge glyph appears in the menu bar showing the active account's 5h %. The
dropdown lists every account — active pinned on top with an orange dot — each
with its plan tier, a 5h usage bar, and (for fallback-chain members) an
`⚡ #position @threshold` armed hint. Click an account to switch; "Refresh now"
forces a re-fetch; "Quit" exits.

## Build a real app

```sh
Scripts/package_app.sh        # → build/clauthbar.app (LSUIElement, ad-hoc signed)
open build/clauthbar.app      # run it, or:
cp -R build/clauthbar.app /Applications/   # then add to System Settings → Login Items
```

## Status (MVP)

Implemented (Phase S1–S3, S5–S6 of `clauth/docs/clauthbar/DESIGN.md`):

- `NSStatusItem` + `NSMenu`, rebuilt from `status.json` on open.
- Per-account rows: active dot, tier badge, 5h bar + %, fallback/armed hint,
  staleness cue — colored from clauth's TUI palette (Catppuccin Mocha).
- One-click switch (socket, `clauth <name>` fallback) + Refresh + Quit.
- Runs as an accessory app (no Dock icon).

Deferred:

- **S4** — the polished hosted-SwiftUI card (real `Canvas` usage bars via
  `NSHostingView` + `intrinsicContentSize`). The MVP draws bars with block
  characters in native menu items instead.
- **S7 (partial)** — `.app` bundling done (`Scripts/package_app.sh`, ad-hoc
  signed). Still deferred: Settings window, Sparkle auto-update, Developer-ID
  signing + notarization, Homebrew cask.
- 7d / per-model windows, `Add Account…` (→ `clauth login`), custom meter glyph.

## Architecture

| File | Role |
|---|---|
| `DaemonStatus.swift` | `Codable` mirror of `status.json` (schema 1) |
| `DaemonClient.swift` | read `status.json`; `switch`/`refresh` over the socket (shell fallback) |
| `Theme.swift` | palette + `util_color`/`health_color` + text usage bar |
| `StatusItemController.swift` | the `NSStatusItem` + `NSMenu` (delegate rebuild + actions) |
| `AppMain.swift` | `@main` accessory app shell |

The full design (why `NSMenu` over `MenuBarExtra`, the `intrinsicContentSize`
trick, the visual spec, and the daemon IPC contract) lives in the clauth repo at
`docs/clauthbar/DESIGN.md`.
