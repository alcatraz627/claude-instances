# gcc policy panel: one store, one click from the top bar

<!-- sessions: gcc-flags@2026-09-24 -->

Owner ask, 2026-09-24, verbatim where it binds:

> "I don't mind if the agents use git or gh or mcp, I just want them to follow
> the guard allow / block as set, usually global, sometimes a local project
> override. If they have allowance, they shouldn't stupidly ask me to approve
> (they can still ask me out of precaution but not because they think it is
> hook blocked)"

> "all I want is to be able to set the policy without typing a sentence or
> constantly approving a guard or having an agent burn through 20k tokens
> every time there's a change."

> "I don't want command-level granularity, it is either full-allow or
> full-block, mainly global, sometimes local override"

This supersedes workstream 1 of `20260825-capabilities-consolidation-plan.md`
(permission guards in the dropdown, never built).

## Owner rulings (2026-09-24)

| # | Question | Ruling |
|---|---|---|
| R1 | Surface | A second menu bar icon served by the claude-instances app, opening a popover. Fallback, only if this fails: a section in the existing dropdown. A kanban page: "absolutely not". Quality bar, verbatim: "ergonomic, low resource consumption, properly visually spaced, and doing proper indication with UI hierarchy and colors and typography without looking like a spaghetti mess". |
| R2 | Push to main | A three-state policy: allow / ask each push / block. Default: ask each push. |
| R2b | Policy types | "the policy type setup to also allow the config to specify the kind of options it wants to show (boolean, enum like this case, dropdown, slider/number with bounds, etc), and we just show a proper UI for it." |
| R3 | Old stores | Migrate all of them, "but first we prove the new feature works fine and I like it before decommissioning the older one." The old stores stay live and authoritative until the owner signs off. |
| R4 | Heavy local models | No RAM slider ("if a model needs a large chunk of RAM then it needs it"). Two states: allow (silent) / warn. Warn tells the agent to still run the model when the output justifies it. Verbatim: "I would hate if the models start using this as an excuse to skip on things that need to be run for quality". |
| R5 | Fable, Codex, heavy models | Three separate policies: "when fable is to be avoided is EXACTLY when codex should be encouraged". |
| R6 | Snooze | Any policy can carry a snooze: at a set time, it flips to a named value. The snooze can be set without changing the current value. No general timer machinery. |
| R7 | Effort and model | Dropped. Claude Code controls those directly. |
| R8 | Env file reads | A policy, global with project override. |

## Current behaviour (the parity baseline)

Allow and block live in five stores, all read per call by hooks:
- about 80 mute files (`.no-*`, `.*-off`), found by regex in `native/Switchboard.swift:34`
- `~/.claude/hooks/snooze.jsonl` (`scripts/hooks/hook-snooze.sh`), which holds the `fable-restrict` row read at `guard-model-tier.sh:51`
- `~/.claude/protected-repos.list`, read by `guard-user-commit.sh`
- single-use `.push-approved-<sid>` nonces (`guard-git-push.sh:40`)
- `settings.json`, read by the harness at session start

The dropdown Switchboard (`Bar.swift:1208`) shows mutes, stale approvals,
prompt suppressors, services, always-thinking and keep-awake, and it keeps
all of them. Codex runs the same guards through
`adapters/codex/hooks/pre-tool-bash.sh:23-31`. Nothing guards
`mcp__github__*`, the Slack, Linear or Vercel connectors, or `wrangler`.

## Shape

```
  menu bar ── [instances icon]  existing dropdown, unchanged
          └── [policy icon] ──▶ popover (SwiftUI): scope picker, groups,
                                 one control per policy, rendered from type
                   │ reads/writes (the owner's clicks only)
                   ▼
  ~/.claude/policy/registry.json   what exists: key, label, group, type,
                                   options/bounds, default, scopes, help
  ~/.claude/policy/policy.json     values: global + projects{<abs root>}
                                   each value may carry {snooze_until, then}
                   ▲ read per call (lazy snooze expiry, no daemon)
  pol.sh get <key>    [--cwd]  ◀── guards (Bash + MCP matchers), Codex adapter
  pol.sh set|snooze   |list|json    session-start one-line summary
```

- **Types**: `bool` (switch), `enum` (a segmented control at 3 options or
  fewer, a dropdown above that), `number` (a slider or stepper with
  `min`/`max`/`step`). The panel renders from the registry, so adding a
  policy means adding a registry entry, with no Swift change.
- **Resolution**: project value (the project root of the cwd), then global,
  then the registry default. An expired snooze resolves to its `then` value.
- **Allowed means silent.** A guard for an allowed policy emits nothing. A
  block message reads "switched off by owner policy <key>; tell the owner,
  do not ask to approve". The session-start line lists the non-default
  values and says that allowed means proceed.
- **Agent write-block**: agent Bash, Write and Edit calls into
  `~/.claude/policy/` are blocked. Only the panel and the owner's own shell
  write there.
- **Coexistence (R3)**: until sign-off, each rewired guard blocks if EITHER
  the old store OR the policy says block, so the new store can only add
  protection while it is being proven.

## Registry, first cut

| Key | Group | Type | Options | Default | Scope | Enforcement |
|---|---|---|---|---|---|---|
| `github.comment` | Acting as you | bool | | allow | g+p | new guard: gh CLI + `mcp__github__add_issue_comment`, reviews |
| `github.write` | Acting as you | bool | | allow | g+p | new guard: issues, PRs, merge, close via gh CLI + MCP |
| `slack.post` | Acting as you | bool | | allow | g | new guard: Slack connector send/schedule/react/canvas |
| `linear.write` | Acting as you | bool | | allow | g | new guard: Linear connector writes |
| `artifact.publish` | Acting as you | bool | | block | g | `guard-artifact-unasked.sh` |
| `git.commit` | Code | bool | | allow | g+p | `guard-user-commit.sh` |
| `git.push` | Code | bool | | allow | g+p | `guard-git-push.sh` + MCP `push_files` / `create_or_update_file` |
| `git.push_main` | Code | enum | allow / ask / block | ask | g+p | `guard-git-push.sh` (ask = today's nonce flow) |
| `deploy.vercel` | Deploy | bool | | allow | g+p | new guard: Vercel connector writes |
| `deploy.cloudflare` | Deploy | bool | | allow | g+p | new guard: `wrangler deploy`, `wrangler kv … put/delete` |
| `deploy.render` | Deploy | enum | allow / ask / block | ask | g | `render-mcp-gate.py` (ask = today's nonce) |
| `model.fable` | Models | bool | | allow | g | `guard-model-tier.sh` |
| `model.codex` | Models | enum | encourage / allow / block | allow | g | codex dispatch path; encourage adds a session-start nudge |
| `model.heavy_local` | Models | enum | allow / warn | allow | g | new PreToolUse on `imagine`, `see`, `lm q --big`; warn text per R4 |
| `files.env_read` | Machine | bool | | block | g+p | `guard-env-access.sh`, `guard-secret-file-read.sh` |
| `files.system_write` | Machine | bool | | block | g | `guard-system-dir-writes.sh` |
| `files.cred_write` | Machine | bool | | block | g | `.allow-cred-write` guard |
| `ops.usage_gate_pct` | Limits | number | 50-100 step 5 | 90 | g | `scripts/cron/usage-gate.sh:24` |
| `ops.fable_warn_pct` | Limits | number | 50-100 step 5 | 80 | g | `scripts/policy.sh:50` |
| `ops.fable_strong_pct` | Limits | number | 50-100 step 5 | 90 | g | `scripts/policy.sh:49` |
| `ops.subagent_model` | Limits | enum | haiku / sonnet / opus | sonnet | g | session-start line + model-tier guard default |
| `ops.workflow_size` | Limits | enum | small / medium / large | small | g | session-start line |
| `gates.prose_smell` | Gates | enum | off / warn / enforce | warn | g | `prose-smell-stop.sh` |

The heavy-model warn text (R4), in full: "Owner policy: heavy local models on
warn. RAM will be tight while this runs. Run it anyway when the output
quality justifies it; do not swap in a smaller model or skip the check to
save memory."

## Status (2026-09-25)

Steps 1 to 5 are built and tested: store and `pol.sh` (56 checks), the hooks
(186 checks across every key and route, plus the existing suites for each
rewired guard, still green), and the panel (21-check store probe, real
popover captured in dark, offscreen render in light). The dropdown Switchboard
dump is byte-identical before and after. Step 6 (migrating and retiring the old
stores) waits on the owner trying the panel. Reference: `~/.claude/features/agent-policy.md`.

Refinements made during the build: `files.cred_write` dropped (its sentinel
belongs to the Anthropic credential guard, which is never switchable);
`artifact.publish` became allow / ask / block, because today's rule is "ask";
`deploy.render` keeps its nonce as its "ask" state.

## Build order

Each step is proven on its own before the next one starts.

1. `policy/registry.json` + `policy.json` + `scripts/pol/pol.sh` (named to avoid the existing `scripts/policy.sh`) (get/set/snooze/list/json)
   + the agent write-block guard.
2. The new guard on Bash + MCP matchers for the unguarded paths, and the
   session-start summary line.
3. Rewire the existing guards in coexistence mode (R3) and add the new guard
   to the Codex adapter.
4. The popover: second status item, SwiftUI view rendered from the registry,
   scope picker, snooze affordance per row, headless dump for the probe.
5. Visual verification in dark and light, then the owner tries it.
6. After owner sign-off only: migrate the old stores and retire them.
