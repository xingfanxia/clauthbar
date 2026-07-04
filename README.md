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

The menu-bar title shows the **active account name + 5h %** (so the active
account is unmistakable at a glance). Clicking it opens a translucent SwiftUI
panel (`MenuBarExtra(.window)`, matching CodexBar's look):

- an **account switcher** — a tile per account, the active one filled in the
  terracotta accent; click a tile to switch.
- the active account's **usage** — Session (5h) / Weekly (7d) / Fable meters,
  each a thin rounded bar with "% used" and a "resets in …" hint (third-party
  api-key accounts show an availability dot instead).
- the **fallback chain** — the ordered chain as chips joined by arrows, the
  armed member (the one auto-switch will rotate away from) glowing in the accent,
  plus the wrap-off state.
- a collapsible **Configure** section to edit the chain without leaving the bar —
  per-account threshold menu, move up/down, add/remove, and a wrap-off toggle.
- **Refresh now** forces a re-fetch; **Quit** exits.

Configuration drives the daemon's control socket (`clauthd.sock`), so a running
`clauth daemon` is required to edit (display works off `status.json` alone).

## Build a real app

```sh
Scripts/package_app.sh        # → build/clauthbar.app (LSUIElement, ad-hoc signed)
open build/clauthbar.app      # run it, or:
cp -R build/clauthbar.app /Applications/   # then add to System Settings → Login Items
```

## Status

Implemented:

- **SwiftUI `MenuBarExtra(.window)`** translucent panel (matching CodexBar),
  light/dark aware — replaces the earlier `NSMenu` + block-character (█░) bars.
- Menu-bar title: active account **name + 5h %** ("—" when never fetched).
- **Account-switcher tiles** (active filled in the terracotta accent) — one-click
  switch (socket, `clauth <name>` shell fallback).
- Active account **usage meters**: Session (5h) / Weekly (7d) / Fable, each a thin
  rounded bar with "% used" + "resets in …" (days for long windows). Third-party
  api-key accounts show an availability dot instead. Colored from clauth's TUI
  palette (Catppuccin Mocha).
- **Fallback-chain strip** — chips joined by arrows, the armed member glowing,
  wrap-off state.
- Inline **Configure** disclosure — per-account threshold menu, move up/down,
  add/remove, and a wrap-off pill, driving the daemon's config socket commands.
- Refresh now + Quit.
- Runs as an accessory app (no Dock icon); packaged as an ad-hoc-signed `.app`.
- **`--snapshot <path>`** renders the panel to a PNG headlessly (a design-review
  aid; not part of the normal run).

Deferred:

- **S7 (partial)** — `.app` bundling done (`Scripts/package_app.sh`, ad-hoc
  signed). Still deferred: dedicated Settings window, Sparkle auto-update,
  Developer-ID signing + notarization, Homebrew cask.
- `Add Account…` (→ `clauth login`), custom menu-bar meter glyph.

## Architecture

| File | Role |
|---|---|
| `DaemonStatus.swift` | `Codable` mirror of `status.json` (schema 1) + window accessors |
| `DaemonClient.swift` | read `status.json`; switch/refresh/config over the socket (shell fallback) |
| `Theme.swift` | SwiftUI color tokens + `UsageBar` + `usageColor`/`resetHint` |
| `StatusModel.swift` | `@MainActor ObservableObject` — polls `status.json`, fires daemon commands |
| `PanelView.swift` | the panel: switcher tiles, usage meters, fallback-chain strip, actions |
| `ConfigView.swift` | inline `Configure` disclosure (threshold / reorder / add-remove / wrap-off) |
| `AppMain.swift` | `@main` — `MenuBarExtra(.window)` app + `--snapshot` render mode |
| `Snapshot.swift` | headless `ImageRenderer` panel→PNG harness (design-review aid) |

The full design (the `MenuBarExtra(.window)` decision, the visual spec, and the
daemon IPC contract) lives in the clauth repo at `docs/clauthbar/DESIGN.md`.
