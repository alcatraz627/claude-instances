# Dropdown redesign — implementation plan

What we are changing in the menu-bar dropdown, how it should behave, and the order
to build it. The current state is in [`dropdown-spec.md`](./dropdown-spec.md); the
color/layout principles behind the choices here live in
[`~/.claude/conventions/visual-design.md`](../../../conventions/visual-design.md).
This doc is the build target, not a discussion.

## Goal

Show the same dense per-session detail, but make the menu read as one designed
surface instead of seven sections that each invent their own layout and color. The
user-visible wins: a calmer color scheme (colors kept, but they stop competing),
consistent spacing and alignment, paths that don't wrap into multi-line walls, and
a shorter menu (Events and History collapse to a row each).

The redesign is **a small set of shared building blocks, then every section rebuilt
on them** — not per-section restyling.

## Build blocks (build these first)

### Type

Three roles, separated by size and weight (not color):

| Role | Font | Used for |
|------|------|----------|
| Title | 13 semibold | model badge, leaf name (identity) |
| Body | 12 regular | metric values, usage stats, history columns |
| Caption | 11 regular | paths, prompts, state detail, ambient counts |

Mono for columnar/numeric content; system font for prose.

### Spacing

One vertical-rhythm constant per density (compact/cozy/comfortable), used for both
row spacing and section padding. Section headers get slightly more space above them
than rows get between them. No per-section ad-hoc gaps.

### Color

Colors stay — they aid identification — but move onto one perceptual grid so none
out-shouts its neighbors (the why: `visual-design.md`). Three emphasis tiers,
separated by chroma:

- **Loud** — model identity and the severity scale (green→amber→red). These pop.
- **Medium** — cost and tokens; one glance-color each.
- **Quiet** — memory/branch/subagent/state keep their hue at low chroma so they
  recede; turns/tools/speed go neutral gray.

These are the new **default** values for the 17 `PaletteToken`s (all stay
user-tunable). Ship the light column first; the dark column is a follow-up via a
dynamic-color provider. Full derivation:
[`color-palette-research.md`](./color-palette-research.md).

| Token | Tier | Light | Dark |
|-------|------|-------|------|
| `model.opus` | Loud | `#C2740E` | `#E8A33D` |
| `model.sonnet` | Loud | `#3B6FD4` | `#6F9CF0` |
| `model.haiku` | Loud | `#0E97A6` | `#3EC2CE` |
| `success.high` | Loud | `#2E9E58` | `#54C47E` |
| `warn.mid` / `permission.plan` | Loud | `#C98A12` | `#E6B23A` |
| `warn.high` / `permission.auto` | Loud | `#CE4B43` | `#EE7A72` |
| `metric.cost` | Medium | `#B98A1F` | `#DDB257` |
| `metric.tokens` | Medium | `#3F9A63` | `#5FBE85` |
| `metric.memory` | Quiet | `#6E8EC0` | `#8AA6D6` |
| `accent.branch` / `state.active` | Quiet | `#4F9D9A` | `#6FBEBB` |
| `accent.subagent` | Quiet | `#5C93B8` | `#7BB1D2` |
| `metric.turns` / `.tools` / `.speed` | Quiet (gray) | `#8A8A8E` | `#9A9AA0` |

`warn.mid`/`permission.plan`, `warn.high`/`permission.auto`, and the three gray
metrics deliberately share a value — a given red always means one severity. The
tokens stay separate so a power user can split them.

### Glyphs

One state-glyph system: tinted SF Symbols everywhere (drop the legacy emoji map
`liveRowStateIcons`). Same state → one glyph in both the header chip and the
state-detail line. Curate one SF-Symbol set for section/metric icons rather than
mixing emoji and symbols.

### Truncation

One rule per field kind: prose clamps by line with a tail `…`; paths
**middle-truncate** to one line with the full path on hover; identifiers (branch)
tail-truncate. Replaces today's multi-line char-wrapped paths.

### Row primitives

Two reusable composers so sections stop hand-rolling layout with `leftPad`:
- **chip row** — horizontal `(text, role, color)` chips with consistent separators
  (header + metrics use this).
- **columned row** — aligned columns (usage, history, events use this).

Section builders feed chips/columns; the primitive owns spacing and alignment.

## Section behavior (target)

- **Rate limits** — keep the two severity bars; align them on a fixed label column
  so the bars line up. Threshold stays a submenu.
- **Usage** — Today / Week on the columned primitive so their stats align; model
  badges on Today only, in identity color.
- **Live instances** — the star. Rebuilt on the chip-row + caption-line primitives.
  Header chips: model badge · state symbol · leaf · elapsed · `↳N` · `P/A` ·
  `⎇branch` · `*N`, with only severity (`*N`, permission, warnings) and identity
  (badge) loud; branch/subagent in the quiet band. Metrics: `ctx%` (severity) ·
  cost · tokens (medium) · memory/speed/turns/tools (quiet). Path and focus file
  middle-truncated to one line. Every datum kept; the ambient colors stop competing.
- **Events** — collapse to a single `Recent Events (N) ▸` row with a submenu.
  Inside: `glyph · HH:MM · name · context` on the columned primitive, model-badge
  prefix kept. Event colors revisited with the palette: danger glyphs keep severity
  colors, the rest move quiet.
- **History** — collapse to a single `History (N) ▸` row with a submenu. Columned
  rows with real alignment; model badge keeps identity color, the rest quiet.
- **Actions** — unchanged (one-click refresh + cadence submenu already shipped).

## Feedback integration (2026-06-21)

> This is the **V1 claude-instances menu-bar widget** — distinct from the
> abandoned V2 generic-widget platform. Do not conflate the two.

Review items, slotted for consistency (built on the primitives, not bolted on):

- **Per-instance ctx bar** → P4. A short severity-coloured bar beside `ctx N%`,
  same green→amber→red scale as the rate bars. Data: `statusline.ctxRemaining`.
- **Show model effort · permission mode · `/rc` state** → P4 for what's available
  (permission mode already renders as the P/A badge). Model effort and `/rc`-active
  are **not in scan.sh yet** → a data task exposes them first; the row renders them
  once scanned.
- **Per-instance submenu: Copy directory path + Copy resume command** → with P4
  (Bar.swift submenu). Data: `cwd`, `resumeId` → `claude --resume <id>`.
- **Threshold → warning/error zones** → dedicated task (with P5/rate-limits). The
  single "Warning at N%" slider becomes a cleaner multi-zone control (warn /
  danger). Semantics differ from RAM: hitting a usage cap isn't purely bad, so the
  framing is "zones to surface in the top bar," not "a limit to avoid." The
  menu-bar icon colour keys off the zones.
- **Settings reconciliation** → after P4 settles the row shape. The Dashboard →
  Settings module (palette editor + row visibility) must match the rebuilt row;
  open to replacing it with something smarter. Reconcile once the row is final, so
  we don't tune Settings twice.

## Modularization (Phase 1, behavior-preserving)

Split `native/claude-instances-bar.swift` (6019 lines) into ~7 files. `swiftc`
compiles them into the same binary, so this changes nothing at runtime — verify
the menu renders identically before any redesign.

| File | Holds |
|------|-------|
| `main.swift` | entry point, `BarDelegate`, status item, timers |
| `Models.swift` | Codable: `ScanResult`, `LiveInstance`, `RateLimits`, `Event`, … |
| `Palette.swift` | `PaletteToken` (17) + `PaletteStore` + color helpers |
| `MenuBuilders.swift` | the section builders + `addSectionHeader` + row primitives |
| `LiveRowView.swift` | the live-instance `NSView` |
| `Dashboard.swift` | SwiftUI `NSPanel` + tabs |
| `HubBridge.swift` | hub + transcript + resume/open actions |

`build.sh`: `swiftc -O native/*.swift -o …`. Cross-file references that were
`private` become file-scoped, so shared symbols move to default (internal) access.
Verification gate: the test suite's structural greps + a manual open must match
before Phase 3.

## Sequence

1. **Phase 1 — modularize.** Split, build, prove identical render.
2. **Phase 2 — build blocks.** Type/spacing/color-tier/glyph/truncation/primitives.
3. **Phase 3 — rebuild sections** one at a time against this doc, each
   screenshot-reviewed.

Decisions D1–D4 (color philosophy, path truncation, Events/History collapse, event
colors) are settled — see git history of this doc / the spec review.
