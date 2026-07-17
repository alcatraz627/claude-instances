# Provider generalization — claude-instances → agentic-runner × model dashboard

<!-- sessions: scour-fable-a3@2026-07-10 -->

The dashboard today monitors exactly one agent runtime: Claude Code. This design
generalizes it so any local agentic runner (codex today, aider/antigravity later)
appears as a session row, and the local one-shot model tools (`q`/`see`/`fleet`/
`gem`) get their own calls panel. It resolves pin `pin-20260706085636-68`
("at the weekly audit, decide whether to build (1) and/or (2)" — decision
2026-07-10: build both, phased, option 2 first).

## Current architecture (grounded)

- `lib/scan.sh` (1,054 lines, bash wrapper around one embedded Python) is the
  single source of truth. It emits ONE JSON object on stdout (`scan.sh:1053`).
- Claude is hard-coded in two places: process enumeration
  (`get_live_instances`, scan.sh:497 — `ps -Ao pid=,args=` filtered to
  `basename(argv[0]) == 'claude'`; deliberately ps-not-pgrep, see the comment at
  scan.sh:501) and transcript discovery (`~/.claude/projects/*/<uuid>.jsonl`,
  where session == transcript file and a matching live proc makes it "live").
- Consumers of the JSON: the Swift bar app (`native/main.swift:13` runs
  `lib/scan.sh`; `native/Models.swift` decodes), `lib/hub-server.py:53`, and
  `~/Code/Claude/sys-pier/adapters/claude-instances.cjs`.

## The provider interface (option 2 — CLEANEST)

Inside scan.sh's embedded Python, a provider is a dict of four capabilities:

```python
PROVIDERS = [claude_provider, codex_provider]   # each a Provider

Provider = {
  "name":            "claude",                  # stamped on every instance
  "proc_match":      fn(argv0_basename, cmdline) -> bool,
  "transcript_iter": fn() -> iter[path],        # provider's session files
  "parse_session":   fn(path) -> {id, cwd, model, started, last_activity,
                                   turns, tool_calls},
  "proc_meta":       fn(cmdline) -> {model_hint, resume_id},
}
```

Shared machinery stays shared (one `ps -Ao pid=,args=` pass for ALL providers,
one lsof-cwd helper, one live/recent pairing step). Pairing rule is unchanged:
a session whose cwd/resume-id matches a live proc of the SAME provider is live.

Output schema change is **additive only**: every instance gains
`"provider": "<name>"`. Absent field ⇒ `"claude"`, so the Swift app, hub, and
sys-pier adapter keep working before they learn to render the badge.

### The two initial providers

- **claude** (extraction of current logic, zero behavior change): proc match
  `basename == 'claude'` + the existing skip-list; transcripts
  `~/.claude/projects/*/*.jsonl`.
- **codex** (verified locally, codex 0.142.5 installed): transcripts at
  `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`; line 1 is
  `{"type":"session_meta","payload":{session_id, cwd, model_provider,
  cli_version, originator, ...}}` — cwd and id come free. Proc match
  `basename == 'codex'`. Model: session_meta has `model_provider` ("openai");
  per-turn model may appear deeper in the rollout — v1 shows
  `model_provider/cli_version`, refine later.

### Not providers

- **lm one-shot tools** (`~/Code/local-models/logs/{q,see,fleet,gem}-history.jsonl`,
  shape `{ts, intent, model, prompt, ...}`): calls, not sessions — no pid, no
  liveness, no transcript. Modeling them as a provider would poison the
  session/liveness semantics. They get a separate `lm_calls` summary block in
  the scan JSON (counts today / last call per tool / last N rows) and their own
  dashboard panel. This is the pin's option (1).
- **antigravity**: IDE-embedded, session store unknown. Investigation ticket,
  not a provider stub (no speculative interface entries — a provider lands only
  with a real transcript_iter).

## Phases

1. **Provider seam** (mechanical, sonnet-delegable): extract claude logic into
   `claude_provider`, add the `provider` field, shared ps pass. `tests/run-tests.sh`
   must stay green; scan JSON diff vs pre-refactor must show ONLY the added field.
2. **codex provider**: as spec'd above, plus a fixture test from a real (redacted)
   rollout head. Swift: render a provider badge on non-claude rows
   (`Models.swift` optional field, default "claude"; small `LiveRowView` chip).
3. **lm_calls block + panel**: scan JSON gains the summary block (cheap tail
   reads, no full-file parses); Dashboard gets the panel.
4. **antigravity investigation**: find its session store (likely under the IDE's
   app support dir), then it's just another provider dict.

## Phase 1/2a implementation notes (2026-07-10, post-review)

- **Per-provider recency slot** (implementer deviation, reviewer-endorsed, KEPT):
  each provider's most-recent transcript reserves a history slot before the rest
  compete on global recency — without it the lone codex session was buried under
  193 more-recent claude transcripts. No-op for the single-provider case; output
  stays recency-sorted.
- **Two undisclosed fixes rode inside `get_session_tokens` and are now
  disclosed** (review finding — Phase 1 was NOT strictly behavior-preserving):
  the cwd→slug transform gained `re.sub(r'[/.]', '-', …)` so dotted paths (e.g.
  `~/.claude/i-dream`) resolve their project dir — previously such live sessions
  showed no tokens/model at all — and a `prefer_sid` parameter pins token
  resolution to the `--resume` session id. Both are correct; both should have
  been declared. A dotted-cwd regression test is a named follow-up: the token
  path needs a live-pid harness the test suite doesn't have yet, and a
  copy-of-the-regex test would bypass the production path (test-harness trap).
- **Perf follow-up for Phase 2b:** `_build_codex_instance` re-parses every
  14-day codex transcript on each scan tick (~5s cadence in the bar app); cache
  by (path, mtime) before codex goes live-paired.
- **sys-pier caveat:** its adapter (`adapters/claude-instances.cjs`) enumerates
  processes itself (pgrep-style) instead of consuming scan.sh output — codex
  will NOT surface there, and it may be exposed to the compiled-binary pgrep
  trap scan.sh explicitly avoids. Fixing that belongs to sys-pier, not here.

## Risks / guards

- **Swift decode strictness**: additive JSON fields are safe (Codable ignores
  unknown keys); the OPTIONAL provider field must default to "claude" when absent
  so old scan output renders too.
- **Perf**: one shared ps pass; codex transcript glob is date-sharded — cap the
  walk to the last 14 days of shards (matches the existing recent-window).
- **The pgrep trap** (scan.sh:501): applies to any compiled runner; provider
  proc-matching stays on `ps -o args` basename, never pgrep.
- **Binary staleness**: any Swift change requires `native/build.sh` + restart —
  the fix-committed-≠-fix-running trap is documented in this repo's gotchas.

## Effort

Phase 1 ≈ 1-2h mechanical · Phase 2 ≈ 2-3h (codex parse is cheap; Swift chip is
the bulk) · Phase 3 ≈ 1-2h · Phase 4 unknown until investigated.
