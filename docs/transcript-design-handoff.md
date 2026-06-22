# Handoff brief — transcript viewer UI/UX

> Paste this whole document to claude design. It is self-contained: everything
> needed to propose a UI is here. We have a working implementation we're happy
> with functionally; we want your take on the *design* — layout, hierarchy,
> navigation, component treatments, micro-interactions, and states — so we can
> fold the best ideas back in.

## What this is

A single-file web viewer for a **Claude Code session transcript**: the full
back-and-forth of a coding session (your messages, Claude's replies, the tool
calls Claude ran, and ambient events like permission-mode changes and hook
summaries). It is reachable from a phone over a private Tailscale network and is
the way the owner reads/monitors their coding sessions while away from the desk.

Primary context of use: **reading on a phone**, often **live-tailing** a session
that is still running (new blocks append every few seconds). Secondary: desktop.

## The artifact and its hard constraints

- **One self-contained file**: `lib/transcript-app.html` — HTML + inline CSS +
  inline vanilla JS. No build step, no framework, no bundler. A design proposal
  must be implementable as plain CSS/JS in one file.
- **Served by a tiny Python server** at `http://<host>:5400/s/<session-id>`; the
  page fetches `/s/<id>/data` (JSON) and renders client-side. Often served over
  **plain http on a tailnet IP** (insecure origin), so anything needing a secure
  context (e.g. `navigator.clipboard`) must have a fallback.
- **Dark default + light mode**, toggled and persisted. All color via CSS custom
  properties (`--bg`, `--surface`, `--surface2`, `--text`, `--dim`, `--accent`,
  `--accent2`, `--warn`, `--err`, `--border`, …). A proposal should work in both.
- **Mobile-first**, must also be good on desktop. Touch ergonomics matter (no
  hover-only affordances on touch).
- **Live updates**: the page polls and appends new blocks; layout must not jump,
  and scroll position / expanded state must survive updates.
- Third-party: `marked.js` (markdown) + `highlight.js` (code) from a CDN. That's
  the only dependency budget.

## The data model (what you're laying out)

`/data` returns `{ meta, records }`.

`meta`: `{ ai_title, session_id, model, tokens:{input,output,cache_read},
git_branch, permission_mode, subagent_count, counts:{...}, total_records }`.

`records` is an ordered list of **blocks**, each `{ seq, role, ts, ts_iso, ... }`
where `role` is one of:

- **`user`** — your message. `{ text (markdown), system_reminders (count) }`.
- **`assistant`** — Claude's reply. `{ text (markdown), model, tokens:{in,out,cache} }`.
- **`tools`** — a group of tool calls Claude made. `{ tools: [ {name, preview,
  input, paths, subagent?}, … ] }`. Tool `name` ∈ Bash, Edit, MultiEdit, Write,
  Read, Grep, Glob, WebFetch, TodoWrite, Task, plus MCP tools. For `Edit`/`Write`
  the input carries old/new strings for a **diff**; `Bash` carries a command +
  description; a `Task` carries a **sub-agent** (its own nested transcript,
  fetched lazily from `/data?agent=<id>`).
- **`event`** — ambient: permission-mode change, hook summary (may be an error).
  `{ event_type, text, errors? }`.

So the visual problem: a long, mixed stream of prose turns, dense structured tool
data (diffs, commands, JSON), and small ambient events, that has to read like a
conversation, scale to thousands of blocks, and work on a phone.

## What we've already built (so you improve, not redo)

We did a research-backed pass (calm reading surface + collapse-by-default +
constant feedback). Current state, all live in the file:

- **Reading surface**: capped measure (~720px centered), document-style turns —
  user messages in a subtle rounded shaded block, Claude as full-width body text.
  Reading line-height ~1.6. Hierarchy by weight, not color.
- **Sender headers**: a small colored role dot + name (`You` / `Claude · Opus`) +
  a receding timestamp + a hover-revealed copy-as-markdown button. No id badges,
  no emoji avatars.
- **Tool calls collapse** to a dense one-line row: `kind-icon · name · preview`
  with a caret; tap expands the body (diff / command / JSON). Edits render as a
  colored unified diff; Bash as a command block.
- **Events** are hairline left-border rows, muted.
- **Navigation**: day + idle-gap dividers ("Mon 22 Jun" / "35m later") chunk the
  session; a floating "↓ latest" pill; an activity ribbon (one colored dot per
  block, click to jump) that's collapsed by default; whole-transcript search with
  next/prev; role filter chips (You / Claude / Tools / Events).
- **Chrome**: a sticky topbar (title · model/token/count pills · search · chips ·
  live indicator · theme toggle); pagination as a single bottom-pinned floating
  pill (only when a transcript exceeds one page; default 200 blocks/page).
- **Feel**: global hover/press/focus feedback, one ~150ms motion default,
  `prefers-reduced-motion` respected, loading skeleton, copy-confirm.

Reference screenshots and the research notes can be provided; the current design
already reads far better than a raw log. We are NOT looking to throw this away.

## What the owner wants pushed further (your brief)

Give your version of the design for these, with concrete, implementable specifics
(CSS values, structure, named patterns) — not vibes:

1. **Buttons and badges** — make them feel more crafted. (token/subagent badges,
   the search nav, theme, pager controls.)
2. **The search field** — it still reads a little "dry"; make it inviting and
   clearly the primary find affordance.
3. **Pagination** — should be appealing and stay reachable, pinned at the bottom.
   (We currently float a pill there; propose your take. Note: we are NOT doing
   virtualized infinite-scroll right now, so a paging affordance stays.)
4. **The whole top bar / activity nav** — the owner wants navigation to be
   genuinely easy "no matter where I am in the scroll." Propose how the topbar,
   search, jump-to-latest, day-jumping, and the activity ribbon should work
   together as one coherent, always-reachable navigation system (sticky behavior,
   compaction on scroll, a possible command/jump surface, etc.).
5. **The tagged/structured bits** — collapsed tool rows, badges, diffs, event
   rows. They're coming along; refine the visual edges (radii, spacing, icon
   treatment, color discipline, the expanded-vs-collapsed transition).

Also welcome: anything you'd add that we're missing for *actual phone usage* of a
live coding-session transcript (we deliberately skipped virtualization for now).

## What to deliver

A design proposal we can implement in the one-file constraint:

1. A short **design rationale** (the feel you're going for, and how it serves
   phone reading + live-tailing).
2. A **token/system layer**: type scale, spacing scale, radii, the dark+light
   color roles, motion. Concrete values.
3. **Component specs** for: a message turn (user vs assistant), a collapsed tool
   row + its expanded states (diff, command, JSON), an event row, a sub-agent,
   the day/gap divider, badges.
4. The **navigation system**: topbar (and its scroll behavior), search, the
   activity ribbon, jump-to-latest, pagination — as one coherent model.
5. **States**: loading, empty, error, end-of-list, the live "new blocks" moment.
6. Where useful, small **annotated ASCII/markdown mockups** of the mobile layout,
   and the specific CSS that achieves each effect.

Constraints to honor: one self-contained HTML file, plain CSS/JS, CSS-variable
theming (dark+light), mobile-first + desktop, insecure-http-safe, layout-stable
under live append, marked.js + highlight.js as the only deps.
