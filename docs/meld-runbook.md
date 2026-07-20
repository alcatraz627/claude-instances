# Meld bridge runbook — what to do when the ipc join looks wrong

The hub joins claude-ipc's view of each session (alias, unread mail,
obligations) onto the live cards. This page is the operator table for when
that join degrades. Design and rationale: `20260718-meld-unified-plan.md`
(the state machine is §7, the operator table this seeds from is §10).

**Current sourcing:** until claude-ipc ships its `digest` verb, the hub uses
the per-alias `count` fallback — cards can only show `fresh` or
`unreachable`. The digest states (`stale`, `skew`, `unknown`) appear
automatically once the verb answers; nothing needs deploying on this side.

## Symptom → first check → fix

| Symptom (what you see) | First check | Owner | Fix |
|---|---|---|---|
| Chips show `✉?` / state `unreachable` | `claude-ipc count <alias>` by hand — does the broker answer? | ipc | `launchctl kickstart -k gui/$UID/com.alcatraz.claude-ipc` |
| Cards show `ipc: version skew` | `claude-ipc digest --project . --json` → compare `contract_version` vs `tests/fixtures/ipc-digest-fixture.json` | whichever repo is behind | redeploy the stale side; the N-1 window means no rush |
| Cards show `ipc: unknown` with the broker up | digest `ts` age vs wall clock; hub scan cadence | instances | check scan errors in `/tmp/claude-hub-5400.log` |
| Badge `📬 ?` persists | any non-fresh chip, or a fresh chip whose count the broker didn't give — same chain as above | per state | per state |
| ⚠ on one card ("ipc thinks offline") | the session is mid-long-turn (heartbeat staleness — expected, ages out) | nobody | none; it clears when the claim and pid-truth re-agree |
| ⚠ on many cards at once | reboot? broker restart? mass session restart? | ipc | expected for one debounce window after a mass restart; persisting → broker registry stale |
| Banner "ipc bridge degraded for over 24h" | walk the chain above for whichever state the chips show | per state | sessions run fine either way; mail counts are unknown until fixed |
| Scan latency jumped | `time bash lib/scan.sh` — digest spawns are capped at 2s total; if the cap is broken the hang test in `tests/run-tests.sh` fails | instances | fix before ship; the cap is pinned by test |
| Disagreement ledger noisy | `tail ~/.claude/widgets/.ipc-disagreements.jsonl` — raw lines are pre-debounce and expected to be chatty | instances | only the on-card ⚠ is debounced; raise the debounce rather than training yourself to ignore it |

## Kill switches (env, read by scan.sh at spawn)

- `HUB_IPC_OVERLAY=0` — the whole join reverts to the legacy silent shape
  (alias + count, no states). The outermost switch.
- `HUB_IPC_DIGEST=0` — digest sourcing off; the per-alias count path (kept
  exactly for this) takes over with honest fresh/unreachable states.

## Scratch/testing isolation

Stub the broker with `HUB_IPC_BIN=<stub>`, and redirect the disagreement
records with `HUB_IPC_DISAGREE_LOG` / `HUB_IPC_DISAGREE_STATE` — a stubbed
run must never write the live ledger. Scratch hubs claim their own port
(`ports.sh claim <name> --tier 3`); the pidfile and log are port-scoped.

## Abort tripwires (from the plan, binding)

A coordinated REACTIVE fix to a live incident spanning both repos → halt,
coupling review. Stale-as-fresh consumed anywhere → that feature's flag off
until the stamp path is fixed. A counter noisy with false disagreements →
raise the debounce.
