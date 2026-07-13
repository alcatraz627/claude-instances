# Line-range map — Session Index.dc.html (3842 lines)

> Produced by a read-only recon agent 2026-07-13 for the P2 port; boundaries
> cross-checked via awk/rg on structural markers. Line numbers refer to the
> file as committed in 9132456. Use with PORT-PLAN.md.

## 1. CSS (`<style>`, L7–L321)

- L12–L27 — `:root` dark tokens: `--bg/--panel/--well/--sel/--edge`, identity
  colors `--you --claude --tool --err --add --meta` (oklch), soft mixes, fonts,
  radii, easing, shadow
- L28–L37 — `:root.light` override
- L38–L45 — base resets
- L47–L68 — topbar (brand/host, `.chip.live`/`.chip.turn` + pulse, `.tbtn`, select arrow)
- L70–L81 — masthead + rate-limit meters (`.meter .bar` + `.warn`/`.hot`)
- L83–L99 — query bar (`.qbar`/`#fq`/`.qstat`/`.qhint`, `.p-hit` + mark)
- L101–L160 — peeks density: `.grid`, `.pane` (+`.cur`/`.turn`), `.p-head`/`.p-st`
  (working pulse L115–116), `.p-tail` (top fade L131–132), `.p-line` role-colored
  glyph rows (L133–140), `.fresh`/`.cursorline`, `.p-wait`, `.p-alert`, `.p-foot`
- L162–L198 — table density: `.tbl`/`.thead`/`.trow` grid, state box-shadows,
  `.c-*` columns, `.t-hit`/`.mcp` sub-rows
- L199–L207 — `.hpk` hover/cursor preview panel
- L208–L222 — breakpoints: ≤1020px (drop columns + hover preview), ≤720px (stacked cards)
- L224–L233 — `.sec` section headers (+`.you`/`.cl` tint), `.endcap`, `.hint` keymap
- L235–L252 — `.sk` shimmer, `.errbanner`, `.emptycard` + `.pane-ghost`
- L254–L260 — `.demo` switcher (prototype-only)
- L261–L297 — palette skins: tty (L262–273), editorial (L274–285), product (L286–297), each + `.light`
- L299–L300 — `#main { zoom: var(--zoom,1) }` — index text-size = UI zoom
- L302–L320 — View panel CSS

## 2. JS

- L322 — pre-paint IIFE: `cc-skin`/`hx-idir`/`hx-fs` → `data-skin`/`data-dir`/`--zoom`
- L326–L334 — SVG icon sprite · L336–L350 topbar markup · L352–L373 `#main`,
  `#hpk`, `#viewPanel` · L375–L383 `.demo` markup (prototype-only)

**Data blobs (excise, L385–L3435):**
- L388–L3343 — `window.SESSION` (meta L389–464 · records L465–3083 · subagents L3084–3342)
- L3344–L3435 — `window.FEED` (fabricated: live×3 L3346–3400 · recent×2 stubs
  L3401–3418 · limits L3419–3426 · aggregates L3427–3434)

**App logic (L3437–L3839):**
- L3439–L3441 — `$`/`esc`/`ic` · L3442–L3450 theme (`SS`, `applyTheme`)
- L3452–L3454 — `lim()`/`ctxCls()` thresholds
- L3457–L3469 — density + sort prefs, wiring
- L3472–L3479 — `lineFor(r)` record→tail-line mapper
- **L3480–L3495 — `tails` object: DIFF bug #1 site.** Keyed by
  `FEED.live[0/1/2].session_id` at construction (position-keyed); live[1]/[2]
  tails hand-fabricated (L3483–3494). Replace with session_id-keyed real tails.
- **L3496–L3505 — `RECENTS`: DIFF bug #2 site.** Invents model/state/branch/tail
  per element (`i===0` ternary). Replace with real feed fields.
- L3507–L3513 — `tailLinesFor(s)` state-based slice · L3514–3515 `lineHTML`
- L3517–L3543 — `paneHTML` · L3545–L3554 `endedPaneHTML` · L3556–L3574 `rowHTML`
- L3576–L3599 — `showPeek`/`hidePeek` + wiring (reads FEED.live/RECENTS)
- L3601–L3607 — `REALSEARCH` (only live[0] gets real transcript search)
- L3608–L3649 — query engine: `parseQ`, `sessionAttrs` (folder:/file:/repo:
  alias→dir at L3624), `matchSession` (transcript content only for live[0],
  L3631–3633), `hitHTML`
- **L3651–L3656 — `elMin()` parses "2h 14m" display strings: DIFF bug #3 site.**
- L3657–L3663 — `sortGroup` (cost/ctx/recency/urgency)
- L3665–L3693 — `render()` (chips, meters, aggregate line, query bar)
- L3694–L3730 — `renderBoard(q)` (parse→filter→group Needs-you/Working/Ended→
  table|grid per direction→empty state)
- L3732–L3750 — keyboard nav (`/` `d` `t` ↑↓ ↵ + cursor/preview sync)
- **L3753–L3770 — fake tail streaming setInterval(3200): prototype-only.**
- L3772–L3787 — `setMode` demo state switcher (states markup reusable)
- L3789–L3793 — `DIRECTIONS` (fleet/v5grid/base)
- L3795–L3829 — View-panel wiring (`applyDir`/`applyPalette`/`applyTextSize`)
- L3831–L3839 — init (demo radios + 600ms fake load — replace with real boot)

## 3. External deps

NONE — fully self-contained (no CDN links at all; differs from the transcript
prototype which loads marked + highlight.js).

## 4. Port notes

- Prototype-only: both blobs, fabricated tails + RECENTS enrichment, fake
  streaming interval, demo harness, `elMin` display-string sort.
- Portable: all CSS, tail primitives (`lineFor`/`lineHTML`/`tailLinesFor`),
  pane/row renderers, hover preview, query engine (once search source is real
  per-session), `sortGroup` (with real timestamps), `render`/`renderBoard`,
  keyboard nav, prefs, View panel.
- Recon agent raised a product call on shipping the index View panel verbatim;
  RESOLVED: owner explicitly requires live variant toggles (2026-07-13), and
  README §3 ships the View panel on both pages. It stays.
