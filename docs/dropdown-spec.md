# Menu-bar dropdown spec

> A precise description of what the claude-instances menu-bar dropdown renders
> today and how it is built, post-redesign. The bar is split across eight Swift
> files compiled as one `swiftc` module (see `native/build.sh`); the dropdown
> lives in `native/Bar.swift`, the live instance row in `native/LiveRowView.swift`,
> and the shared layout primitives in `native/DesignKit.swift`.

## 1. Rendering model

The dropdown is an `NSMenu` rebuilt from scratch every time it needs to update
(`menuNeedsUpdate` -> `populateMenuItems` in `Bar.swift`). Three kinds of items
coexist:

- **Attributed-title items**, most rows. An `NSMenuItem` whose `attributedTitle`
  is an `NSAttributedString` (font, color, kern). Static; cannot redraw while the
  menu is held open. Used for usage, the Events/History header rows, and actions.
- **Drawn-view items**, the rate bars. Each bar is an `NSView` with a real track
  and fill subview (see §3), so 5h and 7d align on fixed frames.
- **View-based live rows**, the live instance rows only. `NSMenuItem.view` is a
  `LiveRowView` (`NSView`). These mutate in place via `update(with:)` so
  elapsed/ctx/tokens/cost/mem tick while the menu is open (`refreshLiveRows`).
  AppKit will not redraw an attributed title of an open menu; the view path is the
  workaround.

Each top-level section ends with `menu.addItem(.separator())`. The menu's
`minimumWidth` is 340pt.

On open, `menuWillOpen` kicks an immediate `refreshData()` (only when not paused)
so the first frame is fresh. Colors come from system semantic colors (auto
light/dark) and the **PaletteStore** (17 user-tunable tokens), read at render
time so Settings edits propagate on the next tick.

Layout and alignment go through the shared `DesignKit.swift` primitives rather
than ad-hoc string math: a three-role type scale (`BarFont`), a `seg`/`row`
segment builder, a `columned(cells, stops:)` tab-stop aligner (replacing the old
`leftPad`), one truncation rule per field kind (`tailTruncate` for identifiers,
`middleTruncate` for paths), and a single closed severity scale
(`severityToken` / `severityColor`).

## 2. Top-to-bottom structure

Order is fixed in `populateMenuItems`:

1. (No-data fallback: before the first scan completes the **entire** menu is just
   `Scanning…` + separator + `Quit`; no sections render)
2. (Stale-data warning, only on scanner error: `⚠ Scanner error — showing stale data`, red)
3. **Rate limits** (`addRateLimitsSection`)
4. **Usage stats** (`addUsageStatsSection`)
5. **Live instances** (`addLiveInstancesSection`)
6. **Recent events** (`addEventsSection`)
7. **History** (`addHistorySection`)
8. **Actions** (`addActionsSection`)

## 3. Section: Rate limits (`addRateLimitsSection`)

Skipped entirely if no `limits` data, or if neither the 5h nor 7d window is
present. Renders up to three rows.

Each bar row is a single **drawn** `NSView` (not an ASCII bar), laid out on fixed
x-positions so the two windows align crisply:

- **5-hour bar**: ` ⏱ 5h` (secondary) + a 96pt rounded **track** (dim) with a
  zone-coloured **fill** sized to `pct/100` + ` N%` (zone colour) + `resets ~<countdown>`
  (tertiary). `countdown` from `rateLimitCountdown(resets_at)`.
- **7-day bar**: same shape with ` 📅 7d` and `resets_at_weekly`.

Fill colour comes from `zoneColor(forUsage:)`: a usage percentage in the **danger**
zone uses `warn.high`, the **warn** zone uses `warn.mid`, otherwise `success.high`.

The threshold control below the bars is **two usage zones**, not one warning line:

- ` ⚙ Usage zones · warn ≥N% · danger ≥N%` (secondary, mono 11), with a disclosure
  chevron. Its submenu holds an explanatory note plus **two `NSSlider`s** (50–100,
  whole-percent ticks): `Warn ≥` (default 70) and `Danger ≥` (default 90), both
  bound to `thresholdSliderChanged`. The two are clamped so warn never exceeds
  danger.

The zones are deliberately framed as signals, not limits: the submenu note reads
"Hitting a cap is fine — these are signals, not limits." The same two zones drive
the bar fill colour **and** the menu-bar icon (see §10), so all three surfaces flag
the same thresholds.

Trailing separator.

## 4. Section: Usage stats (`addUsageStatsSection`)

Skipped if both today and week session counts are 0. Up to two rows, each a
`columned(...)` attributed title built by `buildUsageRow`, so Today and Week align
their stats on a shared tab stop:

- **Today**: ` 📊 Today` (title) + `<s> sess · <turns> turns · <cost>` (mono,
  secondary) + inline **model badges**: for each model in `modelBreakdown` sorted
  desc, `<badge><count>` in that model's colour. Opus badge `◆`, Sonnet `●`,
  Haiku `○` (palette-tunable; unknown models contribute no badge). Each of
  sess/turns/cost is appended only when > 0.
- **Week**: ` 📈 Week …`, same stats, **no** model badges. Shown only when the week
  session count differs from today's.

Trailing separator.

## 5. Section: Live instances (`addLiveInstancesSection`)

If empty: ` No live instances` (tertiary) + separator.

Otherwise a **header** via `addSectionHeader` with the `sparkles` icon and an
aggregate stats string: `<N> live · <totalRssMB> MB · ↑<totalOut> · <totalCost>`.
Header style: 10pt semibold, tertiaryLabelColor, tracked.

Then **one `LiveRowView` per live instance**. A separator is inserted *between*
rows; the last row is covered by the single trailing section separator.

### 5.1 LiveRowView composition (`update`)

A vertical stack. Indent is one leading constraint (no per-line whitespace). Font
scheme: 13pt header, 12pt metrics, 11pt everything else; bold only on the model
badge. Lines render top-to-bottom, each conditional. Most lines are gated by a
per-row visibility preference (`rowShows(.<row>)`, Settings -> Refresh & Warnings
-> Row Visibility).

1. **Header row** (horizontal chips):
   - Model badge glyph (`◆`/`●`/`○`), bold mono 13, model colour (palette token).
   - State icon: when not idle, a tinted SF Symbol (`brain` / `pencil.tip` /
     `wrench.adjustable` / `checkmark.circle`) in the `state.active` colour. This is
     the **single** state glyph; the detail line below carries no second glyph.
   - Leaf name (13 medium, labelColor) + `<elapsed>` (mono 11, tertiary), one cluster.
   - `↳<N>` subagent count (`accent.subagent`), only if >0.
   - Permission badge, a single letter, only in `plan` (`P`, `permission.plan`) or
     `auto` / `acceptEdits` / `auto-accept` / `auto-accept-edits` (`A`,
     `permission.auto`, soft red because auto bypasses edit confirmation). Default
     mode shows nothing.
   - `⎇<branch>` (`accent.branch`), only if a branch exists.
   - `*<N>` modified files: `warn.mid` (<20) or `warn.high` (≥20), only when a branch
     is present and N>0.
2. **Tab title** ` ⌥ <tab>` (secondary), only if a distinct terminal tab title exists.
3. **Full path**: `middleTruncate(path, 46)` to **one line** (mono 11, tertiary);
   the full path is the label's tooltip (shown on hover). No multi-line wrap.
4. **State detail** `<state>: <detail>` (`state.active`), only when not idle. No
   emoji here; the header SF-Symbol chip is the one state glyph.
5. **Last prompt** `❯ <text>` (secondary), only if present.
6. **Last tool** `last: <name> <target> · <ago> ago` (mono 11, tertiary). Suppressed
   only when the session is idle **and** the tool last ran >5 min ago, so active
   sessions still show a just-run tool.
7. **Metrics row** (horizontal, ` · ` quaternary separators): a short **drawn bar**
   (`appendBar`) on the same green→amber→red severity scale as the rate bars,
   followed by `ctx <N>%` (red <30 / yellow <60 / green ≥60), then `<N>t` turns
   (`metric.turns`) · `🔧<N>` tools (`metric.tools`) · `↑<N>` tokens
   (`metric.tokens`) · `<cost>` (`metric.cost`) · `<N>MB` memory (`metric.memory`)
   · `<N>t/s` speed (`metric.speed`). Each chip is shown only when its value > 0.
8. **Compaction warning** `⚠ Context low (N%) — compaction imminent` (`warn.high`),
   when ctx is 1–14%.
9. **Focus file** `📄 <path>`: `middleTruncate(disp, 46)` to one line, full path on
   hover, if the statusline focus file is set.
10. **MCP-down** `⚠ MCP down: <list>` (`warn.high`), if any MCP server is down.

Row height is computed from `stack.fittingSize` and the view is explicitly resized
because `NSMenuItem.view` ignores `intrinsicContentSize`.

Each chip is tagged with the palette token it draws from, so the Settings palette
editor can drive a bidirectional hover highlight against this same view (the
Settings preview wraps a real `LiveRowView` via `LiveRowViewRepresentable`, so
preview and menu share one renderer).

### 5.2 Per-instance submenu (click a row)

Opening a row's submenu offers: Open in Finder / Terminal (Ghostty) / VSCode,
View Transcript (opens the session hub), Copy PID, **Copy Directory Path**,
**Copy Resume Command**, Terminate. Submenu shortcuts are configurable from
Settings -> Keybinds.

## 6. Section: Recent events (`addEventsSection`)

Collapsed to a single row: header `Recent Events (N)` with the `list.bullet` icon
and a submenu. The submenu lists the last 12 events reversed (newest first); when
the deep-event list is longer, a separator + the last 30 deep events follow. Then a
trailing section separator.

Each event row (`formatEventItem`) is: optional **model badge prefix** (when
`evt.model` is set) + colored **event glyph** + `HH:MM` time + event **name**
(coloured) + **context** (tabTitle suffix-truncated, else project; secondary).

Glyph + colour table (`eventIcons` / colours):

| Event | Glyph | Color |
|---|---|---|
| SessionStart | `▶` | green |
| Stop | `■` | red |
| PermissionRequest | `⚠` | orange |
| PostCompact | `⟳` | systemBlue |
| PreCompact | `⟲` | systemBlue |
| SubagentStart | `↳` | systemPurple |
| SubagentStop | `↲` | systemPurple |
| Notification | `🔔` | yellow |
| PostToolUse | `🔧` | teal |
| (fallback) | `·` | (none) |

**PostToolUse rows show the tool name, not "PostToolUse"** (`evtName = tool`).

## 7. Section: History (`addHistorySection`)

Collapsed to a single row: header `History (N)` with the `clock.arrow.circlepath`
icon and a submenu. The submenu lists the **first 14** sessions, each a
**clickable** row (resume on click, `resumeHistorySession`). Rows are
`columned(cells, stops: [196, 240, 290, 338])` for true column alignment (no
`leftPad`): `<model badge> <project, tail-truncated to 22> <turns>t <size> <cost|–>
<relative time>` (badge in model colour; the rest mono caption, secondary). Agent
sub-sessions show `↳ agent` instead of a project. If >14: ` … and N more (open
Dashboard)` (dim). Trailing separator.

## 8. Section: Actions (`addActionsSection`)

- **New Session**, `plus.circle`, ⌘N.
- **Dashboard**, `rectangle.3.group`, ⌘D.
- **Sessions (phone)**, `iphone`. Ensures the hub is running, opens its index, and
  copies the tailnet URL to the clipboard when Tailscale is up.
- **Refresh Now**, `arrow.clockwise`, ⌘R. One click. Title carries the cadence +
  last-scan age inline: `Refresh Now    <cadence> · <N>s ago`.
- **Auto-refresh interval**, `timer`, a submenu (disclosure chevron) with the
  cadence presets (radio ✓ on current: 1/2/5/10/30/60s) and a `Paused` toggle.
- Separator (only when ≥1 live session).
- **Terminate All (N)**, systemRed.
- **Quit Widget**, `power`.
- **Footer** ` Updated <N>s ago · refresh: <cadence>` (dim), escalates when paused.

## 9. Cross-cutting systems

- **PaletteStore**: **17** tunable color tokens (`enum PaletteToken` in
  `Palette.swift`), read at render time: `model.opus/sonnet/haiku`,
  `metric.turns/tools/tokens/cost/memory/speed`, `accent.branch/subagent`,
  `state.active`, `warn.high/mid`, `success.high`, `permission.plan/auto`. Editable
  in Settings with a bidirectional hover preview that highlights the matching
  `LiveRowView` label. The defaults are a harmonious perceptual-tier palette
  (identity and severity loud, ambient metrics low-chroma, skim counts neutral
  gray); see `docs/color-palette-research.md` and
  `~/.claude/conventions/visual-design.md`. Every "gray/green/amber/sky" colour
  named above is the token's **default**; all are overridable.
- **Density**: compact / cozy / comfortable, controls `LiveRowView` stack spacing
  (`densitySpacing()`), read every render.
- **Row visibility**: Settings toggles which `LiveRowView` lines render
  (`rowShows(.<row>)`).
- **Semantic colors**: labelColor / secondary / tertiary / quaternary auto-adapt to
  light/dark and are deliberately NOT in the palette.

## 10. Menu-bar icon

The status item shows the coral Claude logo (dimmed to 50% when no sessions run)
plus a monospaced count badge (`–` when idle, `N` otherwise, `⚠ N` when a recent
PermissionRequest is pending). When the worst window's usage crosses a zone, the
icon appends that percentage in the zone colour: orange in the warn zone, red in
the danger zone. There is no `⚠` glyph on the usage flag; the colour is the signal
and the dropdown carries the per-window detail. Below the warn zone, no percentage
is appended.
