# R2 redesign port — plan of record

Porting the round-2 design handoff (this folder) onto the live hub. Decisions
below were confirmed by the owner on 2026-07-13; treat them as fixed.

## Decisions (owner-confirmed)

- Work happens on branch `feat/r2-redesign`. No pushes to main without fresh approval.
- The live variant system is the point: theme × palette × direction × text-size
  as in-page controls, persisted, no reload. It ships with P1, not later.
- `lib/hub-server.py` + `lib/scan.sh` carry uncommitted provider-generalization
  work from another session. Never commit those files from this effort. P1 does
  not need them; P2 (index feed) builds on top once that work lands.
- Prototypes in this folder are the reference, not the shipping code: recreate
  in `lib/`, lifting exact values. Fidelity per README: high — match tokens.

## Priorities

1. **P1 — transcript pass (MUST, fully working).** Replace `lib/transcript-app.html`
   internals with the handoff reader wired to `GET /s/<id>/data`: chapters model,
   masthead + work-proportional spine, activity ledger, all tool bodies, injected
   annotations, event lines, dividers, outline sidebar, chapter bar, Cmd-K search,
   live tail + jump-new, the five states, and the full View panel (4 directions ×
   4 palettes × 2 themes × text size). Desktop + ~720px responsive (phone = P3).
2. **P2 — index pass.** Replace `lib/hub-index.html` with the fleet board wired to
   `GET /api/sessions`: urgency sections, peek panes with live tails, query grammar,
   table density + keyboard nav, hover preview, its View panel (fleet/v5grid/base).
   Needs data work in scan.sh/hub-server.py (state/doing, session-keyed peek tails,
   real recents ids, timestamps for sort) — after provider work lands.
3. **P3 — phone pass (≤390px)** + DIFF.md open items (transcript-scope query fields,
   sub-agent full-transcript escape hatch, wide-artifact bleed).

## P1 build order

1. Contract diff: `transcript.py` output vs README §5 `SESSION`. Adapter layer
   client-side where derivable (chapters, workedMin, userKind); push into
   `transcript.py` only what needs raw-line access (cls typed-vs-injected,
   sidechain flags, per-record tokens if missing). `transcript.py` is clean —
   safe to edit and commit.
4. Port CSS token layer (README §1 tables are canonical; DIFF says all token
   values are final — no retuning).
2. Port the reader JS from `Transcript.dc.html` (renderer + knobs), replacing
   the inlined `window.SESSION` + live simulation with real fetch + poll
   (`?since=` incremental append already exists server-side).
3. Keep lazy sub-agent fetch (`/data?agent=<id>`) instead of the prototype's
   inlined `subagents{}` — better for big sessions; the nested renderer stays.
5. Verify per exercise-based rule: real session, live tail, every direction ×
   theme (8 states minimum) + palette spot-checks, search, spine jumps, states.

## P1 contract diff (transcript.py vs README §5 SESSION) — done 2026-07-13

Verdict: `/data` is already a near-superset. Port with a thin client-side
adapter; no transcript.py changes required to start.

- Present: seq/role/ts/ts_iso/ts_full · text · tokens (assistant {in,out,cache},
  tools {out}) · tools[] {name,id,input,preview,paths,subagent{agentType,
  description,agentId,exists}} · sidechain on every record · system_reminders ·
  event cls (mode/hooks/err) · meta {ai_title, model, git_branch,
  permission_mode, tokens, counts, subagent_count, tools_breakdown,
  total_tool_calls, total_records} · `?since=` incremental.
- Derived in reader (README §5 note): chapter grouping · _workedMin (30-min idle
  clip) · userKind typed-vs-injected (from raw text markers; our text keeps them)
  · timeline buckets · per-chapter top-3 tools / token sums.
- Not inlined: subagents{} — keep lazy `?agent=<id>` (plan decision).
- R2 tool bodies render INPUT only (Bash = command + description; else JSON), so
  round-1's "thread tool_result" backend item is NOT needed for P1.
- Verify against proto map: source of chapter error ticks (event cls 'err' only,
  or also tool_result errors — the latter would need a data change).

## DIFF.md bugs to fix at source (do not re-port)

1. Peek tails keyed by feed position → key by `session_id` (P2, server-side).
2. RECENTS enrichment invented per-page → data layer; recents need real ids (P2).
3. Sort parses display strings → sort real timestamps (P2).
4. Full-board innerHTML rebuild per keystroke; no `visibilitychange` guard on
   streaming (P2, port-time fix).

## Status log

- 2026-07-13: branch created; bundle preserved (`9132456`); plan written.
- 2026-07-13: **P1 core landed** (`9796e12`, `a5ea2e0`). Reader ported onto real
  `/data` + `?since=` polling; sub-agents lazy-load; prototype constants fixed
  (model, dates, byline). Verified live on a real working session: chapters
  light+dark, tty dark, command dark + real timeline, inspector, search (35
  hits), error→Retry recovery, live-append pill, working/your-turn flips.
  P1 punch list still open: editorial/product palettes + light spot-checks
  across directions · kicker "● live" is static (ended-session signal needs
  P2 feed data) · timeline doesn't rebuild on live append (tlBuilt cache,
  prototype behavior) · outline drawer <1100px check.
- 2026-07-13 (later): P1 punch list closed (`3428696`) — timeline live-rebuild
  fixed + verified, palettes + drawer spot-checked. **P2 core landed**
  (`c17ee8d`): fleet index ported onto real /api/sessions; the peek-tail
  server dependency dissolved — tails stream client-side per session via a
  `?since=` probe+slice against the existing /s/<id>/data, keyed by
  session_id, so hub-server.py stays untouched. All four DIFF source bugs
  fixed at the consumption layer. P2 punch list: whole-transcript query
  (currently attrs + streamed tails only, endcap says so) · "ended" state on
  the transcript kicker/badge (feed knows; wire /s page later) · subagent
  transcript rows appear in recents (cwd_short "subagents" — filter or label)
  · v5grid/base directions + light theme + ≤720px spot-checks · limit-meter
  reset countdowns dropped by design (old page had them — confirm with owner).
- 2026-07-13 (evening, owner feedback round, `641e141` + `3af92d8`): SWR tail
  cache (localStorage, prime-before-first-paint, prune) killed the hover
  fill-in reflow; hover preview elevated + position-stable + re-anchored
  across board re-renders; custom SVG favicon (terracotta starburst on slate
  + teal live-dot) on both pages; subagents filtered from recents
  (client-side; scan-side fix waits on provider work); ended-state kicker on
  the transcript wired from the feed; foreign-provider model ids truncated.
  Remaining P2 items: whole-transcript query · limit-meter reset countdowns
  (owner taste call) · scan flake: a live session intermittently drops out of
  one scan cycle (watch; scan.sh is provider-work territory) · boot-only 404
  noise priming foreign-provider recents whose transcripts the hub can't
  resolve. Then P3 phone pass.
- 2026-07-13 (night, feedback round two, `7635f33`): hub query history (last
  10, chips) · transcript-hit deep links (`#r<seq>&q=<term>`) · block
  permalinks ('#' on hover, all directions, `.linked` border on the target,
  chapter fallback for collapsed seqs) · search-term highlighting (shared by
  the transcript search modal and hub deep links) · timeline toggle persists
  as user override (the "editorial variant" report — presets were resetting
  it) · view-panel option icons · View Transitions crossfade on look changes
  (owner to judge the feel). NOTE: the running hub process predates the
  no-store header — pages can serve stale from browser cache until the hub
  restarts (which should wait for/accompany the provider work landing).
