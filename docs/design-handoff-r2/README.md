# Claude Code Session Viewer — Engineering Handoff

Two design-reference prototypes plus the specs to rebuild them in a real codebase.

## What's in this folder

| File | What it is |
|---|---|
| `Transcript.dc.html` | The single **transcript reader**, self-contained (real session data inlined). Open in any browser. |
| `Session Index.dc.html` | The single **fleet index** reader, self-contained. |
| `README.md` | This file — design tokens, component specs, navigation model, states. |
| `DIFF.md` | What changes vs. the current `redesign/` implementation, and what survives. |

**About these files.** They are **design references authored in HTML**, not production code to ship. Each is one self-contained document: inline CSS/JS, real session data inlined, and **only two external dependencies — `marked` (markdown) and `highlight.js` (code), both from a CDN.** The task is to **recreate these designs in the target codebase** (React/Vue/Svelte/native — whatever the app uses), lifting the exact values below. They open directly in a browser regardless of the `.dc.html` name.

**Fidelity: high.** Colors, type, spacing, radii, and motion are final. Match them.

**Why one reader with knobs.** Every earlier variant (V1–V6) is reproduced as a **preset of geometry knobs over one reader**, not as a separate renderer. The in-file **View panel** (top-right gear) flips four independent axes live, with no reload:

- **Theme** — `dark` | `light` (class `.light` on `<html>`)
- **Palette** — `native` | `tty` | `editorial` | `product` (`data-skin` on `<html>`; pure color)
- **Direction** — the geometry preset (`data-dir` on `<html>` + JS flags)
- **Text size** — prose size (transcript) / UI scale (index)

All four persist to `localStorage` and are applied before first paint (no FOUC).

---

## 1. Design tokens

### 1.1 Identity colors (semantic — never repurpose)

| Token | Role | Dark (native) | Light (native) |
|---|---|---|---|
| `--you` | user / prompts / "your turn" | `oklch(0.76 0.15 268)` | `oklch(0.46 0.16 268)` |
| `--claude` | assistant / "working" | `oklch(0.76 0.14 180)` | `oklch(0.46 0.15 180)` |
| `--tool` | tool calls **only** | `#e2b05b` | `#7e5d0e` |
| `--err` | errors **only** | `#ea8578` | `#b23f33` |
| `--add` | diff additions | `oklch(0.75 0.14 142)` | `oklch(0.46 0.14 142)` |
| `--del` | diff deletions | `#ea8578` | `#b23f33` |
| `--meta` | git / branch hint | `oklch(0.74 0.11 305)` | `oklch(0.46 0.13 305)` |

Soft/ring variants are derived, not hand-set — keep them as `color-mix` so they track the base:
```
--you-soft:   color-mix(in srgb, var(--you) 10%, transparent)
--you-ring:   color-mix(in srgb, var(--you) 40%, transparent)
--claude-soft:color-mix(in srgb, var(--claude) 12%, transparent)
--tool-soft:  color-mix(in srgb, var(--tool) 12%, transparent)
--err-soft:   color-mix(in srgb, var(--err) 10%, transparent)
--mark: rgba(226,176,91,.3)   /* search highlight (light: rgba(216,160,32,.32)) */
```

### 1.2 Neutral ramp — per palette × theme

Identity hues are **constant across palettes**; only the neutrals (surfaces, edges, text tiers) change. `--bg` = page, `--panel` = card/raised, `--well` = inset/sunken, `--sel` = hover/selected, `--edge`/`--edge2` = hairline/stronger.

**native** (editorial dark house / warm paper light)
| | dark | light |
|---|---|---|
| `--bg` | `#191a21` | `#faf9f6` |
| `--panel` | `#21232c` | `#f1efe9` |
| `--well` | `#1d1f27` | `#f4f2ed` |
| `--sel` | `#2b2d38` | `#e8e5dd` |
| `--edge` | `rgba(200,205,225,.13)` | `rgba(35,32,24,.13)` |
| `--edge2` | `rgba(200,205,225,.24)` | `rgba(35,32,24,.26)` |
| `--text` | `#edeef4` | `#1e1f24` |
| `--dim` | `#a2a7b8` | `#565b68` |
| `--faint` | `#676d80` | `#8e93a1` |

**tty** (terminal, cool neutral)
| | dark | light |
|---|---|---|
| `--bg` | `#14161e` | `#f6f6f7` |
| `--panel` | `#1d212c` | `#ecedef` |
| `--well` | `#191c26` | `#f0f0f2` |
| `--sel` | `#2a2f3d` | `#e2e4e8` |
| `--edge` | `rgba(190,200,235,.17)` | `rgba(30,34,48,.16)` |
| `--edge2` | `rgba(190,200,235,.30)` | `rgba(30,34,48,.30)` |
| `--text` | `#eef1f9` | `#1e2027` |
| `--dim` | `#aeb7cc` | `#545866` |
| `--faint` | `#6f7994` | `#82879a` |
| `--tool` | `#e2b05b` | `#8a6410` |

**editorial** (same identity as native; kept selectable for parity)
| | dark | light |
|---|---|---|
| `--bg` | `#191a21` | `#faf9f6` |
| `--panel` | `#21232c` | `#f1efe9` |
| `--well` | `#1d1f27` | `#f4f2ed` |
| `--sel` | `#2b2d38` | `#e8e5dd` |
| (edges/text tiers as native) | | |

**product** (neutral app dark / clean light)
| | dark | light |
|---|---|---|
| `--bg` | `#171923` | `#f2f4f8` |
| `--panel` | `#1f222c` | `#ffffff` |
| `--well` | `#1c1f28` | `#eceef4` |
| `--sel` | `#2a2e3a` | `#e7eaf1` |
| `--edge` | `rgba(178,190,225,.12)` | `rgba(22,28,45,.13)` |
| `--edge2` | `rgba(178,190,225,.22)` | `rgba(22,28,45,.24)` |
| `--text` | `#e8ebf3` | `#1a1c23` |
| `--dim` | `#99a0b4` | `#5f6575` |
| `--faint` | `#6d7488` | `#8a90a0` |
| `--you` | `oklch(0.72 0.13 268)` | `oklch(0.50 0.15 268)` |
| `--claude` | `oklch(0.72 0.13 180)` | `oklch(0.50 0.15 180)` |

> **Palette law (from the review):** a palette is **color only**. Register (serif/sans/mono) is a *direction* knob, never a palette one. Amber (`--tool`) is for tool calls only; red (`--err`) for errors only; blue is the user; teal is Claude. Don't spend an identity hue on anything else.

### 1.3 Type scale

Fonts:
```
--sans:  ui-sans-serif, -apple-system, "Segoe UI", sans-serif
--serif: ui-serif, Georgia, "Iowan Old Style", "Times New Roman", serif
--mono:  ui-monospace, "SF Mono", Menlo, Consolas, monospace
```

**Transcript** (`--fs-prose` 15.5px default, range 13–19; `--lh-prose` 1.68; `--measure` 640px)
| Element | Font | Size / line | Weight |
|---|---|---|---|
| Masthead title | serif | `clamp(22px,4.6vw,30px)` / 1.22 | 600 |
| Chapter title | serif | 19px / 1.35 | 600 |
| Prose body | sans | `var(--fs-prose)` / 1.68 | 400 |
| Prose h1/h2 | serif | 17px / 1.4 | 600 |
| Prose h3/h4 | sans | 15.5px / 1.4 | 600 |
| Prose code / pre | mono | 13px / 1.6 | 400 |
| Byline / meta | mono | 11px | 400; "who" 10.5px 700 uppercase |
| Ledger + tool rows | mono | 12px | tool name 700 |
| Token/ts micro | mono | 10.5px | — |
| Kickers / section caps | mono | 10.5px, `.12–.14em`, uppercase | 700 |

**Index** (body 14.5px/1.55 sans; text-size = UI scale via `zoom` on `#main`, range 12–18)
| Element | Font | Size / line | Weight |
|---|---|---|---|
| Page h1 | sans | 21px / 1.2 | 650 |
| Pane title | sans | 14.5px | 650 |
| Table dir cell | mono | 12.5px | 700 |
| Peek tail lines | mono | 11.5px / 1.65 | 400 |
| Meters / meta | mono | 10.5–12px, tabular-nums | — |
| Section headers | mono | 10.5px, `.12em`, uppercase | 700 |

### 1.4 Spacing, radius, motion

- **Spacing rhythm** (px): `2 4 5 6 8 9 10 12 14 16 18 20 22 26 30 44`; flex/grid `gap` 3–18px. Reading column capped at `--measure`; page frame padding 18–20px.
- **Radius:** `--r` = 8px (transcript) / 10px (index); pills `999px`; chips/wells 4–6px.
- **Motion:** `--ease: cubic-bezier(.2,0,0,1)` · `--t-fast: 130ms` · `--t-slow: 260ms`. Named keyframes: `pulse` 2s (working dot), `fresh` `--t-slow` (new content), `flash` 1.1s (jump target), `blink` 1.1s steps(1) (live cursor), `shimmer` 1.4s (skeleton).
- **Shadow:** `--shadow: 0 10px 32px -12px rgba(0,0,0,.6)` (dark) / `rgba(30,40,70,.24)` (light).
- **Topbar height:** `--tb-h: 44px`. **Focus ring:** `2px solid var(--you)`, offset 2px, `:focus-visible` only.

### 1.5 Per-direction geometry hooks

**Transcript** — one reader; a direction sets these:
| Direction (origin) | `--measure` | sidebar | tool-row | timeline | display font |
|---|---|---|---|---|---|
| **chapters** (V3) | 640px | on | `well` (fold to one ledger line per run) | off | serif titles |
| **command** (V5) | 720px | off | `card` (bordered group + aggregate footer) | on | sans titles |
| **tty** (V2) | 900px | off | `bare` (rows on a rail, no container) | off | mono display; **prose stays sans** (hybrid per review) |
| **inspector** (V1) | 680px | on | `card` | off | sans; `--lh-prose` 1.56 (denser) |

tool-row rule baked in: a **single-tool run renders as a bare row** (no card, no footer); footers only aggregate (≥2 tools).

**Index** — one board; a direction sets these:
| Direction (origin) | grouped | layout | query | sort |
|---|---|---|---|---|
| **fleet** (V6) | yes (Needs you → Working → Ended) | `auto` (density toggle: peeks/table) | on | on |
| **v5grid** (V5) | no (flat) | `grid` (peek panes) | on | off |
| **base** | no (flat) | `table` (one dense table incl. ended) | off | off |

---

## 2. Component specs

### 2.1 Transcript blocks

- **Masthead** — kicker (`● live · claude code session · <id8>`, mono 10.5px uppercase) → serif title → byline chips (model=teal, branch=violet, permission=amber; icon tinted, value a whisper of the hue mixed 40–45% into `--dim`) → colophon stat row (chapters · tool calls · agents · ↓in ↑out · cache; `↓` tinted `--you`, `↑` tinted `--claude`) → **progress spine**.
- **Progress spine** — one segment per chapter; **width ∝ work**: `flex: sqrt(1 + tools*2 + toks/1500 + mins*3)`. Done segments `color-mix(--you 45%, --sel)`; current solid `--you`; error chapters carry a top-right `--err` dot. Click → jump. Segments never narrower than 4px.
- **Chapter head** — 2-char number (`--you`, mono 700) + serif title; optional `/command` chip (`--you` on `--you-soft`); meta line (ts · worked Nm · N tools · N agents · ↑toks · top-3 tools · N reminders · **N errors in `--err`**). Long typed prompt → **epigraph**: `--you` left rule, clamped to 7.2em with a linear-gradient mask + "show full prompt".
- **Claude passage** — byline (`claude` in teal uppercase · `opus · ↑toks` · optional `↳ sidechain` · ts · hover "copy") + markdown body (`marked` → sanitized → `hljs`). Reading column = `--measure`.
- **Activity ledger** (well direction) — one `--well` card per run of consecutive tools/events: gear icon in `--tool-soft`, one-line summary (`worked Nm · Tool ×k … · ↑toks · N errors`), chevron. Expands to tool rows.
- **Tool row** — fold caret · name (`--tool`, agents `--claude`) · path/preview (dir `--faint`, basename `--text` 600) · `↑toks`. Expands to **tool body**:
  - Edit/MultiEdit → computed diff (`--add` +, `--del` −, context `--faint`).
  - Write → "new file · N lines" + all-green body.
  - Bash → `$ command` (prompt `--claude`) + description caption.
  - TodoWrite → checklist (done strike + green ✓, active bold + teal ▸, pending dim ○).
  - Agent/Task → **nested transcript**: dashed `--claude` left rail, honesty note `↳ type · desc · N/M blocks`, then the sub-agent's own turns (prose in sans).
  - else → pretty-printed JSON input.
  - Body scroll cap: `max-height: 360px`, inner scroll.
- **Injected annotation** — command expansions / skill preambles are **not** chapters: a faint mono row `▸ injected · skill preamble · N lines · N reminders`, expands behind a dashed rail. (Chapter titles come from typed content only.)
- **Event line** — permission/mode changes stay **visible outside the fold**: `· <text>` with right-aligned ts; errors are `▲` in `--err`.
- **Dividers** — day (`Thursday, 19 June`) / idle (`38 minutes pass`), centered mono caps between rules.
- **Overview chrome** — outline sidebar (≥1100px persistent, else drawer + scrim) of chapter items; bottom **chapter bar** (prev · `n/N` · next); **search modal** (Cmd-K / `/`) full-session, role-tagged hits, ↑↓/↵; **jump-new** pill during live tail.

### 2.2 Index blocks

- **Topbar** — brand + host · `N live` (teal pulse chip) · `N your turn` (blue chip) · sort select (if direction) · density toggle (fleet only) · View · theme.
- **Masthead** — `Sessions` h1 + limit meters (`5h`, `7d`: bar + %, warn ≥70% amber / hot ≥90% red) + today rollup.
- **Query bar** (fleet/grid) — fields `model: branch: dir: state:` + free text over session attributes **and** transcript content; live `n/N match`; tappable `try …` example chips.
- **Peek pane** — head (state dot · title · model chip · state · elapsed) / **live tail** (mono, block-cursor on the last line for working; last-exchange + "your turn" for idle; adaptive height so idle panes aren't dead air) / optional transcript-hit / MCP-down alert / foot (ctx bar warn/hot · ↑tok · $ · turns · ↳agents · ⎇ branch with `*modified` in amber).
- **Table row** — state dot · dir · model · state+doing · ctx gauge · $ · turns · branch · elapsed; MCP-down inline under the row (proximity). **Hover/cursor → floating preview** (`.hpk`) with the live tail, desktop only (≤1020px disabled).
- **Section header** — `Needs you` (blue) / `Working` (teal) / `Ended` (faint), count pill + rule. Urgency maps to vertical order.

---

## 3. Navigation model

```
Session Index  ──click pane/row──▶  Transcript (opens that session)
     ▲                                   │
     └──────── "‹ sessions" back ────────┘
```

**Within a transcript:** outline click → chapter · spine segment click → chapter · chapter bar prev/next (`[` `]`) · search (`Cmd/Ctrl-K` or `/`) → jump to record `seq` (flash target) · timeline click → nearest record · live append with "N new" jump pill.

**Within the index:** `↑`/`↓` move cursor (both densities), `↵` open, `d` density, `t` theme, `/` focus query. Selection shows the hover preview for the cursored row.

**View panel** (either page): Direction / Palette / Theme / Text-size, persisted; independent of navigation.

Deep-link targets to preserve when rebuilt: session id → transcript; record `seq` → scroll target (`[data-seq]`); chapter index → outline/spine sync on scroll.

---

## 4. The five states (each page)

1. **Loading** — skeleton that **mirrors the final layout** (masthead bar + spine + first passages for transcript; header + 3 pane ghosts for index), `shimmer` animation. Not a spinner.
2. **Normal** — the reader.
3. **Empty** — transcript: "Nothing written yet / chapter one appears with your first prompt". Index: ghost pane + "No sessions running".
4. **Error** — transcript: "Couldn't load the session · GET …/data → unreachable · retrying keeps what's on screen" + Retry. Index: "Can't reach the session server" + Retry; **the last good board stays on screen** while retrying.
5. **Live tail** — working → your turn transition; new records append with `fresh`, a `new` marker, and a jump-new pill when scrolled up; working sessions show a blinking block cursor.

Per-session states carried in data: `working` (teal, pulsing) · `idle`/your-turn (blue) · `ended` (faint); context `warn`/`hot`; `mcp_down`; `git_modified`.

---

## 5. Data contract

Both readers read one object (inlined here as `window.SESSION` + `window.FEED`; in the app these are two endpoints):

- **`SESSION`** — `meta` (session_id, model, git_branch, permission_mode, tokens{input,output,cache_read}, counts, subagent_count, total_records) · `records[]` (each `{seq, role: user|assistant|tools|event, ts, ts_iso, text?, tokens?, tools?[], cls?, system_reminders?, sidechain?}`) · `subagents{agentId → {meta, records[]}}`.
- **`FEED`** — `live[]` (session cards: session_id, cwd_short, cwd, model, state, ctx_remaining, output_tokens, cost_usd, turns, subagent_count, git_branch, git_modified, elapsed, last_prompt, doing, mcp_down?) · `recent[]` · `limits{5h,week}` · `aggregates.today`.

Derived-in-reader (document these when porting): `_workedMin` (gap to next record, **clipped at the 30-min idle threshold** so idle time isn't counted as work), chapter grouping, `userKind` (typed vs injected), timeline buckets. See `DIFF.md` for the derivation bugs to fix at the source rather than re-porting.
