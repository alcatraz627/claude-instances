# R2 — stable record identity for the live tail

<!-- sessions: cl-inst-ce@2026-07-17 -->

Design for remaining-work task #17. `seq` is positional: `next_seq()` numbers
records by parse order, so a mid-file insert renumbers every later record. The
client treats `seq` as identity (`lastSeq` cursor, merge by `seq`, expansion
keys), so a renumber duplicates the tools group and silently drops the
genuinely-new record — reproduced by the audit's reviewer in a real browser.
Unreachable today (Claude Code appends), so this is hardening, not a live lie.

## Identity source, per record type (verified against real transcripts)

Three real transcripts, 2563 content lines: every user/assistant/system line
carries a unique `uuid` (0 duplicates); tool_use blocks carry API-issued
`toolu_*` ids. The uuid-less line types are metadata sidecars (`mode`,
`custom-title`, `file-history-*`, …) of which exactly one becomes a record:
the mode-change event.

| record kind | `id` | fallback (source field absent) |
|---|---|---|
| `user` | line `uuid` | `u:<ts_iso>:<crc32 of content>` |
| `assistant` | line `uuid` | same shape, `a:` prefix |
| `tools` group | first member's `toolu_*` id | first member's line `uuid`, then `t:` shape |
| `event` mode-change | `mode:<last-uuid-line>:<new-mode>[:<ordinal>]` | n/a |
| `event` hook-summary | line `uuid` | `hook:<ts_iso>:<crc32>` |

Mode lines turned out to carry no uuid AND no timestamp (`{type, mode,
sessionId}` only — the first cut used `mode:<ts>:<pm>` and collided on real
data as `mode::auto`). Their identity anchors to the last uuid-bearing line,
with an ordinal for repeated identical flips under one anchor: deterministic
across re-parses, stable under appends.

Honest limit (validated adversarially, worse than first stated): under a
mid-run REWRITE, ordinal ids do not merely change — they REASSIGN. Inserting
a flip into a repeated-flip run gives every later same-value flip in that run
an id that previously named a DIFFERENT event, so a stale cursor still
resolves (no cursor_reset) and the client re-renders the shifted events once.
Blast radius: bounded by one anchor's run of identical flips; repeated
identical events carry no distinguishing content, so position-free identity
for them is impossible in principle. Accepted because a mid-file rewrite is
unreachable today (Claude Code appends) and the failure is a transient
duplicate render of mode chips, not data loss.

The tools-group choice is load-bearing: a group flushed `open` keeps growing on
later reads, but its FIRST member never changes in an append-only file, so the
id is stable while the group grows — exactly the property the live tail needs.

Fallbacks are content-derived (timestamp + kind), never positional. They can
collide only if two same-kind records share a millisecond timestamp AND both
lack their primary id — accepted: today zero real lines lack them.

## Contract changes

1. **transcript.py** — every record gains `id` alongside `seq`. `seq` stays:
   ordering, `data-seq` DOM anchors, and `#r<seq>` deep links depend on it and
   positional is CORRECT for those (an anchor names a position in the rendered
   document, not an identity).
2. **hub-server.py `/data`** — `since` (seq) stays for back-compat and the
   index page's tail probe. New optional `after_id=<id>`: slice strictly after
   the record with that id. Unknown/vanished id → full record set plus
   `"cursor_reset": true` in meta, so the client reconciles by id instead of
   trusting a broken cursor. The `open`-group resend rule applies to both
   cursor forms.
3. **transcript-app.html** — the merge keys move from seq to id:
   `refreshOpen`'s `findIndex(x => x.seq === r.seq)` → `x.id === r.id`;
   `pollLive` tracks `lastId` (cursor) + merges fresh/tail by id, deduping on
   arrival so a resend can never render twice; `state.expanded` keys
   `seq + ':' + i` → `id + ':' + i` so expansion survives a renumber.

## Out of scope, stated

- `hub-index.html`'s `?since=` probe+slice tail stays seq-based — it renders a
  short preview, worst case a transient duplicate line in a card preview.
- `transcript.py --since` CLI parity (R3.6) is a separate small task; it gains
  `or r.get("open")` there, not here.
- No migration of persisted client state: `hub-tail-v2` SWR cache entries key
  by sid and self-heal on the next poll.

## Verification plan

- Extend `tests/fixtures/since-probe.py`'s growing-fixture loop with a
  renumber scenario: parse, insert a line mid-file, re-parse — assert (a) ids
  of pre-existing records unchanged, (b) id-merge neither duplicates nor drops,
  while the old seq-merge provably does both (the red proof).
- Guard that every emitted record has a non-empty `id`, and ids are unique
  within a parse.
- Browser exercise of the live tail after the change (hub serves from disk).
