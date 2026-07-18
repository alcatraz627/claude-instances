# claude-instances × claude-ipc — the unified synthesis plan

<!-- sessions: cl-inst-ce@2026-07-18 -->

The consolidation of two independently drafted plans and their comparison:
the instances-side draft (`docs/20260717-synthesis-plan-instances-view.md`),
the ipc-side draft (`~/Code/Claude/claude-ipc/.claude/output/
20260717-synthesis-plan-ipc-view/PLAN.md`, author cowork-build-c7), the
clarification exchange (msg-d3fbb529 / msg-0c202faa), and the comparison
delivered 2026-07-17. Where the drafts disagreed, this doc records the
resolution and why. One decision remains the owner's and is marked OPEN.

---

## 1 · Intent capture

What the owner actually asked for, in their own framing:

1. **The systems matured separately and now show cross-cutting concerns.**
   The owner sees interaction value "and more features that can be added for
   me (the user) with that bridge."
2. **The governing fear, verbatim in spirit:** "I would rather have the two
   currently functional systems (with issues but still useful) than a
   clobbered mess that makes fixing cause more issues or leads to unwanted
   coupling." The fear is not failure of the features; it is the *class* of
   harder-to-sort-out issues coupling creates.
3. **Evidence bar:** behavior-report reasoning, not bug-list reasoning — "a
   fixed bug in the last 3 days cannot predict issues related to itself in
   the next 3 weeks."
4. **Required deliverable properties:** standalone survival analysis
   (explicitly: "will the systems still be able to operate their core
   functionality on their own"), and a failure-mode catalog with mitigations.

Interpreted intent, one level deeper: the owner is the *daily user* of both
surfaces (dashboard watched all day; sessions live on ipc). The meld's value
is measured in owner-time saved (dangles discovered before they rot, truth
at a glance) and owner-trust preserved (numbers that never lie, per the
standing principle that a self-inconsistent number breaks trust more than a
crash). Any bridge that costs trust to buy convenience is a net loss.

## 2 · The two systems and their ground truths

**claude-instances** (pull; the human's lens): web hub on :5400 (tailnet +
loopback, phone-readable) + a frozen compiled menu-bar Swift bar. scan.sh
holds authoritative pid→session_id→transcript mapping from Claude Code's
own statusline side-files, exact process liveness, project/model/tab-title
enrichment, whole-window aggregates (R1), stable per-record transcript
identity + deep links (R2). Doctrine: hub GETs never write; unknown renders
None, never a fabricated 0; scan latency is a budget (~1.6s full / 0.43s
quick).

**claude-ipc** (push; the agents' postal service): compiled bun broker under
launchd, unix socket, sqlite + memory backends; per-alias mailboxes with
sibling-aware session scoping; hook-driven delivery (SessionStart boot
digest, UserPromptSubmit wake frames, Stop heartbeat); two-stage chase then
park. Doctrine: verified-at-the-field-layer; any state an agent must
remember to query reproduces ghosting; parked-not-failed; UNCONFIRMED, not
a checkmark.

**Why they match:** each holds exactly the ground truth the other lacks
(pid-liveness ↔ obligation graph), and their doctrines rhyme — both refuse
to fabricate (None-not-zero ↔ parked-not-failed). Two systems that already
refuse to lie the same way are safe to let read each other. Independent
receipts: both codebases converged this same week, from unrelated
incidents, on "cosmetic labels must not be identity" (R2's seq→id; ipc's
Concern-6 alias decoupling).

## 3 · Doctrine (the union, now binding)

1. **Bridge, not merge.** No shared code, storage, or process. Shared
   surface = two read-only contracts + one existing file convention
   (`~/.claude-ipc/alias-by-sid/`).
2. **Every fact has one writer and flows one way.** Physical truth
   (instances→ipc), social truth (ipc→instances). No fact round-trips: the
   hub never re-imports broker liveness for its own cards; broker-consumed
   hub data carries provenance so no side can echo the other back at
   itself.
3. **Push/pull by audience** (ipc draft's rule, adopted verbatim): agents
   get obligations PUSHED (wake hooks, boot digest); the human gets them
   PULLED (cards, mailroom). Nothing an agent needs may ever be delivered
   via the hub — the human is the only actor who polls deliberately.
4. **Advisory before authoritative.** Display overlay first; decision input
   only after soak, always with native fallback.
5. **Absence degrades to today, never to wrongness.** Every bridge payload
   carries `ts` + `protocol_version`; consumers enforce max-age and render
   UNKNOWN past it; unreachable ≠ zero; version mismatch → "unavailable,"
   never a defaulted value.
6. **Additive-by-construction, asserted by test.** Every bridge feature has
   a kill switch, no data migration, and the additive property is a shipped
   test (hub renders every card fully with the broker stopped), not prose.
7. **Session UUID + cwd are the only join keys.** Aliases and roles are
   display strings wherever they cross the seam.
8. **Isolation for tooling.** Any validator/test rig touching the seam uses
   scratch brokers (own socket) and scratch hubs (own port via ports.sh
   tier-3) — receipt: the 2026-07-17 live-pidfile deletion incident.

## 4 · Behavior-class analysis (union of both catalogs)

| Class | Receipts | Synthesis effect |
|---|---|---|
| B1 Confident fabrication at boundaries | instances: the audit's five costumes, regenerating mid-fix; ipc: send-success proving nothing, heartbeat liveness lying both ways | Helps where a heuristic is replaced by declared fact; WORSENS at the seam unless staleness stamps are enforced by fixture (doctrine 5) |
| B2 Identity via cosmetic labels | instances: newest-mtime resolution, positional seq; ipc: clade-ipc typo (13 msgs unread in the wrong box), unmarked succession | Strongly helped: sid-keyed everything; the convergence is evidence the meld is natural |
| B3 Pull-only discovery ghosting | ipc RCA: "state an agent must remember to query IS the bug"; the OWNER is a polling agent today (3-day-old chases found by accident) | Helped iff doctrine 3 holds; the mailroom is the correct pull surface for the one deliberate poller |
| B4 Verified at the wrong layer | both systems' RCAs, explicitly | The seam is a NEW wrong layer: countered by vendored fixtures both sides + loud-skip live smokes + adversarial gates per phase |
| B5 Cross-session state decay | dream-consolidation reports (cached state decays under concurrency; checkpoints launder caveats); ipc sibling-alias pileups | NEW capability: disagreement becomes renderable (truth-diff) instead of silently absorbed |
| B6 Tooling blast radius | the pidfile/log deletion incident (2026-07-17) | Negative unless doctrine 8 is mandatory |
| B7 Roster-as-inventory / identity invisible at boot | ipc boot survey 6/6; 340-row roster; 2:1 chase noise | Cards + mailroom answer it at human scale; ipc's digest answers it at agent scale |

## 5 · The bridges — full specs, holes closed

### B1 — Liveness advisory overlay (hub-side, first)
Hub joins scan's pid-truth against ipc's roster (via the digest, or the
existing side-files pre-digest) and renders per card: `process: live` /
`process: gone` beside ipc's claimed status. Disagreement renders as a
flag, not a silent pick (see truth-diff). No ipc change. Kill switch:
`HUB_IPC_OVERLAY=0`.

### B2 — The digest verb (the data pipe)
`claude-ipc digest --project <cwd> --json` (final flag names ipc's call),
ONE subprocess per full scan (quick mode: skipped, same as today's join
semantics). Response contract:

```json
{
  "protocol_version": "<ipc PROTOCOL_VERSION>",
  "ts": "<ISO8601>",
  "sessions": {
    "<session-uuid>": {
      "aliases": ["vb-opus", "..."],
      "role": null,
      "unread": 3,
      "owed": [{"corr_id": "...", "kind": "query", "age_s": 1200,
                 "reply_by_s": 300, "ask_state": "open"}],
      "waiting_on": 1,
      "orphaned_in_cwd": 0,
      "oldest_deadline_s": 300,
      "chase_noise_folded": 4
    }
  }
}
```

Rules: keyed by session uuid; unknown/missing values are `null`, never 0;
consumer enforces max-age (proposal: 30s) and renders UNKNOWN past it;
unknown fields ignored; version mismatch → whole payload treated as
"ipc unavailable". Retires the per-alias `count` subprocess.

### B3 — Obligations on cards (not inventory)
Per card: owes N (oldest age + nearest reply-by countdown), waiting-on M,
orphans-in-cwd, chase noise folded behind a disclosure. Depends on B2 +
ipc's deployed askState. Provenance rendering mandatory: "ipc: unreachable"
is a distinct visual state from zeros.

### B4 — The mailroom page (`/mailroom`)
Sections: **Needs you** (asks parked or past reply-by with no resolution),
**Deadlines** (open asks sorted by reply-by, nudge stage shown),
**Orphans** (dead sessions holding real mail; chase noise split out),
**Recently settled** (folded). Reads ipc's existing verbs
(openAwaitings/orphans/owed) directly — a page fetch, not the scan loop,
so the subprocess cost is per-view and acceptable pre-B2. Aggregate count
badge on the hub index page (the surface the owner already watches; a page
nobody opens is B3-class failure — the two-week-unopened tripwire applies).
Read-only; no reply-from-web in v1 (a web→ipc write path requires its own
adversarially-reviewed design if ever wanted).

### B5 — Deep links (contextPtr)
ipc populates `Message.contextPtr` (exists today, zero schema change) with
`http://<hub-host>:5400/s/<sid>#r<seq>`. Contract: the viewer renders a
graceful "record not found" for dead links; ipc never assumes resolution.
Reverse direction: hub cards link to the session's ipc thread view (`-i`
dashboard deep link, format owned by ipc). Both directions are inert URLs —
nothing breaks when the target is gone.

### B6 — Role labels on cards
After ipc ships role/buddy addressing (its feature 0.5): cards show
`main` / `assistant` role chips with alias as secondary text. Blocked on an
ipc feature by dependency, not value.

### T — The truth-diff panel (from B1 data; the robustness centerpiece)
A hub panel listing every disagreement between the two recorders:
- ipc claims live/idle, no process owns the sid → "stale registration"
- process live, sid absent from ipc → "unregistered session"
- alias bound to a sid whose transcript is gone → "orphaned alias"
Debounce: a disagreement must persist across 2 consecutive scans before
rendering (registration races are legitimate for seconds). Each row names
both authorities' claims with timestamps — surface the contradiction,
never absorb it. This is the owner's trust principle applied between
systems, and it is also the EVIDENCE GATE instrument for the deferred
oracle decision.

### Deferred (decline-able forever): the broker liveness oracle
Default: ipc liveness stays self-sourced; the hub is the sole join point.
If the truth-diff panel shows heartbeat liveness materially wrong at a
sustained rate (proposal: >5% of roster rows wrong across a week), the
oracle option may be revisited: broker consumes `GET /api/sessions` (the
versioned HTTP contract, never scan internals or /tmp files), demotes to
heartbeat after N failed polls with a visible "liveness: heartbeat (hub
unreachable)" provenance line. Its own adversarial review; its own kill
switch; both lanes' drafts agree on this pricing.

## 6 · The contract (Phase 0 artifact)

One short doc, `MELD-CONTRACT.md`, committed to BOTH repos with fixtures:

- **Surface 1:** `GET /api/sessions` — the fields ipc may read (session_id,
  pid, provider, liveness-relevant fields), plus `ts`; hub adds a
  `contract_version` field to the payload.
- **Surface 2:** the digest verb schema above + the existing
  openAwaitings/orphans/owed JSON shapes.
- **Rules (verbatim from doctrine):** staleness stamps + max-age; tolerant
  readers; null-not-zero; additive-only evolution with overlap windows; no
  cross-writes; isolation for test rigs; no fact round-trips.
- **Fixtures:** each repo vendors a frozen sample of the other's response
  and tests its own reader against it; each ships one live smoke that
  SKIPS LOUDLY when the peer is absent.
- **The additive-property test:** hub renders every card fully with the
  broker stopped (instances repo); broker delivers normally with the hub
  down (ipc repo — trivially true today; the test pins it forever).

## 7 · New capabilities

**Functionality:** mailroom escalation console; obligation-aware cards
(owes/waiting/deadline vs bare unread); lineage/succession display (when
ipc's successor facts land); message↔transcript navigation both ways; a
liveness picture that is actually true. **Behavior:** liveness stops lying
to the human the day B1 ships (decoupled from the harder broker-internal
fix); agents stop being chased into dead mailboxes as the human catches
dangles early; boot orientation improves (lineage + owed = the survey's
"one wake line"). **Candy:** mailroom on the phone; deadline countdowns
going red; role chips; click-from-mail to the exact moment; the truth-diff
panel. All hub-side; the bar is frozen until its build is fixed (the one
bar temptation — an owed-asks badge — is pre-marked BLOCKED-ON-BAR-FIX).
**Robustness:** two independent recorders cross-checking (truth-diff);
contextPtr gaining stable targets (R2 ids); unknown≠0≠dead as shared
tri-state doctrine.

## 8 · Standalone survival & drawbacks

**ipc alone (all bridges removed):** delivery, addressing, reply contracts
untouched by construction — nothing core ever consumed instances data
(oracle deferred; if ever built, demote-on-unreachable preserves this).
**instances alone:** cards lose ipc chips (as today when the broker is
down), mailroom banners "broker unreachable", everything else untouched.
Both cores byte-for-byte today's behavior; bridge features go dark
*visibly*.

**Honest permanent costs:** a contract honored forever (additive-only, in
both review flows); a shared failure surface that didn't exist (bounded:
scan already treats ipc as an untrusted timeout-bounded subprocess);
attribution ("which system lied?") answered by mandatory provenance
rendering; interlocked perf budgets (bounded + measured); coupling creep —
every new bridge passes the rubric IN WRITING (standalone, reversible,
contained, then value) and the additive test; and the seam permanently
concentrates fabrication risk, held off by fixtures, not prose.

## 9 · Failure modes → handling (union table)

| Failure | Containment |
|---|---|
| Broker down during scan | One bounded timeout (B2); fields → UNKNOWN; cards render from scan data |
| Hub down | ipc unaffected (nothing core reads it); overlay/oracle-if-ever demotes with provenance line |
| Malformed/partial ipc JSON | Defensive parse; any failure → UNKNOWN (never 0, never crash) |
| Version skew either direction | Tolerant readers; mismatch → "unavailable"; additive-only evolution |
| Stale-as-fresh at the seam | `ts` + max-age enforced by contract fixtures; UNKNOWN past max-age |
| Circular liveness confirmation | No fact round-trips (doctrine 2); provenance strings |
| Dead deep links | Graceful "record not found"; links are inert URLs |
| Mailroom exposure | Parity with already-served transcripts; read-only; no web→ipc writes v1 |
| Fabricated zero when broker down | UNKNOWN ≠ 0 rendering, both directions |
| Bar decode break | Nothing bar-bound; Codable ignores unknown keys; owed-badge pre-blocked |
| Coupling creep | Rubric-in-writing per new bridge + additive test + the coordinated-fix tripwire |
| Validator damage to live systems | Doctrine 8 isolation, mirrored into both repos' dispatch templates |
| Half-built bridge | Phases independently shippable/killable; no phase mutates existing behavior |
| ipc identity rebuild shifting under the bridge | Bridge consumes only sid+cwd; aliases/roles display-only |

**Abort tripwires (standing):** an incident requiring coordinated fixes in
both repos at once → halt, re-review coupling. A bridge caught consuming
stale-as-fresh → flag off until the stamp path is fixed. Mailroom unopened
two weeks → kill without guilt. Truth-diff panel noisy with false
disagreements → raise debounce or flag off; never let it train the owner
to ignore it.

## 10 · Implementation plan

Resolved ordering (comparison verdict: takes ipc's B1-first instinct and
instances' mailroom-early instinct; B4 does NOT depend on B2 — it reads
existing verbs as a per-view page fetch):

- **Phase 0 — contract + tests.** `MELD-CONTRACT.md` + fixtures in both
  repos + the additive-property tests + `contract_version` field added to
  `/api/sessions`. No behavior ships. (instances: ~half day; ipc: ~half
  day, independent.)
- **Phase 1 — B1 overlay + truth-diff panel** (instances only; reads
  side-files/registry read-only pre-digest). Includes the debounce rule.
- **Phase 2 — B4 mailroom** (instances only, existing ipc verbs) **∥ B2
  digest verb** (ipc only). Genuinely parallel: different verbs, different
  consumers, different repos. Mailroom index-page badge included.
- **Phase 3 — B3 obligations-on-cards** (instances, after ipc deploys
  askState + B2; the sequencing handshake — the hub feature simply waits
  for the field, no lockstep).
- **Phase 4 — B5 contextPtr links** (ipc populates; instances adds the
  not-found rendering + reverse links).
- **Phase 5 — B6 role chips** (after ipc feature 0.5 ships).
- **Deferred indefinitely:** the broker oracle (evidence-gated by the
  truth-diff panel); any web→ipc write path; any bar-bound candy.

Each phase: /bloop-style adversarial gate, soak before the next, own kill
switch, no data migration. Every phase leaves both systems in a state
today's code handles.

**OPEN — the one owner decision:** this plan resolves the drafts' B4-fork
by parallelizing (Phase 2). If the owner prefers strict seam-de-risking
first (ipc draft's prior: B2 before any big page), Phase 2 splits into
2a=B2, 2b=B4 — cost: the mailroom arrives one phase later. Default as
written: parallel.

## 11 · Provenance

Instances draft: `docs/20260717-synthesis-plan-instances-view.md` ·
ipc draft: `~/Code/Claude/claude-ipc/.claude/output/
20260717-synthesis-plan-ipc-view/PLAN.md` · baseline exchange
msg-ccac4813 · clarifications msg-d3fbb529/msg-0c202faa · comparison
delivered in-session 2026-07-17. Both drafts were written blind to each
other; doctrine sections 0/3 converged independently — treated throughout
as evidence the constraint is unambiguous and the meld natural.
