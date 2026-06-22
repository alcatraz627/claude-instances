# Transcript viewer redesign — borrowed-patterns plan

Make the transcript viewer read like a macOS / premium-SaaS product instead of a
utilitarian log. The data model and live-update plumbing stay; this is a
presentation rebuild of `lib/transcript-app.html`. Research and citations:
`.claude/output/20260621-transcript-ux-research/` (AI chat UIs, conversation apps,
macOS/SaaS feel, trace/log viewers).

## Thesis (where all four research streams converged)

Our viewer shows the same data the polished ones do. What makes those feel like a
product, and ours not, is four specific things:

1. **A calm, constrained reading surface** (capped measure, generous rhythm) vs a
   cramped full-width log.
2. **Layout that never twitches** under live updates or expand/collapse.
3. **Tool data collapsed to dense one-line summaries** by default, not dumped.
4. **Tiny, always-present feedback** on every interaction (hover, press, copy
   confirm), vs silent clicks.

Fix those four and it stops feeling open-source. Everything below serves them.

## Tier 0 — The feel layer (cheapest, highest impact)

The single highest-leverage change per the research. ~Pure CSS + small JS.

- **Global interactive feedback**: every interactive element gets `cursor: pointer`,
  a ~150ms hover tint, `:active { transform: scale(0.97) }`, and a
  `:focus-visible` ring (2px accent, 2px offset). One ~12-line block kills the four
  worst "utilitarian" tells at once.
- **One motion default**: 150ms ease on color/background/transform globally, so
  nothing snaps at 0ms. Wrap in `@media (prefers-reduced-motion: reduce)` (keep
  opacity, drop transform/scale, 0.01ms not 0).
- **Copy confirmation everywhere**: icon → checkmark swap held ~1.5s on every copy
  control. A silent copy reads as broken.
- **Layout stability**: append-don't-rebuild on live update, RAF-batch DOM writes,
  `dvh` units, bottom padding under the last block so the page never jumps.

## Tier 1 — The reading surface (the anti-log core)

- **Cap the measure** at ~68ch (≈680px) and center it; line-height 1.55. Full-width
  lines are the number-one log smell.
- **Group consecutive same-sender turns**: sender header/identity once per run, a
  tight gap *within* a run and a larger gap *between* runs. Two spacing tokens do
  the whole job.
- **Hierarchy by weight, not color**: system-font stack, semibold identity + regular
  body, three neutral text levels (primary / secondary / tertiary). Mono only for
  code/paths.
- **Neutral-dominant, hairlines not boxes**: greys for chrome, one accent reserved
  for links/active, hairline separators between runs instead of boxed cards.
- **Timestamps recede**: hide per-message time by default; reveal on hover (desktop)
  or a left-drag/tap (touch). Keep day / idle-gap dividers.
- **Spacing scale**: 4/8/12/16/24/32/48 tokens; every gap drawn from it; start
  generous.

## Tier 2 — Taming tool data

- **Collapse tool calls by default** to a dense one-line row: `icon(kind) · summary
  · status` (and duration/tokens when available). Expand to inline detail on tap.
  The collapsed row is the unit of scanning, so it must carry signal, not be a bare
  label.
- **Errors propagate + auto-expand**: a failed tool/hook shows red on its collapsed
  row and opens by default. "Find the failure" becomes "scan for red."
- **Two visual axes off closed fields**: `kind` → icon + accent (message / bash /
  edit / read / event), `status` → a separate badge. Never branch visuals off
  rendered message text.
- **Mixed-stream legibility**: message turns get card-weight; ambient events (hooks,
  mode changes) are hairline rows; everything hangs off one left rail.
- **Sub-agents open in a bottom-sheet / drawer** that doesn't reflow the main
  column. Shallow nesting only.

## Tier 3 — Navigation

- **Jump-to-latest pill** bottom-right above the safe area, with an `N new` badge;
  preserve scroll position on scroll-up, never auto-yank to bottom.
- **Day / idle-gap dividers** with a sticky section pill that fades on scroll-stop,
  chunking a long session into scenes.
- Keep whole-transcript search; restyle it to the new system. Reconsider pagination
  vs a virtualized continuous scroll (continuous reads more like a conversation;
  virtualize for large transcripts).

## Tier 4 — Mobile diffs

- **Unified only** (split never fits a phone). Three WCAG-safe channels per line:
  `+`/`-` gutter glyph + a light background tint + syntax-highlighted tokens.
- **Word-level intra-line highlight** for small edits (the biggest phone diff win).
- **Soft-wrap** so scrolling is one-axis; collapse unchanged regions, collapse whole
  files behind a `path · +N/-M` header, gate huge diffs behind "load full diff."

## Tier 5 — States

- Loading **skeletons** that mirror the real layout (left-to-right shimmer), nothing
  under ~1s, an explicit end-of-list terminus.
- Real **empty** and **error** states: headline + one-line explanation + a single
  action (Retry inline, not a toast).

## Build sequence

Tier 0 and Tier 1 together transform the feel and are mostly CSS, so they go first
and ship as one screenshot-reviewed pass. Then Tier 2 (tool collapse) is the
biggest structural change. Then 3–5. Each tier is screenshot-validated on a phone
viewport against this doc before the next.
