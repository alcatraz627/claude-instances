# Synthesis plan: claude-instances × claude-ipc — the instances-side draft

<!-- sessions: cl-inst-ce@2026-07-17 -->

One of two independent drafts (the ipc lane is writing its own from the same
owner prompt; comparison follows). The owner's governing constraint, verbatim
in spirit: two currently functional systems beat a clobbered mess; loose
coupling; if the optimism doesn't play out, we must be able to walk away with
both systems intact.

## 0 · The stance, made doctrine

This is a **bridge, not a merge**, and every line below is downstream of five
rules:

1. **No shared code, storage, or process.** The only shared things are two
   read-only contracts (the hub's `GET /api/sessions`; ipc's owed/orphans/
   openAwaitings JSON verbs) and one already-shipped file convention
   (`~/.claude-ipc/alias-by-sid/`).
2. **Every fact has one writer, and flows one way.** Physical truth (pid,
   liveness, transcript identity) flows instances→ipc. Social truth
   (obligations, deadlines, roles) flows ipc→instances. No fact is ever
   written by both sides — the sync-todos lesson (one-way mirrors only)
   applied at system scale.
3. **Advisory before authoritative.** Every consumer treats bridge data as a
   display overlay first; only after soak may it become decision input, and
   even then with fallback to its native mechanism.
4. **Absence degrades to today, never to wrongness.** Peer unreachable means
   the feature renders "unknown"/absent and the host system behaves exactly
   as it does now. Every bridge payload carries a timestamp; consumers
   enforce a max-age and render staleness explicitly. Stale-as-fresh is the
   one bug class a bridge manufactures for free; we refuse it in the contract.
5. **Every bridge feature has a kill switch** and no data migration in either
   store. Burning the whole bridge restores today's two systems byte-for-byte
   (contextPtr URLs left inside old messages become inert links, nothing
   more).

## 1 · Concerns, and how they relate

- **C1 Over-coupling** — a change in one repo forcing a change in the other;
  deploy lockstep; shared-schema drift.
- **C2 Failure propagation** — one system's outage degrading the other.
- **C3 Irreversibility** — a half-built bridge worse than none; rollback that
  needs surgery.
- **C4 Ownership blur** — a fact with two writers; "who owns this symptom" in
  an incident.
- **C5 New silent-failure surface at the seam** — both systems' worst
  documented behavior class (confident fabrication) reappearing *between*
  them.
- **C6 Performance coupling** — the scan's daily-watched latency budget and
  the broker's poll load now touching each other.
- **C7 Verification blindness at the seam** — each repo's suite green while
  the cross-system path is broken; both repos have this exact scar
  internally ("verified at the wrong layer").

They relate as a chain: C1 begets C4 (coupling blurs ownership), C4 begets C5
(unowned facts rot silently), C5 is what C7 fails to catch, and C3 is the
meta-concern that decides whether any of it is survivable. C2/C6 are the
runtime faces of the same chain. The doctrine in §0 exists to cut the chain
at its first link: rules 1–2 prevent C1/C4 structurally rather than
procedurally.

## 2 · Existing problems — as behavior classes, not bug lists

The owner is right that a bug fixed this week predicts nothing about next
month. What predicts is the *classes*, and both systems have three months of
receipts. Per class: the evidence, what the synthesis does to it, and where
the synthesis could make it worse.

**B1 · Confident fabrication at boundaries.** Instances: the audit's five
costumes ($0.00 for unpriced models, newest-mtime session resolution,
tokens_in 6 across 12K turns, nc -z liveness) — and it regenerated under the
fixer's hands mid-audit. ipc: send-success proving nothing about delivery;
heartbeat liveness rendering crashed sessions live and working sessions
offline. *Synthesis effect:* helps wherever a heuristic is replaced by the
other side's declared fact (broker liveness ← pid truth). *Worsens if:* the
seam itself fabricates — a 2s-cached liveness snapshot consumed as "now".
Hence the staleness-stamp rule; it is the contract's most load-bearing line.

**B2 · Identity via cosmetic labels.** Instances: sessions resolved by
newest-mtime (the duplicate-card incident); transcript records keyed by
positional seq (R2). ipc: delivery welded to human-typed aliases (clade-ipc,
13 messages unread in a typo's mailbox); per-alias fragmentation; unmarked
succession. Both systems independently converged on the same fix shape this
week — stable identity underneath (session UUID / record id), labels as
display. *Synthesis effect:* strongly positive; the bridge keys everything on
session UUID + cwd, never on alias or role. This is also the strongest
evidence the meld is natural rather than forced: the two codebases derived
the same doctrine from unrelated incidents.

**B3 · Pull-only discovery ghosting.** ipc's sharpest formulation: "state an
agent must remember to query IS the bug." And the human is today a polling
agent too — the owner discovers stuck queries and orphaned mail by accident
(this session found 3-day-old chases only because a resume ritual peeked).
*Synthesis effect:* the mailroom converts the human's discovery to a glance;
obligations-on-cards converts per-session mail state to ambient display.
*Worsens if:* the mailroom itself becomes a pull surface nobody opens —
mitigated by putting the aggregate count on the index page the owner already
watches daily, not on a page they must remember.

**B4 · Verified at the wrong layer.** Both systems, explicitly, in their own
RCAs (unit-green router with broken argv path; 4/4 guards passing around a
broken whole). *Synthesis effect:* neutral-to-negative — the seam is a NEW
wrong layer no single suite sees. Mitigation is structural: the contract is
tiny and versioned; each repo vendors fixture tests of the other's response
shape; each side ships one live smoke that skips (loudly) when the peer is
absent; every bridge phase goes through the same adversarial gate the last
three work packages did.

**B5 · State decay under concurrency / cross-session drift.** The machine's
dream-consolidation reports name this as the owner's top systemic pattern:
cached state (task lists, branch state, ownership claims) silently decays
while concurrent sessions run; checkpoint compression launders caveats. ipc's
sibling-alias pileups and stale checkpointed alias chains are instances of
it. *Synthesis effect:* genuinely new capability — with two independent
recorders of session reality, disagreement becomes *renderable*: "ipc thinks
this alias is live; no pid owns it" as a first-class hub panel instead of a
silent pick-one. Truth-diff is the owner's own principle (surface the
contradiction, never absorb it) applied between systems.

**B6 · Tooling blast radius near live systems.** Fresh receipt: an R3
validator deleted the live hub's pidfile and log mid-test (disclosed,
repaired; log history lost to an unlinked inode). More bridge = more agents
touching more live surfaces. *Synthesis effect:* negative unless bounded —
the contract doc gets a mandatory-isolation clause (scratch brokers, scratch
hubs, fake pids) mirrored into both repos' validator dispatch templates.

## 3 · What the synthesis solves (mapped to the classes)

| Bridge feature | Solves | Class |
|---|---|---|
| Mailroom page on the hub (reads openAwaitings/orphans/owed) | invisible obligations, 2:1 chase noise, human-as-accidental-poller | B3 |
| Liveness advisory overlay → later broker oracle (reads /api/sessions) | liveness lies both directions; dead-beside-successor | B1, B2 |
| Obligations-not-inventory on cards (needs ipc's askState deploy) | roster-as-directory; per-session owed/waiting at a glance | B3, B2 |
| contextPtr deep links (`/s/<sid>#r<seq>`) | "what was this message about" archaeology | B3 |
| Batched counts call (replaces subprocess-per-alias) | scan latency budget; the 95%-subprocess lesson | C6 |
| Truth-diff panel (registry vs pid reality) | silent cross-system disagreement | B5, B1 |
| Succession/lineage display (sid chains + alias-by-sid) | unmarked succession; identity invisible at boot | B2 |

## 4 · New capabilities

**System functionality.** A mailroom (all pending queries, deadlines, nudge
stages, orphans, machine-wide); obligations and deadline countdowns on live
cards; lineage chains (predecessor→successor rendered as one thread); message
→ transcript-moment provenance via stable record ids; a liveness oracle that
is actually true.

**System behavior.** Agents stop chasing dead aliases (their `peers` view
stops lying); fewer human escalations because the human sees dangles before
they rot; boot orientation improves (the ipc boot survey's top ask — "one
wake line: you are X, successor of Y, Y owes N replies" — is exactly a join
of instances' lineage data with ipc's owed data).

**User-facing candy.** The mailroom on the phone (tailnet, already free);
reply-by countdowns turning red; role labels (main/assistant) instead of
cosmetic aliases once ipc's Concern-6 work lands; click-from-mail into the
exact conversation moment; a truth-diff panel that makes the invisible
disagreements visible. All hub-side — the compiled Swift bar is frozen
(its build is a known-broken baseline) and gets nothing that requires a
rebuild.

**Data robustness.** Two independent recorders of session existence
cross-check each other (B5 above); ipc's message log and the transcript
store become mutually navigable (contextPtr one way, ipc tool calls visible
in transcripts the other way); "unknown ≠ 0 ≠ dead" propagates as a shared
tri-state doctrine across both systems' displays.

**Other.** The R2/Concern-6 convergence becomes an explicit shared
convention (stable id under cosmetic label), which future features on either
side inherit for free; and if the Artifact Shelf lands on the hub, messages
gain a second provenance target (artifacts) with zero extra schema.

## 5 · Drawbacks — honestly, including the standalone question

**Can each system still run its core alone? Yes, by construction — but state
what "alone" costs.** The hub without ipc: cards lose alias/mail badges (as
today when the broker is down), the mailroom renders an honest
"broker unreachable" banner, everything else untouched. ipc without the hub:
liveness falls back to heartbeats (today's behavior, with today's lies),
contextPtr links go dead-but-inert, obligations digest unaffected. Neither
core regresses; only bridge features go dark, and they go dark *visibly*.

**The permanent costs, even in the success case:**
- A contract now exists and must be honored forever: additive-only changes to
  two JSON shapes, with a compat check in both repos' review flow. Small, but
  it never goes away.
- Cross-system debugging needs both contexts in one head (or one session);
  incident runbooks must name which side owns which symptom (liveness: hub;
  obligations: broker; rendering: hub; delivery: broker).
- Perf budgets interlock: broker polling the hub rides the hub's 2s scan
  cache; the scan's ipc reads ride one batched call. Both are budgeted and
  measured, but they are now each other's neighbors.
- Temptation debt: a working bridge invites "just let the broker write into
  the hub's cache" style shortcuts. Rule 2 (§0) must be treated as an ADR
  hard rule — the class of exception the house explicitly forbids
  self-permitting.
- The seam concentrates B1 risk permanently: every future bridge payload is
  a fresh chance to consume stale-as-fresh. The staleness-stamp rule has to
  be enforced in the contract fixtures, not just prose.

## 6 · Failure modes and their handling

- **F1 Hub down / port moved → broker oracle blind.** Stage-1 is advisory
  (display only). Stage-2 oracle demotes to heartbeat after N consecutive
  unreachable polls and says so in `peers` output ("liveness: heartbeat
  (hub unreachable)"). Never silent.
- **F2 Broker down → scan join stalls.** Already bounded (2s timeout); the
  batched call reduces the worst case from one timeout per live session to
  one total. Mailroom banners honestly.
- **F3 Contract drift.** Version field in both payloads; tolerant readers
  (unknown fields ignored, missing fields = unknown, never defaulted to 0 —
  the codex-tokens doctrine); vendored fixtures on both sides; additive-only
  evolution with overlap windows.
- **F4 Stale-as-fresh at the seam.** Every payload stamped; consumers
  enforce max-age; past it, render UNKNOWN. The one non-negotiable.
- **F5 Circular liveness confirmation.** The hub never re-imports broker
  liveness for its own cards (it owns pid truth); broker-consumed hub
  liveness carries provenance ("via hub") so a human reading `peers` can see
  which authority spoke. No fact may round-trip.
- **F6 Load coupling.** Broker polls ≥5s against a 2s-cached endpoint;
  backs off on errors; the hub's parse cache (shipped today) makes the added
  read load ~stat-level. Measured before stage-2.
- **F7 Exposure surface.** The mailroom shows message metadata on a
  tailnet-visible page. Parity argument: full transcripts are already served
  there, so mail metadata is not a new exposure class — but the mailroom
  stays read-only, and "reply from the phone" is explicitly rejected for v1
  (it would be the first write path from the web into ipc; if ever wanted,
  it gets its own adversarial review as a WRITE feature, not smuggled in as
  candy).
- **F8 The half-built bridge (the clobbered-mess fear).** Phasing below:
  every phase is independently shippable, independently killable, and adds
  surfaces without mutating existing behavior. No phase leaves either system
  in a state today's code can't handle.
- **F9 ipc's in-flight identity rebuild shifting under the bridge.** The
  bridge consumes only stable keys (session UUID, cwd). Aliases and roles
  appear in bridge payloads as display strings only. Concern-6 can rebuild
  addressing without the bridge noticing.
- **F10 Validators near live systems.** Mandatory-isolation clause in the
  contract doc, mirrored into both repos' dispatch templates (fresh receipt:
  the pidfile incident). Scratch broker sockets and scratch hub ports for
  any cross-system test rig.

## 7 · Phasing — shaped so the pessimistic case is cheap

- **Phase 0 — the contract, frozen small.** One short doc, committed to both
  repos with fixtures: the /api/sessions fields ipc may read; the ipc JSON
  verbs the hub may read; staleness-stamp + tolerant-reader + no-cross-write
  + isolation rules. This phase ships no behavior. Abort cost: zero.
- **Phase 1 — instances-only.** Batched counts (perf fix to the existing
  join) + the mailroom page reading existing broker verbs. ipc untouched.
  Abort cost: delete a page and revert one function.
- **Phase 2 — ipc-only.** contextPtr population + advisory liveness overlay
  in its own peers/dashboard output (reads the hub API, falls back
  silently). Instances untouched. Abort cost: two flags off.
- **Phase 3 — both sides, after soak.** Obligations-on-cards (waits for
  ipc's askState deploy — a natural sequencing handshake, not lockstep: the
  hub feature simply doesn't ship until the field exists). Truth-diff panel.
- **Phase 4 — judgment calls, each its own go/no-go.** Broker liveness
  oracle stage-2; ipc bus pushing hub notifications; role labels on cards.
  Any of these can be declined forever without diminishing phases 0–3.

**Abort criteria, stated up front:** any incident whose fix requires
coordinated changes in both repos at once → stop and re-review the coupling
(that is the C1 tripwire). Bridge feature found consuming stale-as-fresh →
that feature's flag goes off until the stamp path is fixed. The mailroom
unopened for two weeks → it was the wrong surface; kill it without guilt.

**Non-goals, permanent:** shared storage; any cross-write; merging repos;
web-to-ipc write paths; Swift bar changes; delivery semantics moving into
the hub or rendering moving into the broker.

## 8 · The verdict this draft argues for

The promising-vs-mirage question resolves empirically and cheaply: phases
0–2 cost days, touch each repo only alone, and are individually reversible
for the price of a flag. If the pessimism is right, we find out at phase 1–2
soak for almost nothing, and both systems remain exactly as functional as
today. If the optimism is right, the classes that have actually been biting
— fabricated liveness, invisible obligations, cosmetic-label identity,
silent cross-system disagreement — are the ones this specific bridge
retires. The design's honest core: the meld is worth doing *because* the
two systems disagree about when a session is real, and the bridge's job is
to surface that disagreement, not to fuse the systems that hold it.
