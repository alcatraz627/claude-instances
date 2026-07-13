# Line-range map — Transcript.dc.html (4269 lines)

> Produced by a read-only recon agent 2026-07-13 for the P1 port; boundaries
> cross-checked via grep on comment markers and script-tag boundaries. Use with
> PORT-PLAN.md. Line numbers refer to the file as committed in 9132456.

## 1. CSS (`<style>` block, L7–L450)

**Design tokens / theme layer**
- L15–L36 — `:root` design tokens, dark (default): color-scheme, `--bg/--well/--sel/--edge`, role colors (`--you`, `--claude`, `--tool`, `--err`, `--add`, `--del`, `--meta`), soft/ring tint mixes, font stacks (`--sans/--serif/--mono`), type scale, radii, easing, shadow
- L37–L47 — `:root.light` — light-theme override of the same token set
- L48–L56 — base resets (box-sizing, `html`/`body`, button, focus-visible, `.icon`, reduced-motion)

**Layout shell**
- L58–L86 — sticky topbar (`.topbar`, back link, title, live badge + pulse animation, `.tbtn`)
- L87–L118 — `.layout`/`.outline` sidebar + `main`/`.colwrap` reading column, incl. the <1099px drawer/scrim variant (L107–L116)

**Masthead + spine**
- L120–L147 — `.masthead` title page: kicker, `.mh-title`, `.mh-byline` (identity chips), identity colors at L129–L132 (`.bi.model`/`.bi.branch`/`.bi.perm` tinted by `--claude`/`--meta`/`--tool`), `.mh-colophon` stat row, `.spine` progress segments + `.spine-cap`

**Chapter / prompt / passage**
- L149–L170 — `.chapter`/`.ch-head`/`.ch-title`/`.ch-meta`, `.cmdchip` (slash-command chip), `.epi` clamped epigraph (long prompt)
- L172–L193 — Claude `.passage`/`.byline`, and `.content` prose typography (headings, links, code, pre, blockquote, table, mark)

**Activity ledger (tool rows/bodies)**
- L195–L260 — `.ledger`/`.lg-row`/`.lg-body` (collapsed run summary + expand), `.trow` (tool row) + `.tbody`/`.tb-scroll` (tool body pane), diff-line styles (`.dl.add/.del/.ctx`), `.cmdline`, `.todos`, `.jsonpre`, `.nested` (sub-agent transcript indent), `.injected`/`.inj-row`/`.inj-body` (injected annotation), `.evline`/standalone event line

**Dividers, live markers, chapter bar, search, states**
- L262–L279 — `.divider` (day/idle), `.newmark`/`.fresh`/`.flash` (live-append animations), `.endcap`
- L281–L296 — `.chbar` bottom floating prev/next bar, `.jumpnew` pill
- L298–L321 — `.smodal`/`.spanel` search modal (input row, hit list `.shit`, footer)
- L323–L338 — `.sk` skeleton shimmer, `.errbanner`, `.emptycard`
- L340–L347 — `.demo` floating dev-only state switcher (prototype-only)
- L349–L355 — mobile `@media (max-width: 720px)` overrides

**Handoff-specific knob layers**
- L356–L399 — palette skins: `:root[data-skin="tty"]`, `="editorial"`, `="product"` (+ each `.light` pair) — full token re-declarations, color-only
- L400–L408 — direction (geometry) presets: `:root[data-dir="command"/"inspector"]` font swap, `[data-dir="tty"]` (serif→mono, weight), `[data-dir="inspector"]` line-height, `body.no-outline`
- L410–L417 — tool-run rendering for card/bare directions: `.wcard`/`.wcard.solo`/`.wc-foot`, `.bare`
- L419–L427 — session timeline strip: `.cctl` fixed bar, `body.has-tl` padding offsets
- L429–L449 — View panel: `.viewpanel`/`.vp-cap`/`.vp-grp`/`.vp-seg` (segmented control)/`.vp-tog`/`.vp-range`/`.vp-hint`

## 2. JS

**Pre-paint knob bootstrap (FOUC guard)**
- L451 — inline IIFE: reads `cc-skin`/`hx-dir`/`hx-fs` from `localStorage`, sets `data-skin`/`data-dir` on `<html>` and `--measure`/`--fs-prose` before first paint

**Data blob (excise both for the port)**
- L548–L3506 — `window.SESSION = {...}` — inlined real session data: `meta` (L552–L627), `records` (L628 onward), `subagents` map, closing at L3505–3506
- L3507–L3598 — `window.FEED = {...}` — fabricated multi-session feed blob; NO reference in the app-logic script below (unused/leftover) — drop

**External deps**
- L3600 — https://cdn.jsdelivr.net/npm/marked@12/marked.min.js
- L3601 — https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11.9.0/build/highlight.min.js
- L3614/L3615 (created dynamically at L3609–3610) — hljs theme CSS github.min.css (light) / github-dark.min.css (dark)

**App logic script** (L3602–L4267, `"use strict"` at L3603)

Utility helpers (L3604–3642):
- L3604 `$` · L3605 `esc` · L3606 `ic` (icon sprite) · L3607 `kfmt`
- L3608–3619 `applyTheme(t)` — dark/light, swaps hljs stylesheet, persists
- L3620–3627 `copyText` (clipboard + textarea fallback for insecure origin)
- L3628–3635 `sanitizeHTML` — strips script/style/iframe/on*/javascript:
- L3636–3642 `mdRender(el)` — `marked.parse` + `hljs.highlightElement` on `[data-raw]`

Data → chapters / derivations (L3644–3730):
- L3645–3657 `state` object + `HOLD_BACK`/`ALL` (simulation feed — prototype-only)
- L3659–3667 `userParts` — splits slash-command chip from prompt body
- L3668–3672 `userKind(r)` — typed vs injected classification
- L3673–3678 `chTitle(r)` — chapter title from first prompt line
- L3679–3710 `buildChapters()` — grouping + per-chapter tools/toks/agents/errs/mins
- L3711–3730 `annotate(records)` — day/idle dividers + workedMin (30-min idle clip)

Renderers (L3732–3968):
- L3733–3755 `renderMasthead()` (title, byline chips, colophon, spine)
- L3756–3769 `chMetaLine(c)` · L3770–3776 `renderOutline()`
- L3780–3789 `prevHTML(t)` — tool-row preview
- L3790–3817 `toolBody(t)` — Edit/MultiEdit diff, Write, Bash, TodoWrite, Agent/Task → `nestedHTML`, fallback JSON
- L3818–3829 `nestedHTML(t)` — nested sub-agent renderer (reads `window.SESSION.subagents[agentId]` — ADAPT to lazy `?agent=` fetch)
- L3830–3844 `ledgerSummary(run)` · L3845–3868 `ledgerHTML(run, key)` (well style)
- L3869–3922 `chapterHTML(c, i)` — header, chip, title, epigraph, items via `runHTML`
- L3923–3933 `renderChapters()` — full re-render + outline/spine refresh
- L3935–3943 `rerenderChapter(i)` — targeted re-render (live-append)

Navigation (L3945–4016):
- L3946–3950 `jumpToChapter` · L3951–3960 `jumpToSeq` (.flash) · L3961–3968 `updateSpine`
- L3969–3988 scroll listener (topbar .scrolled, current chapter, jumpNew dismissal)
- L3989–3990 chbar wiring · L3991–4010 delegated click handler (outline, spine, expand toggles, epigraph, copy) · L4011–4015 outline drawer

Search (L4017–4076):
- L4018–4022 `searchable(r)` · L4023–4032 `runSearch` · L4034–4054 `renderHits`
- L4055–4067 `openFind`/`closeFind`/`hitJump` · L4068–4075 global keydown (⌘K, `/`, Esc, `[`/`]`)

Live-tail simulation — PROTOTYPE-ONLY, replace with real polling (L4077–4109):
- L4079–4083 `setLiveState(kind)` — topbar working/your-turn/ended badge (KEEP)
- L4084–4103 `appendLive()` — fabricated streaming off HOLD_BACK (REPLACE)
- L4104–4107 jumpNew click (KEEP) · L4108–4109 `startLive`/`stopLive` interval (REPLACE)

Demo state switcher — prototype-only (L4111–4145):
- L4112–4138 `setMode(mode)` — loading/error/empty/normal state renderer (states KEEP; fake error text + demo radios DROP)
- L4139–4142 demo radio wiring (DROP) · L4143–4144 theme button + title-click-to-top (KEEP)

Handoff view controls (L4146–4257):
- L4147–4152 `DIRECTIONS` config (chapters/command/tty/inspector presets)
- L4153–4154 `save`/`load` · L4155–4157 `seg()`
- L4159–4174 `ledgerRowsHTML(run)` (shared rows for card/bare)
- L4176–4184 `runHTML(run, key)` — well/bare/card dispatcher
- L4185–4198 `applyDir` · L4199–4203 `applyPalette` · L4204–4209 `applyTextSize`
- L4211–4241 `buildTimeline()` — 120-bucket density strip + prompt/error ticks, click-to-jump
- L4242–4247 `setTimeline(on)` · L4249–4257 view-panel wiring

Init (L4259–4266): applies theme/direction/palette/size; fake 700ms loading→normal + `startLive()` — REPLACE with real fetch boot.

## 3. Body markup landmarks
- L455–470 — SVG icon symbol sprite (`<symbol id="i-*">`)
- L472–482 — topbar · L483 — scrim · L484–504 — viewpanel
- L506–518 — layout: outline aside + main/masthead/chapters/statewrap mounts
- L520–525 — jumpnew + chbar · L527–535 — search modal
- L538–546 — demo state-switcher (prototype-only)

## 4. Prototype-only vs portable

Strip/replace: SESSION blob (L548–3506) → real `GET /s/<id>/data`; FEED blob
(L3507–3598, unused) → drop; demo markup (L538–546) + demo wiring (L4139–4142);
live simulation (L4084–4103, L4108–4109); init's fake-load choreography
(L4259–4266).

Everything else ships: all CSS except `.demo` (L340–347), all derivations,
all renderers, navigation, search, knob appliers, timeline, utilities.
