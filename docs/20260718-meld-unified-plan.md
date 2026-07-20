# claude-instances × claude-ipc — the meld plan, v2 (planner + implementer)

<!-- sessions: cl-inst-ce@2026-07-18 -->

**v2, 2026-07-18.** Supersedes v1 in place (v1 preserved at commit `d4628b0`).
v1 was deliberated by a five-voter magi panel (archive:
`~/.claude/assets/magi/20260718-1533-meld-unified-plan/`, verdict
EXECUTE-AMENDED, winner voter-1 at 4.72 matching the supervisor nomination).
Every panel amendment is folded in below and marked `[mX]` where it changed
v1. This version adds the implementation layer: code map, handshake, schemas,
heartbeat and staleness model, data flows, UI component spec, runbook, tests.

---

## 1 · Intent and governing constraint (unchanged)

The owner wants the cross-cutting value of the two matured systems without
coupling risk, and would rather keep two functional systems than gain a
clobbered mess. Every item below grades against the four-axis rubric in
order: standalone survival, reversibility, blast-radius containment, value.
The owner is the daily user of both surfaces; the currencies are owner-time
and owner-trust, and a self-inconsistent number costs more than a crash.

## 2 · Doctrine v2 (binding)

1. **Bridge, not merge.** No shared code, storage, or process. Shared
   surface: ONE read-only contract (the digest, §5) plus the existing
   `~/.claude-ipc/alias-by-sid/` side-file convention. `[m: Surface 1
   (/api/sessions for the oracle) is REMOVED from the contract until the
   oracle is seriously tabled — half of v1's Phase 0 had no consumer.]`
2. **One writer per fact, one direction per flow, no round-trips.** Physical
   truth flows instances→ipc only via the deferred oracle (not built);
   social truth flows ipc→instances via the digest. The hub never re-imports
   broker liveness for its own cards. Directionality is PINNED BY TEST
   (§11.5), not prose. `[m]`
3. **Push/pull by audience.** Agents get obligations pushed (ipc wake
   hooks); the human gets them pulled (cards, mailroom). Nothing an agent
   requires may ever be delivered via the hub.
4. **Advisory before authoritative; absence degrades to today, never to
   wrongness.** Every bridge payload carries `ts` + `protocol_version`;
   consumers enforce max-age; UNKNOWN renders as unknown, never as 0.
   Staleness and skew are PINNED BY FIXTURE (§11.2-11.3). `[m]`
5. **Additive-by-construction, asserted in BOTH directions**: hub renders
   fully with the broker stopped; broker delivers fully with the hub absent.
   Both are shipped red-provable tests (§11.1). `[m]`
6. **Session UUID + cwd are the only join keys.** Aliases and roles are
   display strings at the seam.
7. **Isolation for tooling.** Cross-system rigs use scratch brokers (own
   socket) and scratch hubs (own 62xx port via ports.sh); never live control
   files. Mirrored into both repos' validator dispatch templates.
8. **Process-cost honesty.** `[m, from the jester]` Kill switches revert
   code, not obligations: the contract review discipline, once adopted, is a
   permanent cost both repos carry. It is accepted, and it is the plan's one
   irreversible price. Every NEW bridge beyond B1-B6 requires the §1 rubric
   in writing AND a passing directionality/additive test before merge.

## 3 · Component and code map `[new in v2]`

| Component | Repo | File(s) | Owner |
|---|---|---|---|
| Digest verb `digest --project` | claude-ipc | `src/cli.ts` (verb), `src/broker/` (query), spec at `docs/contracts/hub-digest.md` (CANONICAL) | ipc lane |
| Alias→sid reverse-join | claude-ipc | broker-side, reading `~/.claude-ipc/alias-by-sid/` | ipc lane |
| Machine-wide awaitings verb `asks --all --json` | claude-ipc | `src/cli.ts` + storage read (today `openAwaiting` is a PRIVATE method — `src/storage/sqliteBackend.ts:299`; this verb is NEW work) `[m]` | ipc lane |
| contextPtr population | claude-ipc | send path; derive-from-sid rule §5.4 | ipc lane |
| Scan-side digest consumer | claude-instances | `lib/scan.sh` `get_ipc_info` successor (`get_ipc_digest`), replaces per-alias `count` subprocess | instances lane |
| Per-card overlay + obligations block | claude-instances | `lib/hub-index.html` (cards), `lib/scan.sh` (fields) | instances lane |
| Mailroom badge + page | claude-instances | badge: `lib/hub-index.html`; page: `lib/hub-mailroom.html` + `lib/hub-server.py` route `/mailroom` (server stays read-only; page fetches broker data via server-side subprocess with the same timeout discipline) | instances lane |
| Disagreement counter (truth-diff data) | claude-instances | `lib/scan.sh` (compare pid-truth vs digest liveness claim), counter file `~/.claude/widgets/.ipc-disagreements.jsonl` | instances lane |
| Deep-link render + not-found | claude-instances | `lib/transcript-app.html` (`#r<seq>` exists; add graceful miss), hub link derivation in ipc's wake frames | both (display only) |
| Contract fixtures | both | `tests/fixtures/ipc-digest-fixture.json` (instances) · `test/fixtures/hub-consumer.json` (ipc) | each repo vendors |
| Runbook | claude-instances | `docs/meld-runbook.md` (§10 is its seed) | instances lane |

## 4 · The handshake `[new in v2]`

**Version negotiation (every digest call):** response carries
`protocol_version` (ipc's existing constant) and `contract_version`
(integer, starts at 1, additive-only). The consumer accepts
`contract_version ∈ {N, N-1}` and ignores unknown fields; anything else
renders the whole payload as state `skew` (§7), never a partial parse.
N-1 tolerance is what makes the two repos' independent deploys safe: every
ipc redeploy is a skew window by construction (local-branch launchd
restarts), so skew is a STEADY STATE to render, not an error to page on.

**Deploy sequencing handshakes (no lockstep, ever):**
- B3 obligations-on-cards ships only after `askState` is observed in a real
  digest response (the hub probes for the field; absence = feature stays
  dark). The hub NEVER errors on its absence.
- The mailroom page ships only after `asks --all --json` exists (probed the
  same way).
- A `can-i-deploy` check (one script per repo, run pre-merge) diffs the live
  peer's response against the vendored fixture: real ⊇ fixture fields, or
  the merge is flagged. Runs where both peers are present; skips LOUDLY
  (exit 0 with a printed SKIPPED line) otherwise. `[m]`

**Coworker-rebuild freeze:** `[m]` B2/B3/B4 pin to ipc's Step-0 obligation
shape (`corr_id, kind, age_s, reply_by_s, ask_state`). Fields added by
coworker features 1-5 (priority, topic, lane, claims) are IGNORED by the
bridge until a deliberate contract_version bump — stable keys are not
enough; the rebuild changes value SEMANTICS (v3's stable-key/moving-meaning
finding).

## 5 · Schemas `[new in v2]`

### 5.1 Digest response (`claude-ipc digest --project <cwd> --json`)
```json
{
  "protocol_version": "<ipc constant>",
  "contract_version": 1,
  "ts": "2026-07-18T10:00:00.000Z",
  "sessions": {
    "<session-uuid>": {
      "aliases": ["vb-opus"],
      "role": null,
      "liveness_claim": "live|idle|offline",
      "unread": 3,
      "owed": [
        {"corr_id": "msg-…", "kind": "query", "age_s": 1200,
         "reply_by_s": 300, "ask_state": "open|responded|cancelled|parked"}
      ],
      "waiting_on": 1,
      "orphaned_in_cwd": 0,
      "oldest_deadline_s": 300,
      "chase_noise_folded": 4
    },
    "_unresolved": {
      "aliases": ["clade-ipc"],
      "note": "obligations whose alias has no alias-by-sid entry; bucketed, never dropped"
    }
  }
}
```
Rules: keyed by session uuid via the broker's reverse-join over
`alias-by-sid`; an obligation whose alias resolves to no sid lands under
`_unresolved` (visible in the mailroom, never silently dropped) `[m]`.
Unknown/missing numeric values are `null`, never 0. `liveness_claim` is
ipc's OWN heartbeat view, included so the hub can diff it against pid truth
(§8.4) — the hub displays it only inside the disagreement UI, never as the
card's liveness (doctrine 2).

### 5.2 Machine-wide awaitings (`claude-ipc asks --all --json`) `[new verb]`
```json
{ "protocol_version": "…", "contract_version": 1, "ts": "…",
  "asks": [ {"corr_id": "…", "from_alias": "…", "to_alias": "…",
             "to_sid": "…|null", "kind": "query|request",
             "age_s": 0, "reply_by_s": 0, "nudge_stage": "none|nudge|last-call|parked",
             "ask_state": "open|responded|cancelled|parked",
             "project_cwd": "…"} ],
  "orphans": [ {"alias": "…", "sid": "…|null", "cwd": "…",
                "real_mail": 2, "chase_noise": 4, "oldest_ts": "…"} ] }
```

### 5.3 Scan-side derived fields (added to each live card's JSON)
`ipc: { alias, role, unread, owes, oldest_owed_age_s, deadline_s,
waiting_on, state }` where `state ∈ fresh|stale|skew|unreachable` (§7) and
every numeric is `null` under any state but `fresh`. Swift bar safety:
additive optional fields only; Codable ignores unknown keys.

`[impl 2026-07-20, instances side]` Two deviations as built, both
deliberate: (1) the wire keeps the already-shipped field name **`inbox`**
for what this section calls `unread` — the page reads `inbox`, and renaming
a live wire field is a stale-reader hazard for zero value; (2) the
null-unless-fresh sentence above CONTRADICTED §7's "stale → render values
dimmed", and §7 wins — **stale carries values** (plus `age_s` for the
"as of" render); skew/unknown/unreachable carry null. Extra fields as
built: `source: 'digest'` (absent on the count path — its absence IS the
dark-launch signal), `age_s`, and `disagree {claim, kind, scans}` after the
§8.4 two-scan debounce.

### 5.4 contextPtr (deep links) `[m — resolved]`
No schema change. The hub link derives from the EXISTING
`contextPtr.sessionId`: `http://<host>:5400/s/<sessionId>`. Record-precise
`#r<seq>` is dropped in v1 of the links (the field for it does not exist);
adding `contextPtr.recordId` later is a declared additive change. The
transcript viewer renders a calm "record not found" for any dead anchor.

### 5.5 Disagreement counter record (one JSONL line per event)
```json
{"ts": "…", "sid": "…", "pid_truth": "live|gone",
 "ipc_claim": "live|idle|offline", "kind": "stale-registration|unregistered-session|orphaned-alias",
 "raw": true}
```
Raw = pre-debounce, always logged `[m — the oracle gate reads THIS stream,
never the debounced display]`.

## 6 · Heartbeat model (documented, unchanged by the bridge)

ipc heartbeats: Stop-hook emits per turn; the broker ages liveness from
last-seen. Known-wrong cases (why the meld exists): a session mid-long-turn
reads offline; a crashed session reads live until age-out; registry pid is
often null and never process-checked. The bridge does NOT alter this
mechanism — it renders pid-truth beside it (B1) and counts disagreements
(§5.5). The broker oracle that would REPLACE it stays deferred (§13).

## 7 · Bridge staleness state machine `[new in v2]`

Per digest payload, evaluated at consume time:

```
fresh        ts age ≤ 30s AND contract_version ∈ {N, N-1}   → render values
stale        30s < age ≤ 120s                               → render values dimmed + "as of <age>"
unknown      age > 120s OR parse failure OR timeout          → all values null; "ipc: unknown"
skew         contract_version ∉ {N, N-1} OR PROTOCOL mismatch→ "ipc: version skew" (DISTINCT from unknown) [m]
unreachable  spawn failure / non-zero exit                   → "ipc: unreachable"
```

Timeout: the digest subprocess is capped at **2s** (matching the scan's
existing ipc posture), and a scan-returns-under-hang test pins it (§11.6)
`[m — v1 never named the number]`. Degraded-duration alert: any state other
than `fresh` persisting > 24h surfaces a one-line banner on the hub INDEX
page (the surface the owner actually watches), not only inside a panel
`[m — silent graceful degradation is itself the B3 bug]`.

## 8 · Data flows `[new in v2]`

```
8.1 scan loop (every full scan, quick mode skips)
  scan.sh ──spawn(≤2s)── claude-ipc digest --project <cwd> --json
     │ parse defensively → state machine §7
     ├─ per-card ipc fields (§5.3)
     ├─ badge aggregate (Σ owed+unread across live cards)
     └─ §8.4 disagreement pass

8.2 mailroom page view (per page load, NOT in the scan loop)
  GET /mailroom → hub-server (read-only) ──spawn(≤2s)── asks --all --json
     └─ render sections; broker down → honest banner

8.3 message deep link
  ipc wake frame carries http://host:5400/s/<sid> (derived, §5.4)
     └─ transcript viewer; dead anchor → "record not found"

8.4 disagreement pass (inside 8.1)
  for each sid: pid_truth(scan) vs liveness_claim(digest §5.1)
     ├─ disagree → append RAW line (§5.5) → counter
     ├─ same disagreement in 2 consecutive scans → display flag on card
     └─ counter ≥ threshold sustained → (future) justifies panel/oracle talk
```

## 9 · UI component spec `[new in v2]`

**Hub index header:** mailroom badge `📬 N` (owed+unread across live
sessions, from 8.1; state≠fresh renders `📬 ?` with tooltip naming the
state). Click → `/mailroom`. Degraded-duration banner slot under the header
(§7). Effort note: badge ships in Phase 1 sourced from the existing
side-file+count join; switches to digest data in Phase 2 transparently.

**Live cards:** existing alias chip stays. New (Phase 2+, digest-gated):
`owes 2 · oldest 20m · ⏱ 4m` line (null-safe: absent under any non-fresh
state); `waiting on 1`; disagreement flag `⚠ ipc thinks offline` after the
2-scan debounce, tooltip shows both authorities + timestamps. Role chip
(Phase 5, B6): `main`/`assistant` before the alias, only when `role` is
non-null AND the owner has asked for the feature by name.

**Mailroom page (`/mailroom`, Phase 3):** four sections from §5.2 —
Needs you (parked or past reply-by, incl. `_unresolved` bucket rows) ·
Deadlines (open asks by `reply_by_s`, nudge stage shown) · Orphans
(real_mail split from chase_noise) · Recently settled (folded). Read-only;
every row deep-links via §5.4. No reply-from-web (permanent non-goal).

**Transcript viewer:** graceful "record not found" for dead `#r<seq>`
anchors (ships with Phase 4).

**ipc `-i` dashboard (their lane, advisory overlay):** peers rows show
`process: live|gone (via hub)` when the hub answers, sourced from
`GET /api/sessions` read-only; falls back silently. This is the ONE
instances→ipc display flow and it is display-only (doctrine 2 forbids it
feeding delivery).

## 10 · Failure modes → runbook (operator table) `[m — v1 had containment, no operator]`

| Symptom (what the owner sees) | First check | Owner | Fix |
|---|---|---|---|
| Cards show `ipc: unreachable` | `claude-ipc digest --project . --json` by hand | ipc | `launchctl kickstart -k gui/$UID/com.alcatraz.claude-ipc` |
| Cards show `ipc: version skew` | compare `contract_version` in digest vs fixture | whichever repo is behind | redeploy the stale side; N-1 window means no rush |
| Cards show `ipc: unknown` with broker up | digest `ts` age; hub scan cadence | instances | check scan errors in hub log `/tmp/claude-hub-5400.log` |
| Badge `📬 ?` persists | same as above chain | per state | per state |
| Disagreement flags on many cards at once | `pmset`/reboot? broker restart? B7 resume timing | ipc | if after mass session restart: expected for one debounce window; persisting → broker registry stale |
| Mailroom banner "broker unreachable" | broker health | ipc | restart broker; page needs no fix |
| Scan latency jumped | time the digest spawn; 2s cap intact? | instances | verify cap; if cap broken, that's the §11.6 test failing — fix before ship |
| Dead deep links from old mail | none needed | nobody | by design: inert URLs, viewer shows not-found |

**Abort tripwires (redefined `[m]`):** a coordinated REACTIVE fix to a live
incident spanning both repos → halt, coupling review (planned additive
evolution does NOT trip it). Stale-as-fresh consumed anywhere → that
feature's flag off until the stamp path is fixed. Mailroom console unopened
two weeks after Phase 3 → kill without guilt. Counter noisy with false
disagreements → raise debounce; never let it train the owner to ignore it.

## 11 · Test battery (each watched red before trusted) `[m — prose→tests]`

1. **Additive, both directions:** hub renders every card with the broker
   stopped; ipc's suite asserts delivery with no hub present (trivially true
   today; the test pins it forever).
2. **Staleness:** fixture with old `ts` → UNKNOWN; mutation check: fresh
   `ts` must NOT render UNKNOWN (or the guard proves nothing).
3. **Skew:** contract_version N-2 → state `skew` (distinct string), values
   null; N-1 → fresh. Includes the N-1 fixture.
4. **Malformed:** truncated JSON, non-JSON, empty, `Infinity` → unknown,
   never crash, never 0.
5. **Directionality:** the card-render path invokes no ipc liveness verb
   (grep-level + a runtime assertion in the render test). Pins doctrine 2.
6. **Hang:** digest replaced by a sleeping stub → scan returns within budget
   with state `unreachable` (macOS: process-group kill pattern, no
   `timeout(1)`).
7. **Count parity (shape ≠ truth `[m]`):** digest's `unread`/`owed` values
   cross-checked against the broker's own single verbs for one live alias in
   the live smoke — catches the `--body`-swallow class where valid JSON
   carries wrong numbers.
8. **Contract diff:** live digest ⊇ vendored fixture fields; runs where
   both peers exist (cron/CI), loud SKIPPED otherwise.

## 12 · Phases v2 (efforts `[m]`, gates, kill switches)

- **Phase 0 (~½d instances + ~½d ipc, independent):** contract doc
  (CANONICAL in ipc: `docs/contracts/hub-digest.md`; instances vendors
  fixtures `[m]`), test battery items 1-5 scaffolded red→green where
  buildable pre-digest. Ships no behavior.
- **Phase 1 (~½–1d, instances only):** B1 per-card pid-truth flag +
  disagreement counter (raw JSONL) + mailroom badge v1 (existing join) +
  degraded banner. Kill: `HUB_IPC_OVERLAY=0`.
- **Phase 2 (~1–1.5d ipc + ~½d instances):** digest verb per §5.1 (2s cap,
  reverse-join, `_unresolved`) + `asks --all --json` (§5.2) + count-parity
  smoke; scan switches badge+cards to digest; B3 obligations block appears
  automatically once `ask_state` is observed. Kill: digest flag off → scan
  falls back to the retired per-alias count path, which is KEPT behind the
  switch `[m — retirement must be reversible]`.
- **Phase 3 (~1.5d, instances, gated on badge click-through probe ≥ a
  handful of uses in week one `[m]`):** the mailroom console.
- **Phase 4 (~½d, both, display only):** contextPtr links (derive-from-sid)
  + viewer not-found + `-i` advisory overlay on the ipc side.
- **Phase 5 (B6 role chips):** only after ipc feature 0.5 ships AND the
  owner asks by name.
- Every phase: adversarial gate (the /bloop pattern), soak before next.

## 13 · The deferred oracle (quantified `[m]`)

Default: never build. Revisit conditions, ALL required: (a) the RAW counter
(§5.5) shows >5% of roster rows provably wrong sustained across 7
consecutive days; (b) ipc's B7 (SessionStart wiring on platform-resume) is
CONFIRMED — polluted boot-timing data must not feed a liveness demotion;
(c) reviewed as its own adversarially-gated design. If built: broker reads
`GET /api/sessions` (only then does Surface 1 enter the contract), demotes
to heartbeat after N failed polls with a visible "liveness: heartbeat (hub
unreachable)" provenance line, and ships the direction-2 survival test
before enablement. Owner of the evidence review: the weekly review ritual.

## 14 · Non-goals (permanent)

Shared storage · any cross-write · repo merge · web→ipc write paths
(reply-from-phone is a future WRITE design with its own review, never
candy) · delivery semantics in the hub or rendering in the broker · bar
changes that require decode of non-optional fields.

## 15 · Changelog v1→v2

Folded the magi amendment set (A: three spec errors — digest reverse-join +
`_unresolved`, contextPtr derive-from-sid, B4's new-verb honesty; B: prose
guards → test battery §11; C: operability — timeout, skew state, 24h
banner, runbook, count parity, tripwire redefinition; D: economics —
Surface-2-only contract, counter-before-panel, badge-first mailroom, effort
estimates, B2-lands-with-B3; E: coworker freeze matrix + canonical-in-ipc
contract; F: quantified oracle gate + B7 block). Added the implementation
layer (§3-§11). The B4 fork from v1 is dissolved: badge-first, console
gated on engagement. Bar-freeze constraint from v1 is retired (the bar
builds; suite baseline 5).
