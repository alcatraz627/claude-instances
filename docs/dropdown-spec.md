# Menu-bar dropdown — current-state spec

> A precise description of what the claude-instances menu-bar dropdown renders
> today and how it is built, as of 2026-06-20. This is the baseline we agree on
> before any structured redesign. Source: `native/claude-instances-bar.swift`
> (6019 lines). Reference screenshot: `.tmp-test/dropdown-2026-06-20.png` (light
> mode, 4 live sessions).

## 1. Rendering model

The dropdown is an `NSMenu` rebuilt from scratch every time it needs to update
(`menuNeedsUpdate` → `populateMenuItems`, `bar.swift:2007`, `:2087`). Two kinds
of items coexist:

- **Attributed-title items** — most rows. An `NSMenuItem` whose `attributedTitle`
  is an `NSAttributedString` (font, color, kern). Static; cannot redraw while the
  menu is held open. Used for rate bars, usage, events, history, actions.
- **View-based items** — the live instance rows only. `NSMenuItem.view` is a
  `LiveRowView` (`NSView`, `bar.swift:1114`). These mutate in place via
  `update(with:)` so elapsed/ctx/tokens/cost/mem tick while the menu is open
  (`refreshLiveRows`, `:2031`). AppKit will not redraw an attributed title of an
  open menu; the view path is the workaround.

Each top-level section ends with `menu.addItem(.separator())`. The menu's
`minimumWidth` is 340pt (`:2088`).

On open, `menuWillOpen` (`:2013`) kicks an immediate `refreshData()` (only when not
paused, `:2018`) so the first frame is fresh. Colors come from system semantic colors (auto light/dark) and the
**PaletteStore** (12 user-tunable tokens, `bar.swift` palette section), read at
render time so Settings edits propagate on the next tick.

## 2. Top-to-bottom structure

Order is fixed in `populateMenuItems` (`:2087`):

1. (No-data fallback — before the first scan completes the **entire** menu is just
   `Scanning…` + separator + `Quit`; no sections render, `:2090`)
2. (Stale-data warning, only on scanner error: `⚠ Scanner error — showing stale data`, red)
3. **Rate limits** (`addRateLimitsSection`, `:2124`)
4. **Usage stats** (`addUsageStatsSection`, `:2213`)
5. **Live instances** (`addLiveInstancesSection`, `:2276`)
6. **Recent events** (`addEventsSection`, `:2489`)
7. **History** (`addHistorySection`, `:2526`)
8. **Actions** (`addActionsSection`, `:2574`)

## 3. Section: Rate limits (`:2124`)

Skipped entirely if no `limits` data. Renders up to three rows:

- **5-hour bar** — ` ⏱ 5h  ` (secondary) + 10-cell bar (`█` filled in severity
  color, `░` empty in quaternary) + `  N%` (severity color) + `   resets ~<countdown>`
  (tertiary). `countdown` from `rateLimitCountdown(resets_at)`.
- **7-day bar** — same shape with ` 📅 7d ` and `resets_at_weekly`.
- Severity scale (shared by both, `:2147` `severity()`): `≥90` → systemRed,
  `≥70` → systemOrange, else systemGreen. Dynamic system colors (light/dark safe).
  *(This replaced an earlier scheme that painted the weekly bar cyan/indigo, which
  washed out in light mode.)*
- **Threshold control** — ` ⚙ Warning at N%` (secondary, mono 11) with a submenu
  containing an `NSSlider` (50–100, 5% ticks) bound to `thresholdSliderChanged`.
  Renders with a disclosure chevron (it has a submenu).
- Trailing separator.

Bar glyphs are `█` filled / `░` empty (mono 12 medium, `:2135`); fill =
`floor(pct/10)` cells. Screenshot: `⏱ 5h` fully empty (0% → no fill, so no severity
color shows; only the `0%` label is green), `📅 7d` ~6 filled `█` cells at 69%
`resets ~2d 9h`, `⚙ Warning at 70%`.

## 4. Section: Usage stats (`:2213`)

Skipped if both today and week session counts are 0. Up to two rows, each an
attributed title built by `buildUsageRow` (`:2220`):

- **Today** — ` 📊 Today ` (label, 13 medium) + `<s> sess · <turns> turns · <cost>`
  (mono 12, secondary) + inline **model badges**: for each model in
  `modelBreakdown` sorted desc, `<badge><count>` in that model's color (mono 11).
  Opus badge `◆`, Sonnet `●`, Haiku `○` (default orange/blue/teal, palette-tunable;
  unknown models contribute no badge, `:2246`). **Each of sess/turns/cost is appended
  only when > 0** (`:2229`), so the row carries 1–3 stat segments, not a fixed three.
- **Week** — ` 📈 Week …`, same stats, **no** model badges. Shown only when week
  session count differs from today's (`:2267`).
- Trailing separator.

Screenshot: `📊 Today 3 sess · 3K turns  ◆17` (opus badge, orange; cost gated when 0);
`📈 Week 20 sess · 22K turns · 56¢` (no model badges on Week).

## 5. Section: Live instances (`:2276`)

If empty: ` No live instances` (tertiary) + separator.

Otherwise a **header** via `addSectionHeader` (`:2925`) with the `sparkles` icon
and an aggregate stats string: `<N> live  ·  <totalRssMB> MB  ·  ↑<totalOut>  ·
<totalCost>` (built `:2293`). Header style: 10pt semibold, tertiaryLabelColor,
kern 0.6 (calm, tracked).

Then **one `LiveRowView` per live instance**. A separator is inserted *between*
rows (only when `idx < count-1`, `:2414`); the last row is covered by the single
trailing section separator, not its own.

### 5.1 LiveRowView composition (`update`, `:1173`)

A vertical stack. Indent is one leading constraint (no per-line whitespace).
Font scheme: 13pt header, 12pt metrics, 11pt everything else; bold only on the
model badge. Lines render top-to-bottom, each conditional:

1. **Header row** (horizontal chips, `:1238`):
   - Model badge glyph (`◆`/`●`/`○`), bold mono 13, model color (palette token).
   - State icon — when not idle, a tinted SF Symbol (`brain`/`pencil.tip`/
     `wrench.adjustable`/`checkmark.circle`) in the `state.active` color.
   - Leaf name (13 medium, labelColor) + `  <elapsed>` (mono 11, tertiary), one cluster.
   - `↳<N>` subagent count — mint-cyan (`accent.subagent`), only if >0.
   - Permission badge — single letter, only in `plan` (`P`, amber) or
     `auto`/`acceptEdits`/`auto-accept`/`auto-accept-edits` (`A`, soft red).
     Default mode shows nothing.
   - `⎇<branch>` — teal (`accent.branch`), only if a branch exists.
   - `*<N>` modified files — yellow (<20) or red (≥20), only when branch present and N>0.
2. **Tab title** ` ⌥ <tab>` (secondary) — only if a distinct terminal tab title exists.
3. **Full path** `<~/cwd>` (mono 11, tertiary, **char-wrap, never truncated**) — if != leaf.
4. **State detail** `<emoji> <state>: <detail>` (teal) — only when not idle.
   **Dual glyph system:** the header state icon (line 1) is a tinted SF Symbol
   (`brain`/`pencil.tip`/`wrench.adjustable`/`checkmark.circle`, `liveRowStateSymbols`
   `:2057`), but this detail line uses a *legacy emoji* (`💭`/`✍️`/`🔧`/`⚙️`,
   `liveRowStateIcons` `:2066`). Same state, two different glyphs — a redesign
   should unify them.
5. **Last prompt** `❯ <text>` (secondary) — only if present.
6. **Last tool** `last: <name> <target> · <ago> ago` (mono 11, tertiary) — present
   unless the session is idle AND the tool ran >5 min ago (stale-suppression).
7. **Metrics row** (horizontal, ` · ` quaternary separators, `:1384`):
   `ctx <N>%` (red <30 / yellow <60 / green ≥60) · `<N>t` turns (gray) · `🔧<N>`
   tools (gray) · `↑<N>` tokens (green) · `<cost>` (amber) · `<N>MB` memory (sky) ·
   `<N>t/s` speed (gray). Each chip only shown when its value > 0.
8. **Compaction warning** `⚠ Context low (N%) — compaction imminent` (red) — when ctx 1–14%.
9. **Focus file** `📄 <./rel path>` (tertiary, char-wrap) — if statusline focus file set.
10. **MCP-down** `⚠ MCP down: <list>` (red) — if any MCP server down.

Row height is computed from `stack.fittingSize` and the view is explicitly resized
(`:1479`) because `NSMenuItem.view` ignores `intrinsicContentSize`.

Many lines are gated by `rowShows(.<row>)` — a per-row visibility preference
(Settings → Row Visibility).

### 5.2 Per-instance submenu (click a row)

Opening a row's submenu offers: Open in Finder / Terminal (Ghostty) / VSCode,
View Transcript (now → hub), Copy PID, Terminate (`:2310`–`2480` region).

## 6. Section: Recent events (`:2489`)

Header `Recent Events` (`list.bullet` icon). Then the **last 7 events, reversed**
(newest first), each an attributed `formatEventItem` row, then a `📜 Event
History (N)…` item whose submenu lists the last 30 deep events, then a separator.

Each event row (`formatEventItem`, `:2440`–`:2486`) is: optional **model badge
prefix** (when `evt.model` set, `:2446`/`:2467`) + colored **event glyph** + `HH:MM`
time + event **name** (colored, padded to 14) + **context** (tabTitle suffix-
truncated to 16, else project; secondary).

Full glyph + color table (`eventIcons` `:2423`, colors `:2428`):

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
| (fallback) | `·` | — |

**PostToolUse rows show the tool name, not "PostToolUse"** (`evtName = tool`,
`:2450`–`:2452`, truncated to 14).

Screenshot rows (all SessionStart/Stop in this capture): `▶ 05:08 SessionStart  tmp`,
`■ 05:09 Stop  tmp`, … `📜 Event History (50)…`.

## 7. Section: History (`:2526`)

Header `History (N)` (`clock.arrow.circlepath` icon). Then the **first 6** sessions,
each a **clickable** row (resume on click, `resumeHistorySession`): `<model badge>
<project padded to 18> <turns>t <size> <cost|–> <relative time>` (badge in model
color; rest mono 11 secondary; columns left-padded for alignment). Agent sub-sessions
show `↳ agent` instead of a project. If >6: ` … and N more (open Dashboard)` (dim).
Trailing separator.

Screenshot: `◆ local/models  1103t  2.1M  –  2m`, `◆ ↳ agent  43t  218K  9¢  9h`, etc.

## 8. Section: Actions (`:2574`)

- **New Session** — `plus.circle`, ⌘N.
- **Dashboard** — `rectangle.3.group`, ⌘D.
- **Sessions (phone)** — `iphone`. Ensures the hub is running, opens its index,
  and copies the tailnet URL to the clipboard when Tailscale is up.
- **Refresh Now** — `arrow.clockwise`, ⌘R. One click. Title carries the cadence +
  last-scan age inline: `Refresh Now    <cadence> · <N>s ago`.
- **Auto-refresh interval** — `timer`, submenu (disclosure chevron) with the cadence
  presets (radio ✓ on current) and a `Paused` toggle.
- Separator (only when ≥1 live session).
- **Terminate All (N)** — systemRed.
- **Quit Widget** — `power`.
- **Footer** — ` Updated <N>s ago · refresh: <cadence>` (dim), escalates when paused.

## 9. Cross-cutting systems

- **PaletteStore** — **17** tunable color tokens (`enum PaletteToken`, `:649`),
  read at render time: `model.opus/sonnet/haiku`, `metric.turns/tools/tokens/cost/
  memory/speed`, `accent.branch/subagent`, `state.active`, `warn.high/mid`,
  `success.high`, `permission.plan/auto`. Editable in Settings with a bidirectional
  hover preview that highlights the matching `LiveRowView` label. *(The README's
  "12 tokens" is stale — the palette grew to 17.)* Every "gray/green/amber/sky"
  color named elsewhere in this spec is the token's **default**; all are overridable.
- **Density** — compact / cozy / comfortable, controls `LiveRowView` stack spacing
  (`densitySpacing()`), read every render.
- **Row visibility** — Settings toggles which `LiveRowView` lines render
  (`rowShows(.<row>)`).
- **Semantic colors** — labelColor / secondary / tertiary / quaternary auto-adapt
  to light/dark and are deliberately NOT in the palette.

## 10. Known structural issues (the redesign targets)

- The whole menu is built imperatively across ~7 builder methods inside one
  6019-line file; there is no shared row/column/spacing primitive, so spacing and
  alignment are tuned ad hoc per section.
- Alignment in attributed rows relies on monospace + manual left-padding
  (`leftPad`), which breaks when content widths vary.
- Section headers, rate bars, usage, events, history are all distinct ad-hoc
  attributed-string layouts; only the instance rows have a real view component.
- `LiveRowView` packs up to 10 conditional lines per instance — dense, and the
  per-line truncation/wrap rules differ (some char-wrap, some truncate).
