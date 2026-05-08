# Gotchas

Developer notes on non-obvious behaviors, pitfalls, and lessons learned.
Newest entries at the bottom.

---

## 2026-05-07 — README hero must be a file, not inline `<svg>`

GitHub.com renders inline `<svg>` blocks in `README.md` correctly, so it's tempting
to paste raw SVG markup directly into the README. But almost every other markdown
renderer (Cursor/VS Code preview, terminal viewers like glow/mdcat, Claude
Desktop's reader, npm/crates.io project pages, AI assistants reading the file) strips
the SVG element and dumps the inner `<text>` nodes as plain prose — producing an
unreadable wall of words like "Claude Instances Native macOS menu bar... opus
sonnet haiku RUNNING SESSIONS opus 14t · 482 t/s..." right at the top of the page.

**Fix:** Always write SVG to a file under `assets/` and reference via
`<img src="assets/banner.svg" width="...">`. The banner and UI-preview SVGs in
this repo live at `assets/banner.svg` and `assets/preview.svg` for that reason.
Same rule applies to any future hero/diagram art added to the README.

---

## 2026-05-08 — `const` in JS halts the script if hit before its declaration

In `lib/detail.sh`'s embedded JS, the flow-arrow code defined `const FLOW_ICONS`
and `function rebuildFlowArrows()` AFTER `applyFilter()` was first called.
Function declarations are fully hoisted, so the call was syntactically valid —
but `const FLOW_ICONS` is in temporal dead zone until its declaration line is
reached. Calling `rebuildFlowArrows()` early threw `ReferenceError: Cannot
access 'FLOW_ICONS' before initialization`, which propagated up and **halted
the entire `<script>` block**. Net effect: not just no flow arrows — every JS
feature added after that point silently stopped working too. No console error
visible without devtools open.

**Fix:** Place every `const` referenced by a hoisted function declaration
BEFORE any code that calls that function. Or move both the const + the
function above any call sites.

**Process lesson:** A static `rg -c flow-arrow` confirms strings are *in the
file* but says nothing about whether DOM elements ever got created. Always
open generated HTML pages in a browser via `chrome-devtools-mcp` and run
`evaluate_script` to confirm runtime state matches expectation. Two passes
of "looks right in the source" claimed flow arrows worked when they didn't.

---

## 2026-05-08 — NSMenu items don't auto-refresh while the menu is open

AppKit calls `menuNeedsUpdate(_:)` when the menu is *about to open*, not while
it's visible. Our scan timer keeps `cachedData` fresh in the background, but
the on-screen rows render off the snapshot taken at open time and stay frozen
until the user closes + reopens.

**Fix (parked):** Convert per-instance rows to view-based `NSMenuItem.view`
items so each row owns its own NSTextField/labels and can mutate them in
place when data changes. See `UPGRADE-PLAN.md` "PARKED — Live-update while
menu is open" for decomposition.

**Workaround today:** The Refresh submenu's "Refresh Now" + close/reopen is
the manual path. Cadence picker keeps the background data fresh.

---

## 2026-05-08 — Chrome blocks `fetch()` between two `file://` URLs

Since Chrome 67 (2018), every `file://` URL is treated as its own opaque
origin. A `file://` page CANNOT `fetch()` another `file://` URL — same-
directory or otherwise. This blocks the natural "transcript page polls its
own file for fresh content" pattern.

**Fix (parked):** Spawn a tiny localhost `http.server` in detail.sh and open
the browser via `http://127.0.0.1:<port>/...`. fetch() then works normally.
See `UPGRADE-PLAN.md` "PARKED — Live-update while transcript is open".

**Workaround today:** Background daemon regenerates the file every 5 minutes;
manual ↻ Refresh button does `location.reload()` to pick up the latest.

---

## 2026-05-08 — `<meta http-equiv="refresh">` + heavy JS = visible flicker

The transcript page used `<meta http-equiv="refresh" content="5">` to keep
itself current. Worked fine when the page was static HTML + minimal JS. After
adding `marked.js` + `highlight.js` via CDN, every 5s reload re-fetched (cache
hit) AND **re-parsed AND re-executed** both libraries, then `marked.parse()`
ran on every message, then `hljs.highlightElement()` ran on every code block —
all on a freshly-torn-down DOM. Result: ~50–100ms work per tick, visible as
a flash + content reflow.

**Fix:** Remove meta-refresh entirely. Use a background regenerator daemon
to keep the file fresh on disk; user clicks a manual ↻ Refresh button to
do a single intentional `location.reload()`. Live-without-click needs the
HTTP-server approach above.

**General principle:** Don't reload a document if you don't have to. The
moment your page has expensive client-side work (markdown rendering, syntax
highlighting, image processing), full reload is no longer cheap.

---

## 2026-05-08 — Background subshells need `BASHPID` for self-identification

The transcript regenerator daemon writes its own PID to a lock file so
subsequent invocations can dedupe. Two pitfalls:

1. **`disown <pid>` usually doesn't work** — `disown` expects a job spec
   like `%1`, not a numeric PID. The variant `disown` (no args) targets the
   most-recent backgrounded job and is what you usually want.
2. **`$$` inside a `(...)` subshell returns the parent shell's PID, not the
   subshell's.** Use `$BASHPID` to get the subshell's actual PID. Without
   this, our daemon was writing the parent's PID to the lock file, then the
   parent exited and `kill -0 <pid>` failed even though the daemon was alive.

**Fix:** `DAEMON_SELF_PID=$BASHPID` inside the subshell, and gate the
self-cleanup `rm -f "$DAEMON_PID_FILE"` on a content match check so a NEW
daemon's PID write isn't trampled by an OLD daemon's exit cleanup.
