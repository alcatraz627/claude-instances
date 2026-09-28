# Switchboard v2: one panel for what needs you, what agents may do, and the machine

<!-- sessions: gcc-flags@2026-09-25 -->

Owner ask, 2026-09-25, verbatim where it binds:

> "gcc approvals and claude perm prompts: See how this can be integrated, but
> it should not be coupled at all; it should work the same as if approved from
> the terminal or the switchboard, clear out older ones in the switchboard ->
> Explore first, we don't want a broken system, would rather not have this at all"
> "hook snoozes, yes · mute files, yes · local modal board, amazing: Button for
> on / on and other details · Keep awake with a proper timer · Dev server
> ports, omg yes please, link to the pm2 policy in gcc · notifications hmm yeah maybe"
> "Take all of this and plan a coherent way to show all this"

Done already (2026-09-25): the dropdown Switchboard section is removed (its
switches, including the scan cadence, live in the panel); every system switch
takes a timer, which covers "Keep Awake with a proper timer" (presets plus
"until a time"; engine tested by `--probe-timers`).

## The shape: one strip, three tabs

A menu bar panel stays usable only if every item answers one of a few
questions the owner actually asks. Four questions, four places:

```
┌ Switchboard ─────────────────────────── [Agents|Machine|Hooks] ┐
│ ▸ NEEDS YOU (only when non-empty)                              │  "does anything
│   push to main · speedway (a3f2c1)   2m   [Approve] [Cancel]   │   wait on me?"
│   Bash · gcc-flags asked 40s ago          [Go to tab]          │
├────────────────────────────────────────────────────────────────┤
│ Agents   what agents may do as you (today's policy tab)        │  "what may they do?"
│ Machine  power · services · dev servers · local models · feed  │  "what is running?"
│ Hooks    muted guards · snoozes, each timed                    │  "what is switched off?"
└────────────────────────────────────────────────────────────────┘
```

- **Needs you** is a strip, not a tab: it sits above the tabs and only shows
  when something waits, so it is the first thing read and costs nothing when
  empty. The menu bar icon gets a small dot while it has items.
- **Machine** replaces today's System tab and grows into sub-groups.
- **Hooks** is new: everything currently silenced, and how long for.
- Notifications are a small group inside Machine, not a tab.

## Needs you (approvals)

Built only from the findings in
`~/.claude/assets/reports/20260925-1639-approvals-explore/findings.md`: the
panel is one more writer of files that already exist, so every flow works the
same with the app closed.

| Item | Shown from | Answer on click | Clears when |
|---|---|---|---|
| Push approval | `.push-nonce-<sid>` (nonce, target, why, ts) | `touch .push-approved-<sid>`, the file the typed line writes | the gate deletes both on the push; "Cancel" does what typing `cancel push` does |
| Render write | `.render-approve-<hash>` plus a new sidecar JSON saying which tool and env | `touch` the nonce | the gate consumes it; hidden after its 300 s TTL |
| Kanban decision | `kanban.sh decide list` | `kanban.sh decide answer <id> "<ruling>"` | answered |
| Claude permission prompt | the session's latest event in `events.jsonl` is a PermissionRequest | **none**: "Go to tab" only, via the OSC 9 navigation `permission-notify.sh` already uses | any later event from that session |

Stale ones: a nonce whose session is no longer live shows greyed with a
Discard button (same effect as `cancel push`). The existing stale push
*approvals* row (armed sentinels of dead sessions) moves here too.

Not built, on the findings' evidence: any hook that answers a Claude
permission prompt (it would race the terminal dialog), any wait loop in a
hook, any auto-answer.

## Machine

| Group | Rows | Source | Actions |
|---|---|---|---|
| Power | Keep Awake (timer); notification sound, quiet hours | IOPM assertion; a new flag `permission-notify.sh` reads | switch + timer |
| Services | Kanban, Session Hub, Decision Pages, Warden, ipc broker, scheduled jobs | existing rows | switch + timer; jobs gain a drill-down listing the failing ones with "run now" |
| Dev servers | tier 2 services with live state, tier 1 pins (read-only), "N expired one-offs · Reap" | `ports.sh list` / `scan`, `pm2 jlist` | start/stop (pm2), open link, reap (revivable); a "Port policy" link opens `features/dev-servers.md` |
| Local models | resident models with size and keep-until, running mlx jobs (imagine, see), memory pressure, mem-guard daemon | `ollama ps`, `ps`, `kern.memorystatus_vm_pressure_level`, `/tmp/mem-guard.pid` | unload a model, warm a model, mem-guard on/off (+ timer); links to the `model.heavy_local` policy |
| Cost | Always thinking | settings.json | switch + timer |
| Feed | Auto-refresh, scan cadence | in-app | switch, picker |

Today's machine, for scale: 21 tier-2 services, 3 tier-1 pins, 44 expired
one-off claims never reaped; one 5.5 GB model (`gemma4-e4b-warm`) resident
with no expiry.

## Hooks

- **Muted guards:** every sentinel-based guard that is currently off, with age.
  One click re-arms (deletes the file). Muting from here is always timed (30 m to
  7 d), never permanent: the panel writes the sentinel and the timer engine
  removes it at expiry. A permanent mute stays a deliberate shell act.
- **Snoozes:** the `hook-snooze.sh` ledger rows with hook, scope, reason and a
  countdown; lift in one click (`hook-snooze.sh lift <id>`). New snoozes from
  the panel pass `--approved-by owner`, which is exactly what they are.
- A hook that supports snoozes is snoozed rather than sentinel-muted, so the
  reason and expiry are recorded where `hook-snooze.sh list` shows them.

## Build order

Each step ships and is exercised on its own; approvals come last because they
touch live gates.

1. Machine: Dev servers group (read + pm2 start/stop + reap), then Local models.
2. Hooks tab: muted guards (re-arm, timed mute) and snoozes (list, lift, add).
3. Needs you: Claude permission prompts (show + go to tab), then Kanban decisions.
4. Needs you: push and Render answers. Render first needs the sidecar change in
   `render-mcp-gate.py`. Before shipping, try to click the panel through the
   Accessibility API from an agent shell and confirm macOS refuses (findings, unknown 1).
5. Notifications group, if still wanted.

## Checks for done

- Every write the panel makes is the same file or CLI call an existing channel
  makes; a test per item runs the gate once with the app's write and once with
  the old channel's and compares the gate's decision.
- With the app not running, every gate behaves exactly as today (the existing
  hook suites stay green; no hook reads anything the app writes except the
  files the old channels already write).
- Screens: each tab and the Needs-you strip, dark and light, empty and full.

## Backlog (owner, 2026-09-25): next session

Built since this plan: Usage tab (Claude and Codex bars, thresholds), Home tab
(WiZ bulbs), Machine > Schedules (launchd jobs: run now, plist, log) and
Machine > Session > Wake a device. Still open, in no set order:

1. The items above: Needs-you strip, Hooks tab, Dev servers, Local models.
2. csync integration: the owner's own tunnel toolkit on the tailnet (ipc=csync,
   Codex instance parity). Explore first. Tailscale's own device list: not soon.
3. Git status across ~/Code, plus worktree management.
4. Connected devices and drives: mount point, disk format, basic actions.
5. Wi-Fi, Bluetooth, sound and brightness in one place, so the individual menu
   bar widgets can be hidden.
6. Disk and cleanup belongs in sys-monitor (~/Code/Claude/sys-monitor), not here.

Never: backups.

## Next session, first (owner, 2026-09-25)

1. Make the repo github.com/alcatraz627/switchboard-mac (public) and give it a
   proper README via /readme, with a /banner-fun banner. Decide first whether the
   Switchboard is extracted from the claude-instances widget or the widget repo is
   published under that name. Pushing needs a fresh owner approval.
2. Then: versioned releases with a changelog, and proper docs.

## More backlog (owner, 2026-09-25)

- Bulbs: renaming already exists (the ⋯ menu > Rename…, saved by MAC in
  ~/.claude/widgets/.wiz-names.json); check it is enough. Add a colour wheel and
  the other Philips WiZ options (rgb, speed, scene extras).
- Smartivity smart plugs: integrate alongside the bulbs on the Home tab.
- Revisit every option and group shown; several booleans may want
  allow / ask / block instead.
