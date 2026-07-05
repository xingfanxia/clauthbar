# clauthbar

A native macOS menu-bar companion for [clauth](https://github.com/xingfanxia/clauth)
— glance at every Claude Code account's 5-hour usage, see what auto-switch will do
next, and switch deliberately when you want to, without opening the TUI.

The panel is **inspect-first** ("Preflight"): a single click on any account
**inspects** it (pure view state, zero daemon traffic) — browse freely — while
switching is a distinct verb in the detail card, guarded so a Keychain rewrite
can't silently strand a live Claude session.

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
  clauthbar reads the daemon's liveness distinctly: if the daemon was never
  started (no `status.json`), the menu shows **"clauth daemon not running"**; if
  it wrote the file and then died, the panel keeps the last data under a loud
  **"Daemon stalled — data from HH:MM"** banner (so a frozen % never reads as
  current) and the menu-bar glyph dims; if the daemon's `status.json` schema is
  newer than this build understands, it shows **"clauthbar out of date"** rather
  than a misleading "not running".

## Run (development)

```sh
swift run          # launches as a menu-bar accessory (no Dock icon)
```

The menu-bar title shows the **active account name + 5h %** (so the active
account is unmistakable at a glance), with all other state encoded in the SF Symbol
shape — a near-threshold dot, a switch-in-flight ellipsis, a rotation glyph, a
`bolt.slash` when auto-switch is disarmed, or a warning triangle + frozen age when
the daemon dies (the % is withheld rather than shown stale). Clicking it opens a
translucent SwiftUI panel (`MenuBarExtra(.window)`, matching CodexBar's look), laid
out top to bottom as **status strip → account list → detail card → chain rail →
actions**:

- a **status strip** — the single place exceptional truth appears, priority-ordered:
  a dead-daemon banner (with a one-click **Start daemon**) > the switch lifecycle
  (arm / switching… / switched / failed) > a wrap-off "all off, resumes when a
  window resets" card > a zero-armed "auto-switch is idle" warning > otherwise the
  **forecast sentence** ("Watching xfx — would switch to cl-ax at 95% · now 62%"),
  a pure mirror of the daemon's own chain-walk.
- the **account list** — one row per account in **file order (rows never reorder)**;
  single click **inspects**. Each row leads with a full-width 5h bar carrying a tick
  at that account's own auto-switch threshold, then half-width 7d / Fable bars, plus
  badges (a sapphire "⚡ watching" chip when armed, a danger "spent"/"week spent"/"5h
  spent" pill with a muted name when a window is at its cap, last-resort sink flag,
  in-use, login-expired). Third-party api-key accounts show an availability dot instead
  of %-bars.
- the **detail card** for the inspected account — its three windows with reset times,
  a forecast-driven chain-membership line, and **the one switch surface**: a static
  "Active account" for the current one, a disabled login hint for an expired one, or
  a **Switch** verb. If the active account has a live Claude session, the first click
  **arms** ("Confirm — live session on …") and a second within 5s fires; with the
  daemon down it becomes "Switch via CLI", confirmed by exit code.
- the **chain rail** — the ordered fallback chain as chips joined by arrows, the armed
  member glowing in sapphire, plus the "when spent" outcome. **Edit** opens the
  inline Configure disclosure.
- **actions** — Refresh usage, Start at login, Quit (the daemon keeps running).

**Two config surfaces, no Settings window:** a native **right-click context menu** on
every row (switch / refresh / add–remove / move / "Leave chain at ▸" preset submenu /
copy name) for fast edits, and the inline **Configure** disclosure as the canonical
editor (per-account threshold, reorder, add/remove, and the wrap-off setting as a
plain-language radio). Removing an armed member asks first. Both drive the daemon's
control socket (`clauthd.sock`), so a running `clauth daemon` is required to edit
(display works off `status.json` alone).

## Build a real app

```sh
Scripts/package_app.sh        # → build/clauthbar.app (LSUIElement, ad-hoc signed)
open build/clauthbar.app      # run it, or:
cp -R build/clauthbar.app /Applications/   # install it
```

**Autostart:** on first launch the app registers itself as a login item via
`SMAppService`, so the panel comes back after a reboot (the daemon already does,
via its LaunchAgent). Toggle it off any time with **Start at login** in the panel
— no manual System Settings step. A single-instance guard means launching a
second copy just bows out, and the running one keeps its single menu-bar item.

## Status

Implemented (the CBAR-4 "Preflight" redesign):

- **SwiftUI `MenuBarExtra(.window)`** translucent panel (matching CodexBar),
  light/dark aware — replaces the earlier `NSMenu` + block-character (█░) bars.
- **Menu-bar label ladder** — active account **name + 5h %**, with all other state
  in the SF Symbol shape (never color, which the menu bar flattens): near-threshold
  dot, switch-in-flight ellipsis, rotation glyph, `bolt.slash` when disarmed, and a
  warning triangle + frozen age (% withheld) when the daemon dies.
- **Inspect-first account list** — file-order rows (never reorder); single click
  inspects (zero daemon traffic). 5h-dominant row anatomy: full-width 5h bar with an
  in-track threshold tick, half-width 7d / Fable bars, and badges ("⚡ watching" when
  armed / "spent" pill + muted name when a window is capped / sink / in-use /
  login-expired). Third-party accounts show an availability dot.
- **Detail card + one switch verb** — the inspected account's three windows, a
  forecast-driven chain line, and a deliberate Switch with the **live-session
  arm-confirm** guard and a **CLI fallback** (confirmed by exit code) when the daemon
  is down.
- **Truthfulness engines** (pure, unit-tested): a **forecast** mirror of the daemon's
  `fallback.rs` chain-walk (line-pinned, fixture-tested — never a naive position+1),
  a graded **liveness ladder** (live < 5s / syncing < 15s / dead) on the 1s write
  cadence, a **switch state machine** (arm / pending / confirmed / failed), and the
  **menu-bar label ladder** — plus a **rotation heartbeat** that flashes "rotated to
  X" when auto-switch fires unattended.
- **Two config surfaces** — a native right-click context menu on every row, and the
  inline **Configure** disclosure (per-account threshold, reorder, add/remove, and a
  plain-language wrap-off radio; armed-member removal asks first). Both drive the
  daemon's config socket, with an "Applying…" shimmer and loud revert-on-rejection.
- **Distinct daemon-liveness states** — never-started (empty state) vs frozen (dead
  banner over dimmed last-known data, % withheld) vs schema-too-new (out-of-date).
- Runs as an accessory app (no Dock icon); packaged as an ad-hoc-signed `.app`.
- **`--snapshot=<variant>`** renders any canonical state to a PNG headlessly
  (`default` / `inspecting` / `mid-switch` / `daemon-dead` / `config` /
  `remove-confirm`; a design-review aid, not part of the normal run).

Deferred:

- **Packaging (partial)** — `.app` bundling done (`Scripts/package_app.sh`, ad-hoc
  signed). Still deferred: Sparkle auto-update, Developer-ID signing + notarization,
  Homebrew cask.
- `Add Account…` (→ `clauth login`), chip-click-to-inspect on the chain rail.

## Architecture

| File | Role |
|---|---|
| `DaemonStatus.swift` | `Codable` mirror of `status.json` (schema 1) + window/auth accessors |
| `Exhaustion.swift` | pure `ProfileStatus.spentTag` — the one definition of "a window is at its cap" |
| `DaemonClient.swift` | read `status.json`; switch/refresh/config over the socket (shell fallback) |
| `Theme.swift` | color roles (one meaning per hue) + `UsageBar` (threshold tick) + `usageColor`/`resetHint` |
| `ForecastEngine.swift` | pure mirror of `fallback.rs::next_target` — the "would switch to X" prediction |
| `LivenessLadder.swift` | graded freshness (live / syncing / dead) on the 1s write cadence |
| `SwitchMachine.swift` | pure switch-lifecycle reducer (arm / pending / confirmed / failed) |
| `MenuBarLabelLadder.swift` | pure menu-bar label spec — all state in SF Symbol shape |
| `ChainEdit.swift` | shared config vocabulary (presets, legends, removal gate) — one source of truth |
| `StatusModel.swift` | `@MainActor ObservableObject` — polls `status.json`, drives switch/config effects + inspection |
| `PanelView.swift` | panel orchestration: status strip → account list → detail card → chain rail → actions |
| `StatusStrip.swift` | the single exception surface (dead banner / switch lifecycle / wrap-off / zero-armed / forecast) |
| `AccountRow.swift` | one file-order account row + its right-click context menu |
| `AccountContextMenu.swift` | the row context menu (fast-path chain edits) |
| `DetailCard.swift` | the inspected account's windows, chain line, and the one switch surface |
| `ConfigView.swift` | inline `Configure` disclosure (threshold / reorder / add-remove / wrap-off radio) |
| `AppMain.swift` | `@main` — `MenuBarExtra(.window)` app + `--snapshot` render mode |
| `Snapshot.swift` | headless `ImageRenderer` panel→PNG harness (design-review aid) |

The visual spec is **`docs/clauthbar/CBAR-4-DESIGN.md`** in the clauth repo (the
binding "Preflight" design); `docs/clauthbar/DESIGN.md` there covers the original
`MenuBarExtra(.window)` decision and the daemon IPC contract.
