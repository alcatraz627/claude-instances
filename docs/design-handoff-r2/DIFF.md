# Diff vs. the current `redesign/` implementation

How these two consolidated readers relate to the code you already have in
`redesign/variants/` and `redesign/shared/`. Read this before rebuilding so you
port the *system*, not six divergent files.

## What survives unchanged (lift verbatim)

- **The V3 transcript renderer.** `Transcript.dc.html` **is** `v3-chapters/transcript.html`'s renderer — chapter grouping, activity ledger, tool-body renderers (diff/bash/todo/json/nested agent), epigraph clamp, masthead, outline, spine, search modal, live-append. All copied as-is; only additive knob code was layered on top. The chapters direction is byte-for-byte the current V3 behavior.
- **The V6 index renderer.** `Session Index.dc.html` is `v6-fleet/index.html` — the state-grouped board, query engine (`model:`/`branch:`/`dir:`/`state:` + free text over attributes *and* transcript content), live peek tails, table density, hover preview, keyboard cursor, sort. The fleet direction is the current V6 behavior.
- **All token values.** Colors, type scale, spacing, radii, motion (§1 of README) are exactly the current values. No retuning.
- **Fixes already landed in the current files** and preserved here: weight-proportional spine, injected-content classification (skill preambles are annotations, not chapters), reminder/sidechain badges, mode-events-outside-the-fold, worked-minute idle clip, single-tool-run-as-bare-row economics, V6's grouped index + adaptive idle peeks.

## What changes

### A. Theming moves from files to attributes
- **Current:** each variant hard-codes its palette in its own `:root`/`:root.light`; `shared/skins.css` is an external stylesheet linked per page and toggled by a bottom-left switcher that **navigates between separate files**.
- **Handoff:** palette is `data-skin` on `<html>` (color-only blocks inlined), theme is `.light`, and both apply **live in one file** with no navigation. Register (serif/sans/mono) is decoupled from palette and owned by the direction knob. → In the app, model theme + palette as two independent context values / CSS-var scopes; do **not** ship the tty palette's old font remap (it's a direction concern now).

### B. "Variants" become runtime directions, not routes
- **Current:** V1/V2/V3/V5 are four separate transcript files; V5/V6/base are separate index files; moving between them is a page load via the switcher.
- **Handoff:** they are presets of geometry knobs over **one** reader (README §1.5), flipped in-page. → Build **one** transcript component and **one** index component, each parameterized by a `direction` prop that sets `{measure, sidebar, toolRow, timeline, display}` / `{grouped, layout, query, sort}`. V4 waterfall is **not** a direction — its timeline survives only as the opt-in capability (below).
- Consequence: the `shared/switcher.js` bottom-left file-switcher is **gone** from these readers (replaced by the View panel). The `redesign/` variant files and their switcher stay as-is for reference.

### C. Timeline is a capability, not a page
- **Current:** V4 is a whole architecture; `shared/timeline.js` is also bolted onto V3/V5.
- **Handoff:** the timeline is inlined into the transcript reader and exposed as the `command` direction's default + a View toggle, drawn in the **neutral vocabulary** (faint intensity bars, blue prompt ticks, red error ticks — not V4's four-hue amber mass). → Port `timeline.js`'s build/jump logic; drop V4's colored legend.

### D. Text-size is now a first-class control
- **Current:** fixed prose size per variant (V3 15.5, V4/V5 14.5).
- **Handoff:** transcript exposes `--fs-prose` (13–19px) live; index exposes a UI `zoom` (12–18). → Wire prose size to a token; on the index treat it as UI scale.

### E. Data is inlined; self-contained
- **Current:** every page `<script src="../../shared/session-slice.js">`.
- **Handoff:** the slice is inlined so each file stands alone (your requirement). → In the app this is obviously two fetches (`GET /s/<id>/data`, `GET /api/sessions`); the inlining is a prototype packaging detail only.

## Bugs to fix at the source (do NOT re-port these as-is)

These exist in the current V5/V6 files and are carried into the handoff readers **only because the readers reuse that code**. Fix them in the data layer when you rebuild — flagged in the multi-lens review (`research/SUBREVIEWS-2026-07-10.md`):

1. **Peek tails keyed by feed position** (`FEED.live[0]`, `[1]`, `[2]`) in both index origins. A feed reorder attaches the wrong live tail to a session. → Key fabricated/streamed tails by `session_id`, defined once server-side.
2. **`RECENTS` enrichment invented per-page** (model/branch/final tails). → Move to the data layer; recents need real `session_id`s (also unlocks ended-row hover previews, currently dead).
3. **Sort "recency" parses display strings** ("2h 14m"). → Sort on real timestamps.
4. **Full-board `innerHTML` rebuild per keystroke / toggle** and a streaming interval with no `visibilitychange` guard. → Debounce; pause the tail loop when the tab is hidden; don't rebuild scroll-position-losing DOM on every filter at fleet scale.

## Still open (not in these readers)

- Transcript-scope query fields (`tool:` / `role:` / `err:`) — the query grammar is index-only today; extend the same parser into the transcript search modal.
- Sub-agent "open full transcript ▸" escape hatch.
- Phone pass (≤390px): the readers are responsive to ~720px; a true phone audit of the View panel, peek targets, and timeline touch targets is pending.
- Wide-artifact (tables/code past `--measure`) expand-to-full-bleed affordance.
