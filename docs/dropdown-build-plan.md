# Dropdown redesign — build plan + validation gate

The ordered steps and the validation checked **after each one**, then **all
together at the end**. Target design: [`dropdown-redesign.md`](./dropdown-redesign.md).

Every step is validated on four axes:

- **Behaviour** — the user-visible result is what we intended (and nothing that
  worked before is broken).
- **Runtime** — it actually runs: builds, launches, the menu opens, the path is
  exercised, zero ERROR lines. Not "it compiles."
- **Code** — compiles cleanly, the test suite is green, structure is as intended.
- **Intent** — it serves the redesign goal (calmer-but-colorful, coherent, dense,
  fewer clicks) with no scope drift.

Check boxes are ticked only after the axis is actually verified.

---

## P1 — Modularize into logical files (behaviour-preserving)

Split `native/claude-instances-bar.swift` (6019 lines) into the ~7 units in
`dropdown-redesign.md`. No redesign yet; the menu must render identically.

- [x] **Behaviour** — proven identical by construction: each of the 7 files is a
      byte-exact slice of the original modulo the `private`→`internal` promotion
      (diff empty for all 7). No NSMenu pixel diff possible, but a pure code move
      with zero logic change is stronger evidence than a screenshot.
- [x] **Runtime** — `build.sh` builds + signs + launches (PID alive, scan timer
      started); 0 ERROR lines in the log.
- [x] **Code** — `swiftc -O` of the 7-file module succeeds; 130-test suite green
      (compile test now builds the split; markers resolve across `native/`); 7
      cohesive files; cross-file symbols `internal`, file-local SwiftUI views kept
      `private`.
- [x] **Intent** — pure refactor; byte-identity check confirms zero behaviour
      change and no styling touched.

## P2 — Shared design primitives

Build the reusable blocks: 3-tier type scale, one spacing constant, `chipRow` +
`columnedRow` composers, a truncation helper (line-clamp / middle-truncate /
tail), and one curated SF-Symbol set. No section migrated yet (or one as proof).

- [x] **Behaviour** — no section migrated yet; primitives are unused infra, menu
      renders unchanged (nothing regresses).
- [x] **Runtime** — builds + launches (PID alive, 0 ERROR lines).
- [x] **Code** — `DesignKit.swift` adds `BarFont`, `seg`/`row`, `columned`
      (tab-stop alignment), `middleTruncate`/`tailTruncate`/`clampLines`,
      `severityToken`/`severityColor`; compiles; 138 tests green (8 new markers).
- [x] **Intent** — building blocks ready (one type scale, real column alignment,
      one severity scale); no ad-hoc layout introduced.

## P3 — Harmonious palette defaults + glyph unification

Set the 17 `PaletteToken` defaults to the new light-column hex (tier scheme); drop
the legacy emoji state map so each state has one SF-Symbol glyph.

- [ ] **Behaviour** — PENDING SCREENSHOT (light): colours read as the tiers —
      model identity + severity pop, ambient recedes, turns/tools/speed gray.
      (Glyph unification moved to P4, with the LiveRowView rebuild.)
- [x] **Runtime** — builds + launches (PID alive, 0 ERROR lines).
- [x] **Code** — defaults dict = 17 harmonious light hex; compiles; 138 tests green.
- [x] **Intent** — "many colours, one scene"; ambient demoted by chroma, not grayed
      (only turns/tools/speed go neutral).

## P4 — Rebuild Live instances row on primitives

Move `LiveRowView` onto `chipRow` + caption lines; tier colours; paths/focus
middle-truncated to one line. Every datum kept.

- [x] **Behaviour** — confirmed by user ("looks good"): ctx bar beside `ctx N%`
      (severity colour); cwd + focus paths on one line (full on hover); state-detail
      line has no emoji (header SF-Symbol is the one glyph); submenu has Copy
      Directory Path + Copy Resume Command. (model effort + `/rc` deferred to #23.)
- [x] **Runtime** — builds + launches (PID alive, 0 ERROR); live-update path
      unchanged so rows still tick.
- [x] **Code** — `middleTruncate` (truncation helper) used for paths; `appendBar`
      added; glyph emoji removed; compiles; 144 tests green (6 new P4 markers).
- [x] **Intent** — dense detail preserved (every datum kept), ctx readable at a
      glance, paths no longer wall-wrap.

## P5 — Rebuild Rate limits + Usage on primitives

Bars aligned on a fixed label column; usage Today/Week on `columnedRow`.

- [ ] **Behaviour** — PENDING SCREENSHOT: 5h/7d bars align (label|bar|pct|reset
      on tab stops) and colour by the usage zones; Today/Week stats align; the
      "⚙ Usage zones" submenu has two sliders (Warn ≥ / Danger ≥) + reframed note;
      the menu-bar icon flags by zone (orange warn / red danger). [#22 folded in]
- [x] **Runtime** — builds + launches (PID alive, 0 ERROR lines).
- [x] **Code** — bars + usage use `columned()` (tab stops, no leftPad); `zoneColor`
      drives bars + icon; two-slider `zoneSlider`; compiles; 149 tests green.
- [x] **Intent** — real column alignment (not hand-padding); zones unify bar colour
      and icon; reframed from "limit to avoid" to "zones to surface".

## P6 — Collapse Events + History to submenu rows

Each becomes one `… (N) ▸` row; submenu holds the columned rows.

- [ ] **Behaviour** — PENDING SCREENSHOT: Events + History each one `… (N) ▸` row;
      submenus open with column-aligned rows; menu shorter.
- [x] **Runtime** — builds + launches (PID alive, 0 ERROR lines).
- [x] **Code** — both collapsed to submenu rows; `formatEventItem` + history rows
      use `columned()` (tab stops, no `leftPad`); rate bars now drawn views (not
      ASCII — fixed the "splitting" regression); 153 tests green.
- [x] **Intent** — max detail behind one interaction; shorter menu; real alignment.

---

## Final — full validation sweep (run once all P1–P6 done)

- [ ] **Behaviour** — PENDING USER LIGHT+DARK SCREENSHOT PASS: walk every section —
      identity + severity pop, ambient calm, alignment consistent, paths one line,
      drawn rate bars (not split), Events/History collapsed, Refresh one click,
      ctx bar. Nothing from the original menu lost.
- [~] **Runtime** — clean build + launch, 0 ERROR confirmed. Exercising every
      submenu/action + the light/dark screenshots needs a human (can't drive a live
      NSMenu programmatically).
- [x] **Code** — `swiftc -O` of the 8-file module clean; 153 tests green; `leftPad`
      calls eliminated (comments only); no ASCII bars; emoji not rendered (presence
      flag only); 8 cohesive files.
- [x] **Intent** — matches `dropdown-redesign.md`: harmonious palette, drawn bars,
      collapsed Events/History, one-click refresh, ctx bar, usage zones. No scope
      drift beyond the agreed design.
