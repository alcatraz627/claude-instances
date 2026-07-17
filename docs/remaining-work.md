# Remaining work — dashboard truthfulness

Living doc. Written 2026-07-17 at the end of the audit that produced `b225076`.
Everything here is measured or reproduced, not inferred. Read the **Ground
truth** section before touching anything — it exists so you don't re-derive what
cost a whole session to learn.

## The principle these all serve

The owner's framing, verbatim, because it decides priority better than severity
labels do:

> "When the whole transcripts page blows up, it feels like an error one can fix,
> an understandable aspect of writing software. But when the small logical bugs
> cause the system to behave in a self-inconsistent or contradictory or
> reality-divergent way, that's when it truly feels broken, and it breaks trust
> more than an outright error."

So: a number that is confidently wrong outranks a crash. R1 below is a *display*
bug by conventional triage and the highest-value item here by this standard —
the header says "today: 19 sessions" when there are 148.

---

## Ground truth — do not re-derive these

**The tree.** `main`, unprotected. `b225076` (the audit) and `8d61a30` (an
earlier session's provider artifacts) are committed. As of writing, ~20 commits
were ahead of `origin/main` and the push was pending the owner's per-push
approval sentinel — check `git status -sb` rather than trusting this line.

**Tests.** `bash tests/run-tests.sh` → **6 failed / 232 passed**. Those 6 are a
pre-existing baseline (1 `bar FAILED to compile` + 5 SPA greps for `const HUB =`
/ `function diffBlock` in `transcript-app.html`). They fail on a clean checkout
too. **A 7th failure is yours.** The suite takes ~90s (it compiles Swift), so
run it in the background.

**Calling scan.sh's internals.** It is a bash wrapper around an embedded python
heredoc, so nothing is importable. Use the probe:

```bash
python3 tests/fixtures/scan-probe.py estimate opus 1000000 1000000   # -> 90.0
python3 tests/fixtures/scan-probe.py read_cost <pid>
python3 tests/fixtures/scan-probe.py tokens 'Infinity'               # -> 0
python3 tests/fixtures/scan-probe.py local_day '2026-07-16T19:00:00Z'
python3 tests/fixtures/scan-probe.py tail <file> <n>
python3 tests/fixtures/scan-probe.py read_pid_file <pid> <kind>
python3 tests/fixtures/scan-probe.py turns_big 40                    # -> 40:40:True
python3 tests/fixtures/scan-probe.py history_session 12              # -> 12:120:60
python3 tests/fixtures/scan-probe.py poison_scan                     # -> STRICT_JSON_OK
```
Its `load()` shows the exec trick if you need it directly. `since-probe.py`
drives the real client poll loop against a growing fixture.

**The hub.** Runs on `127.0.0.1:5400` from this tree. `scan.sh` re-runs per
request (2s cache) so scan edits are live with no restart — but `hub-server.py`
and `transcript.py` are imported into the process, so **those need
`bash lib/hub.sh restart`**. Always `python3 -c "import ast; ast.parse(...)"`
both before restarting a service the owner is looking at.

**Hard-won facts.** Each of these cost real time:

- `lsof` **ORs** its selection flags. `-p <pids> -d cwd` means "these pids OR
  any cwd" and dumps the whole process table — 2394 lines for a pid that does
  not exist. `-a` ANDs them. This is why `prime_process_info` passes `-a`.
- `os.path.exists()` returns **True** for a FIFO; only `os.path.isfile()` is
  False. Opening a FIFO with no writer blocks forever. The codebase's original
  `exists()` guard protected nothing — every per-PID read goes through
  `read_pid_file()` for exactly this reason.
- `json.loads` accepts a bare `Infinity`/`NaN`. A transcript is a file on disk,
  so usage counts are untrusted; `token_count()` is the boundary. An infinite
  cost serializes to a literal no JSON parser accepts and takes down every
  consumer of the scan, not one card.
- `parse_qs` drops blank values unless `keep_blank_values=True` — `?since=` read
  as "absent" and bypassed validation entirely.
- macOS has **no `timeout(1)`**, and a plain `perl alarm` orphans the child. Use
  the process-group kill (see the FIFO tests in `run-tests.sh`).
- `re.sub(r'[/.]', '-', cwd)` in scan.sh is **not a bug**. It mirrors Claude
  Code's own project-dir naming (`/Users/x/.claude` → `-Users-x--claude`,
  verified against 4 real dirs). "Fixing" it points the scanner at directories
  that do not exist. A reviewer will flag it; reject it.
- The scan's cost is **95% subprocess spawns**, not file reads. Profile before
  optimizing: the 26MB `readlines()` everyone blames was 17ms of 2835ms.

**Never** run `git checkout` / `stash` / `reset` / `clean` to test a mutation —
restore by copy. **Never** write a real `/tmp/claude-{cost,tpath,statusline,ctx}-<pid>`
for a live pid; use fake pids in the 999xxx range. **Never** plant fixtures in
the real `~/.claude/projects` (a permission hook will stop you, but don't rely
on it).

---

## R1 — Aggregates cover 20 sessions and call it "today"

**Priority: highest.** This is the owner's principle in its purest form: the
header states "today: 19 sessions" when the real number is **148** (209 over 7
days). It is not a missing feature; it is a confident falsehood.

**Why it is not already fixed.** `aggregates = compute_aggregates(history)` in
scan.sh, and `get_session_history(max_sessions=20)` caps the pool — so the
totals can only see what the *display list* parsed. Widening the window costs
**+838ms** on a scan that already takes 2.06s (measured: 209 sessions / 508MB
over 7 days; 148 / 120MB for today alone).

**The fix, in order:**
1. Build a per-file summary cache keyed by `(path, mtime, size)` →
   `{turns, tokens_in, tokens_out, model}`. Unchanged sessions never re-parse.
   A sensible home is `~/.claude/widgets/.session-summaries.json`, written
   atomically (tmp + rename), pruned to files that still exist.
2. Decouple `compute_aggregates` from the 20-row display list: give it its own
   file list over the real window (today + 7 days), served from the cache.
3. Keep `max_sessions=20` for the display list. That cap is correct — it is a
   list of rows, not a total.

**Do not** widen the window before the cache exists. Making the dashboard slower
to make one number righter is a bad trade, and the owner watches this thing all
day.

## R2 — `seq` is positional but the client treats it as identity

**The bug.** `next_seq()` in transcript.py numbers records by position on every
parse. Insert a line mid-file and every later seq shifts: the client's `lastSeq`
then points at a different record. Reproduced by a reviewer in a real browser —
the tools group **duplicates** (rendered at both the stale and the new seq) and
the genuinely-new record is **silently dropped** (it is neither `seq > lastSeq`
nor `open`).

**Two things you must know before you touch it** (both tested; the reviewer's
report did not establish either):

1. **It is not caused by the `open`-resend change.** The OLD filter (`seq > n`)
   and the NEW one (`seq > n or open`) fail *identically* against the same
   renumber — 2 tools groups, dropped message, both. Do not "fix" it by
   reverting the live-tail work.
2. **It is unreachable today.** Claude Code appends; a mid-file insert needs a
   rewrite. This is latent, not active. That is why it was filed rather than
   improvised at the end of a long session.

**The fix.** Records need a stable identity that survives a re-parse. The
transcript's own `uuid` per line is the obvious candidate (check it is present
and stable across resume/compaction before committing to it — read a real
transcript, don't assume). Then:
- `transcript.py` emits `id` alongside `seq` (keep `seq` for ordering/anchors —
  `data-seq` and `#r<seq>` deep links depend on it, see `transcript-app.html`
  around the chapter/outline code).
- `/data`'s cursor becomes id-based, or `since` keeps meaning "position" but the
  client keys its merge on `id`.
- `transcript-app.html`: `refreshOpen`'s `findIndex(x => x.seq === r.seq)` and
  `pollLive`'s fresh/tail split key on `id`. `state.expanded` uses
  `seq + ':' + i` — that must move too or expansion state breaks on renumber.

This is a contract change across three files. Design it, don't patch it.

## R3 — Small and known

Each is self-contained; none needs design.

| # | what | where | note |
|---|---|---|---|
| R3.1 | `hub.sh` reports success when the **loopback co-bind** fails, printing a dead "this Mac" URL. The primary-port collision path is correct and tested; this is the *secondary* 127.0.0.1 bind failing while the tailnet bind succeeded. | `lib/hub.sh` start check + `lib/hub-server.py` (the co-bind block) | Verify the printed URL actually answers before claiming success |
| R3.2 | `PID_FILE` is not port-scoped → `CLAUDE_HUB_PORT=X hub.sh start` says "already running" about a hub on another port, and prints a dead URL for X. | `lib/hub.sh:20-21` | `/tmp/claude-hub-${PORT}.pid` (and the log). Check nothing else reads the old fixed path first. |
| R3.3 | `/data` re-parses the entire transcript on **every poll**, uncached, while being the incremental live-tail. Largest transcript on disk: 56MB. | `lib/hub-server.py` `_serve_data` | Cache keyed by `(path, mtime, size)` like R1's; they may share one helper |
| R3.4 | `read_tab_title` does an uncached full `os.listdir('/tmp')` **per live instance**, and again per event. | `lib/scan.sh` | Prime once per scan like `prime_process_info` does |
| R3.5 | `codex_parse_session` reports `tokens_in/out: 0` where the data is genuinely unavailable — reads as "used nothing" rather than "unknown". `cost_usd` is already `None` for codex. | `lib/scan.sh` | Verified: the codex format carries no usage keys at all. Making it `None` needs the aggregate sum (`or 0`) and `kfmt` to tolerate null, same shape as the cost fix |
| R3.6 | `transcript.py`'s own `--since` CLI flag lacks the `or r.get("open")` treatment that `/data` has. | `lib/transcript.py` main() | Dormant — nothing in the tree calls it. A latent trap for whoever reaches for the documented flag expecting parity |
| R3.7 | `read_transcript_path` trusts a stale tpath (PID reuse). Defense-in-depth only: **0 orphans** on this machine, the daemon reaps. | `lib/scan.sh` | Cheap guard if wanted: compare the tpath file's mtime against the process start (`ps -o lstart=`). Costs a subprocess per pid per scan — probably not worth it; batch it into `prime_process_info` if you do |

## How to work on these

The pattern that produced every real finding this session: **run it, don't read
it.** Every intuition lost to a measurement — "add a truncated flag" died at a
99% undercount, "parsing everything is too slow" died at +14ms, "the 26MB read
is the bottleneck" died at 17ms of 2835ms.

And **watch each guard fail before trusting it**. Every test added here was
mutation-tested: break the thing it protects on a `/tmp` copy, confirm the test
goes red, restore by copy. A guard nobody has seen fail is decoration.

## Reports

- `/Users/alcatraz627/.claude/widgets/claude-instances/.claude/output/20260717-final-review/REPORT.md`
  — the full audit, the 12 fixes, the adversarial review, and the dispositions
- `/Users/alcatraz627/.claude/widgets/claude-instances/.claude/output/20260717-0005-skeptical-review/REVIEW.md`
  — the original 20 findings with file:line
