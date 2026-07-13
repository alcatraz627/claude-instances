# Transcript Viewer — Engineering Handoff

> Paste this whole document to the agent that will build the real app. It is self-contained: it carries the **concepts and rationale**, the **data pipeline** from raw Claude Code `.jsonl` to the on-screen view model, the **full design-token system**, and the **exact variant tables** for theme / palette / direction / text-size — all of which must ship as **live in-app controls**, not hard-coded choices.
>
> Two reference designs accompany this doc: `Transcript Viewer Proposal.dc.html` (the session reader) and `Session Index.dc.html` (the landing grid). They are visual prototypes with fabricated-but-realistically-shaped data. Your job is to wire the same view model and design system to **real session data** and ship it as a single file.

---

## 0. What you're building & why

A phone-first reading surface for Claude Code sessions running on the user's machines, reachable over Tailscale. Two surfaces:

1. **Session Index** — the landing page. A grid of rich cards, one per live/recent session.
2. **Transcript Viewer** — open one session and read it like a calm document, not a terminal log.

**The four jobs the UX must serve** (these drove every decision — keep them in mind when you make trade-offs):

1. **Find one specific thing fast.** → search that doubles as a jump palette.
2. **Skim the whole session and get an accurate read without feeling overwhelmed.** → prose-first reading flow; structured/tool data folded until asked; a session map.
3. **Inspect internal thinking / tool calls / tool usage.** → every tool call is one tappable line that expands to its diff / command / JSON / todo / sub-agent.
4. **Feel time passing and the weight of work between two user messages.** → "worked Nm · K tools · T tok" meters on every tool group, idle-gap dividers, and a session map whose item widths scale with work.

**Hard constraints** (from the original brief — do not break these):

- **One self-contained HTML file.** Plain CSS + vanilla JS. The only external libraries allowed are **`marked.js`** (markdown) and **`highlight.js`** (code). No build step, no framework.
- Must run over **insecure HTTP** on a tailnet (no APIs that require secure context).
- **Mobile-first**, must also work on desktop.
- **Layout-stable under live append** — new blocks arrive while you read; the page must not jump.
- All theming via **CSS custom properties** so the variant controls below are cheap.

---

## 1. Data pipeline — raw `.jsonl` → view model

Claude Code writes one session as a **JSON Lines** file (one JSON object per line), appended in real time. This is your input. The pipeline has three stages: **parse lines → coalesce into blocks → derive summary/meta.** Treat the line schema below as *observed from real sessions* — confirm field names against your own dumps; some (hook shape, live status) you will get from the server, not the log.

### 1.1 Line types (the raw log)

Every line is an object. Common envelope fields: `type`, `parentUuid`, `uuid`, `timestamp` (ISO), `gitBranch`, `cwd`, `isSidechain`.

| `type` | Meaning | Key fields |
|---|---|---|
| `last-prompt` | Pointer to the leaf of the active branch | `leafUuid` |
| `summary` | Model-generated session summary (may appear) | `summary`, `leafUuid` |
| `user` | A user turn **or** a tool result being fed back | `message.content` (string, or array of `{type:"text"}` / `{type:"tool_result", tool_use_id, content}`) |
| `assistant` | A Claude turn — prose and/or tool calls | `message.model`, `message.usage`, `message.content` (array of `{type:"text", text}` / `{type:"tool_use", id, name, input}`) |
| `system` | Local command / system notes | `subtype` (e.g. `local_command`), `content` |
| (attachment) | Hook results, etc. | `attachment.type` = `hook_success` \| `hook_error`, plus payload |
| permission/mode | Permission-mode changes | mode string |

`message.usage` (on assistant lines) carries: `input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`.

**Sidechains / sub-agents:** lines with `isSidechain:true` (and `Task` tool calls) belong to a nested agent transcript. Keep them associated with the parent `Task` tool_use so the UI can open them as a nested transcript on demand.

### 1.2 Coalescing into blocks (the view model)

The reader does **not** render raw lines — it renders **blocks**. Walk the lines in order and group:

- A **`user`** line with real text (not a pure `tool_result` payload, not only a `<system-reminder>`) → a **user block**. Count `+N reminders` if the content array also carries reminder text.
- One or more consecutive **`assistant` text** parts → an **assistant block** (prose; render `text` through marked.js).
- A run of **`tool_use`** parts + their matching **`tool_result`** lines → **one tool group block**. Each tool inside keeps `{name, input, result}` and a body type (below). Compute the group's **meter** from the timestamps and token deltas spanned by the run.
- A **hook / permission / system** line → an **event block**.
- **Idle-gap divider:** when `Δt` between two adjacent blocks exceeds a threshold (e.g. > 8 min, and always across a calendar-day boundary), inject a **divider block** carrying the elapsed label ("18m later", "Tue") and a rollup of the work in the gap ("5 tools · 31k tokens").

**Block shape the UI consumes** (normalize to this — both pages depend on it):

```js
// role: 'user' | 'assistant' | 'tools' | 'event' | 'divider'
{ seq, role, ts,
  // user:
  paras:[string], reminders:int,
  // assistant:
  model, paras:[string],
  // tools:
  meter:"2m · 2 tools · 14k", tools:[{ name, preview, body }],
  // event:
  event_type:"hook"|"permission"|…, text, detail, event_err:bool, errText,
  // divider:
  label:"18m later", work:"5 tools · 31k tokens" }
```

**Tool `body` types** (drives which expanded renderer is used):

| body.type | Source | Renders as |
|---|---|---|
| `diff` | `Edit`/`MultiEdit`/`Write` input → old/new | gutter +/- lines, add/del color rows |
| `cmd` | `Bash` input + result | `$ command` block + stdout |
| `todo` | `TodoWrite` input | checkbox list, done = struck + accent box |
| `agent` | `Task` (sub-agent) | accent2 rail, "Open nested transcript →" (lazy-load sidechain) |
| `json` | everything else (`Read`, `Grep`, MCP, …) | pretty-printed JSON / meta |

The **monogram + color** of a tool row is derived from its name — see §4.4. The **collapsed preview** is the most useful one-liner: file path for `Read`/`Edit`, the command for `Bash`, the pattern + match count for `Grep`, the task title for `Task`.

### 1.3 Deriving session meta (for the topbar + index card)

Aggregate while you walk:

```
title       = first real user prompt (cleaned), else summary line
model        = last assistant message.model  (pretty-print: "claude-opus-4-8" → "Opus 4.8")
branch       = last gitBranch ; cwd = last cwd (collapse $HOME → ~)
counts       = { user, assistant, tools, event }
toolCounts   = { Bash: n, Edit: n, … }      // for the card's top-tool monograms
tokIn/out    = Σ usage.input/output_tokens
tokCache     = last cache_read_input_tokens (+ Σ cache_creation)
tokTotal     = human(tokIn + tokOut)
firstTs/lastTs → duration ("1h 24m"), span ("spans 3 days")
inPct/outPct  = share of a sensible denominator for the split-bar (cache as faint underlay)
```

**Status (`working` / `needs` / `idle`)** is **not** reliably in the log — it's a *live* property (is the process generating right now? is it blocked on a permission prompt?). Get it from your server/daemon, not by guessing from the file. The UI treats it as first-class (see §5, §6). `needs` sorts above `working` above `idle` on the index.

> Reference parse: `sessions.json` in this project was produced by walking the three uploaded `.jsonl` files with exactly this logic — use it as a fixture / shape reference.

### 1.4 Live updates

The file is appended to. Poll `/data` (or tail via your transport) and **append new blocks in place**. Rules:

- If the user is at/near the bottom → auto-scroll to keep newest in view.
- If scrolled up → **do not jump**; show a "**N new ↓**" pill and a persistent "**↓ latest**" affordance.
- Persist scroll position to `localStorage` keyed by session id so reopening resumes where they were.
- Never reflow earlier content (stable keys per `seq`).

---

## 2. The control system — SHIP THESE AS LIVE CONTROLS

This is the part to get right: **theme, palette (color), direction (layout), and text-size must all be user controls inside the app**, persisted, not author-time constants. The mechanism is a **four-layer CSS-variable cascade** merged onto the root element:

```
themes[theme]            // neutral + semantic roles (bg, surface, text, dim, add/del/err…)
  ⊕ palettes[palette][theme]   // the two accents only (--accent = You, --accent2 = Claude)
  ⊕ directions[direction]      // geometry: radii, gaps, paddings, type scale, layout hooks
  ⊕ { zoom }                   // root font-scale / CSS zoom
→ applied with root.style.setProperty(k, v) for every key
→ all four choices persisted to localStorage, re-read on load
```

Because everything else in the CSS reads `var(--…)`, flipping any layer is instant and global. Put the controls in a **Display / Settings sheet** reachable from the topbar (the reference design surfaces theme + size directly in the bar and keeps palette + direction in the proposal header — in the real app, group all four in one sheet, with theme also as a quick toggle in the bar).

### 2.1 Theme (2) — dark default, GitHub-ish blue-slate

Neutral + semantic roles. Accents come from the palette layer, so they are **not** here.

```js
themes = {
  dark: { '--bg':'#13151c','--surface':'#1b1e27','--surface2':'#252935',
    '--border':'rgba(180,190,225,.12)','--text':'#e9ecf4','--dim':'#9499ab','--faint':'#646a7e',
    '--add':'#6fc090','--add-bg':'rgba(111,192,144,.14)','--del':'#e07f72','--del-bg':'rgba(224,127,114,.14)',
    '--warn':'#dcb05f','--err':'#e07f72','--tint':'rgba(180,190,225,.05)' },
  light:{ '--bg':'#f4f6f9','--surface':'#ffffff','--surface2':'#e8ebf0',
    '--border':'rgba(20,24,40,.12)','--text':'#1b1d23','--dim':'#686c75','--faint':'#8a8e98',
    '--add':'#3f8a59','--add-bg':'rgba(63,138,89,.12)','--del':'#bb5346','--del-bg':'rgba(187,83,70,.1)',
    '--warn':'#9c7320','--err':'#bb5346','--tint':'rgba(20,24,40,.04)' }
};
```

Dark is intentionally **not** near-black — it's a soft blue-slate at GitHub's darkness level, with borders/tints carrying a faint blue cast (`rgba(180,190,225,…)`) rather than pure white, which is what makes it feel calm rather than harsh.

### 2.2 Palette (8) — the accent layer; `--accent` = You, `--accent2` = Claude

Each palette defines only the two accents, per theme. **Slate is the default.** Keep all eight — the user picks.

```js
palettes = {
  Slate:    { dark:{'--accent':'#6f86f0','--accent-soft':'rgba(111,134,240,.18)','--accent2':'#4fb6a6'},
              light:{'--accent':'#4a57c8','--accent-soft':'rgba(74,87,200,.13)','--accent2':'#2f8e80'} },
  Iris:     { dark:{'--accent':'#a78bfa','--accent-soft':'rgba(167,139,250,.18)','--accent2':'#5fb0e8'},
              light:{'--accent':'#6d4fd0','--accent-soft':'rgba(109,79,208,.13)','--accent2':'#2f7bb8'} },
  Clay:     { dark:{'--accent':'#d4825d','--accent-soft':'rgba(212,130,93,.16)','--accent2':'#86a6cb'},
              light:{'--accent':'#bb6037','--accent-soft':'rgba(187,96,55,.13)','--accent2':'#4d749c'} },
  Graphite: { dark:{'--accent':'#8aa0c4','--accent-soft':'rgba(138,160,196,.16)','--accent2':'#aab0bc'},
              light:{'--accent':'#56627d','--accent-soft':'rgba(86,98,125,.12)','--accent2':'#7c8292'} },
  Forest:   { dark:{'--accent':'#5cb98a','--accent-soft':'rgba(92,185,138,.16)','--accent2':'#c2a85f'},
              light:{'--accent':'#2f8a5b','--accent-soft':'rgba(47,138,91,.12)','--accent2':'#8a6d23'} },
  Ember:    { dark:{'--accent':'#e6735c','--accent-soft':'rgba(230,115,92,.16)','--accent2':'#d8a24e'},
              light:{'--accent':'#c2492f','--accent-soft':'rgba(194,73,47,.12)','--accent2':'#9c7320'} },
  Ocean:    { dark:{'--accent':'#4aa8d8','--accent-soft':'rgba(74,168,216,.16)','--accent2':'#6fd0c4'},
              light:{'--accent':'#2575a3','--accent-soft':'rgba(37,117,163,.12)','--accent2':'#2f8e80'} },
  Mono:     { dark:{'--accent':'#cdd0d8','--accent-soft':'rgba(205,208,216,.13)','--accent2':'#9398a3'},
              light:{'--accent':'#3a3d45','--accent-soft':'rgba(58,61,69,.1)','--accent2':'#797d87'} }
};
```

Rule of thumb if you add more: the two accents should share lightness/chroma and differ mainly in hue, so You/Claude read as a pair, not a clash. Reserve `--add`/`--del`/`--err` (green/red) strictly for diffs and errors — never as a palette accent.

### 2.3 Direction (4) — layout philosophy, expressed as geometry hooks

Direction changes **structure and density**, not color. Each sets radii, gaps, padding, the body type scale, and a few layout hooks the templates read. **Console is the default.** (An earlier "Manuscript" direction was cut — Console covers the airy case well enough and Compact covers density.)

```js
directions = {
  Console:  { desc:'dense, every row surfaced',
    '--r-md':'9px','--r-sm':'6px','--turn-gap':'19px','--row-pad':'10px 12px','--tool-gap':'7px',
    '--tool-bg':'var(--surface)','--tool-border':'var(--border)','--user-bg':'var(--surface)',
    '--user-maxw':'100%','--user-ml':'0','--user-jc':'flex-start',
    '--body-fs':'15.5px','--body-lh':'1.62','--label-mb':'7px','--tool-grp-mt':'14px',
    '--spine':'0px solid transparent','--blocks-pl':'16px','--spine-ml':'0px' },

  Compact:  { desc:'maximum density, log-like',
    '--r-md':'6px','--r-sm':'4px','--turn-gap':'9px','--row-pad':'5px 9px','--tool-gap':'4px',
    '--body-fs':'13px','--body-lh':'1.45','--label-mb':'3px','--tool-grp-mt':'7px',
    '--blocks-pl':'12px', /* + same layout hooks as Console */ },

  Threads:  { desc:'messaging app — sender by alignment',
    '--r-md':'19px','--r-sm':'13px','--turn-gap':'15px','--row-pad':'11px 13px',
    '--user-bg':'var(--accent-soft)','--user-maxw':'80%','--user-ml':'auto','--user-jc':'flex-end',
    '--body-fs':'15px','--body-lh':'1.55', /* … */ },

  Timeline: { desc:'time-forward spine — feel the gaps',
    '--r-md':'12px','--r-sm':'8px','--turn-gap':'24px','--row-pad':'11px 13px',
    '--spine':'2px solid var(--border)','--blocks-pl':'18px','--spine-ml':'19px',
    '--tool-grp-mt':'18px', /* … */ }
};
```

How the hooks are consumed (so you know what they do):

- `--user-maxw` / `--user-ml` / `--user-jc` — **Threads** uses these to right-align user bubbles in an accent-tinted bubble (sender by alignment, not just color — this is the single biggest perceptual differentiator and is well-supported by chat-UI research).
- `--spine` / `--blocks-pl` / `--spine-ml` — **Timeline** draws a vertical rule down the block column so idle gaps read as physical distance.
- `--body-fs` / `--body-lh` / `--label-mb` / `--tool-grp-mt` — **Compact** shrinks all of these together so it becomes genuinely log-dense, not just "Console with smaller corners."

### 2.4 Text-size (4) — independent of direction

A separate axis from direction's `--body-fs` (which sets the *baseline* per layout). Size scales the **whole reading surface** so nothing drops to an unreadable px. Implemented as `zoom` (or a `--scale` font multiplier) on the scroller's content wrapper, **not** by shrinking individual font sizes.

```js
zooms  = [0.9, 1, 1.14, 1.3];                  // cycle
labels = ['Compact','Default','Large','Largest'];
```

### 2.5 Persistence

```js
const PREFS_KEY = 'transcript.prefs';
function loadPrefs(){ try { return JSON.parse(localStorage.getItem(PREFS_KEY)) || {}; } catch { return {}; } }
function savePrefs(p){ localStorage.setItem(PREFS_KEY, JSON.stringify(p)); }
// defaults: { theme:'dark', palette:'Slate', direction:'Console', zoom:1 }
// applyVars() runs on load and on every control change.
```

---

## 3. Type, space, radius, motion

- **Fonts:** `Hanken Grotesk` (UI/body) + `JetBrains Mono` (code, timestamps, token counts, monograms). Pick a sane fallback stack; do not add a third family.
- **Type scale (px):** `10.5 · 11.5 · 13 · 14.5 · 15.5 · 17`. Weights `400/500/600/700`. Body is `--body-fs` (direction-driven); eyebrows are 10.5 caps with `.1em` tracking.
- **Space scale (px):** `4 · 7 · 9 · 13 · 16 · 24 · 30`.
- **Radii:** `--r-sm` and `--r-md` (direction-driven), plus `999px` pills.
- **Motion:** 150 ms default ease; caret/expand 0.18 s. Honor `@media (prefers-reduced-motion: reduce)` → 0. Use flex/grid with `gap` for all groupings (survives DOM edits better than margins).

---

## 4. Component specs (what each block looks like + which vars it reads)

### 4.1 Message turns
- **You:** 9px `--accent` dot + "You" + mono timestamp; body in a `--user-bg` card with `--r-md`, padded `--row-pad`. In Threads it right-aligns via the `--user-*` hooks.
- **Claude:** 9px `--accent2` dot + "Claude · model"; **full-width prose, no card** — hierarchy from the dot + weight, never a background. Body `--body-fs`/`--body-lh`. Render markdown via marked.js; code via highlight.js.
- Both: a copy-as-markdown affordance, top-right.

### 4.2 Tool group
- Header: "**WORKED** · `meter`" with a hairline rule. `meter` = `elapsed · N tools · K tok`.
- Each tool = one row: **monogram tile** (26px, `--r-sm`) · bold name · mono **preview** (ellipsized) · caret. Tap toggles expansion (`transform: rotate(0→90deg)`, expand body fades in 0.18 s). Row padding `--row-pad`, inter-row gap `--tool-gap`.
- Expanded body switches on `body.type` (§1.2): diff / cmd / todo / agent / json.

### 4.3 Event row (expandable)
- `border-left:2px` (var(--border), or **var(--err)** when `event_err`) + uppercase type label + one-line text + timestamp + caret. Tap → detail; failed hooks show `errText` in a `--del-bg` mono block. (Earlier the type label was static — it must be a real toggle.)

### 4.4 Tool monogram + color map
```js
toolMeta = {
  Edit:['ed', accent], MultiEdit:['ed', accent], Write:['wr', accent],   // edits → --accent
  Read:['rd', dim],   Grep:['gr', dim],   Glob:['gl', dim],              // reads → --dim
  Bash:['sh', warn],                                                      // shell → --warn
  Task:['ag', accent2], /* sub-agents */                                  // agent → --accent2
  TodoWrite:['td', dim], WebSearch:['ws', dim], Skill:['sk', dim],
  default:['mcp', accent2]
};
// On the index card, MERGE tools that share a monogram (Task/TaskCreate/TaskUpdate → "ag") before taking the top 4.
```

### 4.5 Masthead (the redesigned summary)
Replaces the old "pill soup." Quiet identity line (`id · branch · live`), then a **token split-bar** (input as `--accent` fill, output as `--accent2` fill, cache as a faint `--accent2` underlay), then **three calm stat tiles** (tool calls / sub-agents / duration). It lives in the scroll body and slides away; the topbar persists.

---

## 5. Navigation model (one reachable system)

1. **Persistent topbar**, two rows + a chip row:
   - Row 1: **‹ back to index** + "SESSIONS" eyebrow + **title**; **theme** quick-toggle on the right.
   - Row 2: **map** button · **search field** (primary, wide) · **text-size** button.
   - Row 3: **filter chips** (You / Claude / Tools / Events, each with a live count; toggling filters the stream and the map).
   - Gains a hairline shadow once scrolled off the top.
2. **Search = find + jump.** Opens full-screen; typing filters to live results; empty query lists every block so it doubles as a jump palette. Tap a result → jump + close.
3. **Session map** (the "ribbon"): blocks shown as small rects, **grouped into per-page boxes**. The **current page's group is highlighted** (accent ring + fill); tapping the group number paginates there, tapping a rect jumps to that block. Item **width scales with tool-count** in that turn (with a count label); error events are red. This is the "feel the weight" overview.
4. **↓ latest** pill — fades in only when scrolled away from the bottom (essential while live-tailing).
5. **Pager** — pinned bottom-center, ≥44px targets, current page filled. (Pagination keeps heavy multi-thousand-block sessions responsive; the map groups mirror the same page boundaries.)

---

## 6. States (build all five)

- **Loading** — skeleton in the *shape* of real turns (dot + prose lines), never a spinner on blank.
- **Empty** — calm "Session is quiet / blocks will appear as Claude works," not an error.
- **Error** — keep the last good render; "Can't reach the session," last-loaded time, Retry. Never a white screen.
- **End of list** — an explicit terminus rule so the scroll feels finite.
- **Live** — new block animates in; if scrolled up, the "N new ↓" count pill (§1.4).

---

## 7. Index page specifics

- **Card = status-first.** Colored status line answers "working / needs me / idle" at a glance. **Needs-you is amber and sorts to the top**, then working, then idle.
- **Weight you can feel:** three tiles (messages · tool calls · out tokens) + the token split-bar + the day-span.
- **What it's been doing:** top-4 tool monograms (merged by glyph) show the shape of the work without opening the transcript.
- **Layout:** full-width stacked on phone (expect **2–7 active** at once), 2-up grid on desktop; "Earlier today" collapses ended sessions into a lighter single-line row.
- A card links into the viewer for that session id.

---

## 8. Build checklist

- [ ] Single HTML file; only `marked.js` + `highlight.js` external; runs over plain HTTP.
- [ ] `/data` parse → blocks → meta pipeline (§1); fixture-test against real `.jsonl`.
- [ ] Four-layer CSS-var cascade (§2) with **theme + palette + direction + size as in-app controls**, persisted to `localStorage`, applied on load.
- [ ] All five block renderers + five tool body renderers (§1.2, §4).
- [ ] Full nav system (§5) and all five states (§6).
- [ ] Live append that never reflows; scroll position persisted per session.
- [ ] Index grid with status sort + 2-up/stacked responsive (§7).
- [ ] `prefers-reduced-motion`, ≥44px touch targets, AA contrast in both themes.

**Server still owns:** live `status` per session, canonical `title` (if you have a better one than first-prompt), and the hook/event schema — confirm those three against your daemon rather than inferring from the log.
