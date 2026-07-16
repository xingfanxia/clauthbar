# TABS-1 — Provider tab switch + codex management parity

> **STATUS: SHIPPED 2026-07-16.** Plan-reviewed (4 judges + refute: 13 confirmed
> findings folded in pre-build), implemented, adversarially code-reviewed (4
> dimensions + refute: 4 confirmed + 6 LOW, all fixed; the switch-harness HIGH
> re-verified CLEAN on every path). 199/199 tests green.

**Objective (1 sentence):** Restructure the ccsbar panel into codexbar-style provider
tabs (Overview / Claude / Codex) and bring codex account **management** to parity with
claude — switch (with real confirmation), refresh, reauth, rename, add, and chain
editing — all against the daemon contract that already routes per-harness.

**Reference design:** AX-supplied codexbar screenshot — a top tab bar (grid "Overview"
+ per-provider tabs with brand glyph, label, and a small usage-colored underline bar),
then the selected provider's page (account row: name → email, plan tier, "Updated 2m
ago"). Gemini appears in codexbar; clauth has no gemini harness, so tabs are
**Overview / Claude / Codex** only (add a tab when a harness exists — no dead chrome).

**Zero clauth changes.** Verified daemon-side (2026-07-16):

| Contract fact | Where |
|---|---|
| Socket `switch/refresh/rename/fallback_*/set_threshold/set_last_resort` are harness-agnostic; `switch` routes by the profile's own harness | `clauth src/daemon/socket.rs:194` |
| `fallback_add` on a codex profile joins `codex_fallback_chain` (per-harness route, homogeneity by construction) | `fallback_config.rs:52` |
| Per-profile `fallback` block (position/threshold/armed/last_resort) is computed against **its harness's** chain | `status_json.rs:78` |
| Codex walk honors per-member `threshold`, `last_resort` sink pass, and the chain-global weekly line; **no wrap-off** (claude-only concept) | `fallback.rs:829-868` |
| `auth_status` published for codex profiles too | `status_json.rs:336` |
| `active_codex_profile` + `codex_fallback_chain` top-level; per-profile `harness`, `codex_snapshot_at`, `codex_rate_limit_reached` | consumed in `DaemonStatus.swift` already |
| `pending_switch` publishes the single ranked winner across both harnesses (a codex pending shows when it's the winner) | `daemon/mod.rs:630` |
| CLI add/reauth for codex: `clauth login <name> --codex` (capture live login, instant, no browser) and `clauth login <name> --codex --browser` (PKCE mint); `--new` composes for race-proof CREATE | `main.rs parse_login_args` |
| Live daemon reality: clauth 0.11.0, **zero codex profiles yet** → the Codex tab's EMPTY STATE is the actual front door | `~/.clauth/status.json` |

## Known ccsbar gaps this closes

1. **Codex switch never confirms** — `observeSwitch`/`armPendingDeadline` watch
   `activeProfile`; a codex switch lands in `activeCodexProfile`, so today a GUI
   codex switch would false-fail after the pending timeout. (Latent bug: no codex
   profiles exist yet, so never hit.)
2. **Reauth/Add are claude-only** — `DaemonClient.login` never passes `--codex`;
   context-menu reauth and DetailCard reauth surface gate on `provider == "anthropic"`.
3. **Codex chain rail unbuilt** — `codexFallbackChain` decoded but unused (documented
   DEFERRED in `DaemonStatus.swift`).
4. **Settle predicates claude-chain-only** — `fallbackAdd`'s `expecting` checks
   `fallbackChain.contains` only; a codex add would settle late (falls to the 4s poll).
5. **Context-menu "Move down" bound** uses `status.fallbackChain.count` for all rows.
6. **`chainLine(for:)`** keys off `fallbackChain.firstIndex` → nil for codex members.
7. **`expectedClauthVersion` = "0.7.4"** vs live daemon 0.11.0 → the skew badge
   misfires constantly today. Bump to 0.11.0 (drift fix, file already touched).

## Design

### Tab bar (new `ProviderTabs.swift`)

- `enum ProviderTab: String, CaseIterable { case overview, claude, codex }` +
  `ProviderTabBar` view at the very top of the panel (above everything, mirroring
  codexbar). Three equal-width segments: SF Symbol + label
  (`square.grid.2x2` Overview · `sparkle` Claude · `hexagon` Codex — no brand
  bitmaps; SF glyphs keep it native and license-clean).
- Selected segment: filled rounded-rect in `Theme.accent.opacity(0.18)` +
  accent-tinted label (terracotta = active identity, per Theme §5). Unselected:
  secondary label, hover wash `0.045` (AccountRow's quiet-hover idiom).
- **Usage underline** (the codexbar detail AX circled): a 3pt mini bar under the
  Claude and Codex labels showing that harness's ACTIVE account 5h % in
  `Theme.usageColor` — a glance answers "which agent is near its limit" without
  entering the tab. Hidden when the harness has no active account. Overview gets none.
- Selection persists via `@AppStorage("providerTab")`; first-run default `overview`.
  Switching tabs calls `resetInspection()` (inspection is per-page state).
- Keyboard: `⌘1/⌘2/⌘3` select tabs.
- A11y: the bar is a `Picker`-semantics group; each segment
  `accessibilityLabel("<name> tab")` + `.isSelected` trait; underline % is decorative
  (the row/detail read the real numbers).

### Page composition (PanelView becomes a router)

Global chrome (all tabs): command-error banner, removal-confirm banner, reauth
banner, rename banner, add banner — they are model-global states and must be visible
wherever triggered. Then the tab bar. Then per-tab content. Then the shared actions
section (Refresh usage / Start at login / Quit) — global, bottom, unchanged.

- **Overview** (new `OverviewPage.swift`): one summary card per harness: glyph +
  "Claude"/"Codex", active account name + email (middle-truncated), tier,
  "updated Xs ago", 5h + 7d mini bars. Tapping a card jumps to that tab. Codex card
  with no codex profiles: "No codex accounts yet — set up in the Codex tab ›".
  Claude card with none: same shape. No chain editing, no switch verbs here —
  Overview is read-only glance + navigation.
- **Claude** page: today's panel body EXACTLY, filtered to claude profiles:
  `TokensStrip` (plan-review correction: tokens.json is **Claude Code telemetry**,
  not cross-harness — it stays with the Claude page, preserving the claude power
  user's current experience; the `tokens` snapshot variant pins `.claude`), forecast
  `StatusStrip`, accounts list (claude rows only, harness pill hidden — the tab
  scopes it), `DetailCard`, chain rail (claude chain), `ConfigView`, add-account row
  (claude browser login). Behavior byte-identical for claude flows. Zero claude
  profiles (fresh install): warm empty state symmetric to the codex door
  ("No Claude accounts yet" + Sign in with browser…).
- **Codex** page: codex strip (see below), codex accounts list, `DetailCard` (works
  already — windows path + email), codex chain rail (reads `codexFallbackChain`),
  codex `ConfigView` (membership/order/threshold/last-resort; NO weekly row, NO
  wrap-off radio — codex walk has no wrap-off, and the weekly line is a shared knob
  edited from the Claude page), add-codex-account row.
- **Codex strip** (new, small): active codex account + "captured Xm ago"
  (`codexSnapshotAt` — credential age, distinct from usage freshness) + rate-limit
  state from `codexRateLimitReached`: `"primary"` → "5h window hit — resets …",
  `"secondary"` → "weekly window hit — resets …" (two-window signal, fallback.rs:765).
  **No client-side next-target prediction** (plan-review: it would re-create the
  drift-prone forecast mirror clauth deliberately replaced with a daemon-published
  forecast; the daemon publishes no codex forecast today → show state, not
  prediction; daemon-side codex forecast is a logged follow-up). The strip also
  hosts the codex switch lifecycle line (see switch section).
- **Codex empty state** (the actual first-run door): warm, two paths, primary action:
  "No codex accounts yet." + `[Capture current codex login]` (creates a profile from
  `~/.codex/auth.json` — instant, works because AX is already signed in) and
  `[Sign in with browser…]` (PKCE). Both route through the add-banner with the name
  field; capture runs `clauth login <name> --codex --new`, browser adds `--browser`.

### Interaction state coverage (per new surface)

| Surface | Loading | Empty | Error | Success | Frozen (daemon dead) |
|---|---|---|---|---|---|
| Tab bar | n/a (pure state) | always renders | n/a | underline tracks active % | dims with panel; still switchable (view state) |
| Overview card | — | "No <harness> accounts yet …›" | banner (global) | live numbers + updated stamp | "as of Xm ago" stamp, 60% dim |
| Codex add (capture) | button → "Capturing…" (in-flight guard shared with reauth) | — | loud banner w/ exact CLI hint (`clauth login <name> --codex`) | inspect newcomer + refresh nudge | allowed (pure CLI, daemon-down OK) |
| Codex add (browser) | "Opening browser to sign in…" global banner | — | same pattern as claude add | same | allowed |
| Codex chain rail | — | "None — add accounts in Configure" | rejected edits → banner | chips + when-spent summary | dim |
| Codex switch | no arm (nothing to protect — see switch section) → "Switching…" | — | timeout → failed banner | confirmed via `activeCodexProfile` observation | "Switch via CLI" title |

### Harness-aware switch machine (correctness core)

`SwitchMachine` (pure) is untouched. `StatusModel` effects become harness-aware:

- `switchTo(name)`: resolve target's harness from `listProfiles` (unknown name →
  dispatch anyway, daemon's rejection is authoritative; observe claude slot — the
  failure surfaces loudly either way, never a silent claude default that hides an
  error).
- **Codex switches never arm** (plan-review HIGH): `status.json`'s
  `has_live_session` is computed by claude-only `runtime::has_live_session`
  (status_json.rs:335 has no `is_codex` branch) — always `false` for codex — AND
  `clauth start` codex sessions are isolated (own CODEX_HOME), so a switch to the
  shared `~/.codex/auth.json` doesn't strand them anyway. Honest zero-clauth-change
  position: codex `switchTo` goes straight to pending (`currentHasLiveSession:
  false` by construction), and the codex `.help` copy reads "Rewrites
  ~/.codex/auth.json at the session boundary — isolated codex sessions (clauth
  start) are unaffected." Never claim the confirm protects codex sessions.
- `observeSwitch`/`armPendingDeadline`: observe `activeName(for: harness)` — a new
  pure helper `DaemonStatus.activeName(for harness)` returning `activeProfile` or
  `activeCodexProfile`. Codex switches now confirm.
- **Switch lifecycle renders on the harness-matched strip** (plan-review HIGH): the
  single `switchPhase` slot stays (one switch at a time is the existing invariant),
  but its target's harness routes the lifecycle row — `StatusStrip` (Claude page)
  shows it only for a claude target; `CodexStrip` shows it for a codex target,
  naming the codex active. No cross-tab bleed, no wrong-active wording.
- `DetailCard` arming title names the harness-matched current active.
- `maybeNotify`: codex rotation notification stays DEFERRED (daemon publishes no
  codex switch provenance) — comment stands.

### Model/data plumbing

- **Tab state** (plan-review HIGH): `@Published var tab: ProviderTab` on
  `StatusModel` with manual `UserDefaults` persistence (read in `init`, write in
  `didSet`) — NOT `@AppStorage` (a DynamicProperty inside an ObservableObject never
  publishes → the panel wouldn't re-render). The preview/snapshot init takes a
  `tab:` parameter so snapshot variants can inject a page.
- **StatusModel decomposition** (plan-review MED — file is 914 LOC, 83% over the
  500-LOC hard-debt gate): split into same-type extension files in the same change —
  `StatusModel.swift` (core: polling, liveness, derived display), 
  `StatusModelSwitch.swift` (switch-machine effects), `StatusModelActions.swift`
  (login/add/rename/removal/config commands + settle). Each file lands ≤ ~400 LOC;
  no behavior change in the move (tests stay green across the split commit).
- `StatusModel`: `claudeProfiles`/`codexProfiles` filters; `profiles(for tab)`;
  `chain(for harness)`; settle predicates check the union
  (`fallbackChain + codexFallbackChain`); `chainLine(for:)` uses
  `p.fallback.position` — **1-based already** (status_json.rs emits `pos + 1`), so
  the ordinal is `ordinal(position)` with NO `+ 1` (plan-review MED: a literal swap
  keeping `+1` would shift every ordinal on BOTH harnesses; unit test pins
  "1st in chain" for the head); `addAccount(name, codex:)` + `reauth(name, codex:)`
  thread the flag; inspected-fallback resolves within the current tab's harness.
- **Login in-flight state is mode-aware** (plan-review MED): `reauthInFlight:
  String?` becomes `loginInFlight: LoginFlight?` (`{name, mode}` where mode ∈
  `.browser`/`.capture`). The global banner copy branches: browser → "Signing in to
  X — finish in your browser…", capture → "Capturing current codex login into X…".
  The single-login-at-a-time guard is unchanged (one flight at a time across all
  flows).
- `DaemonClient.login(name, newOnly:, codex:, browser:)` with a **pure**
  `loginArgs(...) -> [String]` builder (unit-tested): claude → `["login", "--new"?,
  name]`; codex capture → `+ ["--codex"]`; codex browser → `+ ["--codex",
  "--browser"]`.
- `AccountContextMenu`: reauth item for codex (`p.isCodex` → codex flags; titles
  "Re-capture codex login" / "Sign in again (browser)"); "Move down" bound uses
  `chain(for: p.harness).count`; threshold + last-resort items stay (codex walk
  honors both).
- `ConfigView(harness:)`: profiles + chain filtered; weekly + wrap-off sections
  rendered only for `.claude`.
- `ChainRail(harness:)`: codex rail's when-spent summary uses codex copy (rotates at
  the session boundary; stays put when all limited) — never the claude wrap-off
  sentence (codex has no wrap-off).
- `DetailCard`: the "Pick another account above to switch" hint gates on the
  **harness-scoped** peer count (not global `listProfiles.count`) so a single-codex
  page never points at rows it doesn't show.
- `AccountRow(showHarnessTag:)`: pill hidden inside harness-scoped tabs; shown in
  any mixed context (Overview cards don't use AccountRow).

### Fixtures / snapshots / tests

- `Fixtures/status.json`: add `codex-2` (non-active, chain #2, own email/tier) so the
  codex chain rail renders with 2 chips; **give BOTH codex members real `fallback`
  blocks** (`{position, threshold, armed, last_resort}` — the daemon emits one for
  every chain member of its harness; codex-1 currently lacks it, which would blank
  the rail's armed chip and `chainLine`); bump the fixture's `clauth_version` to
  0.11.0 **in the same change as** the `expectedClauthVersion` bump (else every
  non-skew snapshot grows a spurious skew badge). Update the two
  `DaemonStatusTests` fixture-shape assertions (profile count, codex chain) in the
  same commit — the fixture contract legitimately grew.
- `Snapshot.swift` variants: `tab-overview`, `tab-codex`, `codex-empty` (fixture with
  codex profiles stripped — proves the empty-state door), plus existing variants
  (incl. `tokens`) pin `.claude` so legacy renders stay comparable.
- Tests (pure-logic first, TDD): `loginArgs` composition; `activeName(for:)`;
  harness-aware observe confirm (feed `.observedActive` from the codex slot);
  settle-predicate union; `chainLine` codex copy via `fallback.position`;
  tab filtering; move-bound helper; ConfigView ordering with codex inputs
  (`ChainEdit.chainOrdered` reuse); fixture decode with codex-2; empty-state
  presence logic.

### Files (≈13 ccsbar, 0 clauth code)

New: `ProviderTabs.swift`, `OverviewPage.swift`, `CodexStrip.swift`,
`ChainRail.swift` (chain section extracted from PanelView, harness-scoped).
Modified: `PanelView.swift` (router; sheds chain section — stays under LOC gate),
`StatusModel.swift`, `DaemonClient.swift`, `DetailCard.swift`,
`AccountContextMenu.swift`, `ConfigView.swift`, `AccountRow.swift`,
`Snapshot.swift`, `Fixtures/status.json`, tests.
Docs (in-flight sync): ccsbar `README.md`; `DaemonStatus.swift` DEFERRED comments;
clauth `docs/ccsbar/DESIGN.md` + `docs/codex-support/PLAN.md` consumption notes;
project memory.

## Acceptance criteria

1. `swift test` green (existing 181 + new); no new warnings.
2. Snapshot renders for `tab-overview` / `tab-claude(default legacy)` / `tab-codex` /
   `codex-empty` × dark+light — visually verified against the codexbar reference
   (tab anatomy: glyph, label, usage underline, selected fill).
3. A codex profile can be: added (capture AND browser paths spawn the right CLI args
   — arg-builder test), switched (confirm observes `activeCodexProfile` — machine
   test), refreshed, renamed, reauthed, chain-edited (add/remove/move/threshold/
   last-resort with codex-chain bounds) — all through the existing daemon socket.
4. Claude flows behavior-identical (claude tab = today's panel body incl.
   TokensStrip; existing tests green — only the two fixture-shape assertions grow
   with the fixture, no behavior assertion changes).
5. Skew badge silent against clauth 0.11.0 (constant + fixture bumped together).
6. Live acceptance (AX-manual, per security constraints): real codex capture/login
   clicks, real codex switch — handed over as exact steps, never run by the agent.

## NOT in scope (deferred, logged)

- Menu-bar label codex rung (label stays claude-% — separate milestone).
- Codex rotation notifications (needs daemon-side switch provenance for codex).
- Gemini tab (no harness in clauth).
- Weekly-line editing from the Codex page (shared knob lives on Claude page).
- Daemon-published codex forecast (`forecast` field is claude-only; a truthful
  codex next-target line needs the daemon to publish its own
  `next_codex_auto_switch_target` result — clauth follow-up, not a client mirror).
- Codex arm-confirm (correctly absent, not deferred: `has_live_session` is
  claude-only in status.json AND isolated codex starts aren't stranded by a switch
  — there is nothing for a confirm to protect; would need clauth-side
  `has_live_codex_session` publication to ever exist).

## Rollback

`git revert` of the ccsbar commit(s); no persisted-state or daemon-contract changes.
