"""Does the live tail deliver everything exactly once — and still go idle?

Failure modes covered, each a real incident or the audit's browser repro:
  1. the original bug — tools appended to an already-seen seq never arrive
  2. the naive fix — always resending the open group means records is never
     empty, so quietPolls never increments and the UI never says 'your turn'
  3. the renumber — a mid-file insert shifts every later seq, so a seq-keyed
     client renders the tools group twice and silently drops the genuinely-new
     record; identity must come from record ids, not positions
  4. the grow-and-close gap — a group that gains tools AND closes between two
     polls falls out of both the open-resend and the after-cursor buckets; the
     cursor must never park on an open group or that growth is lost forever

Simulates the real client loop (transcript-app.html pollLive/refreshOpen) and
the server slice (hub-server.py /data after_id) against a live-appended
fixture. Throwaway files under /tmp only.
"""
import os, sys, json, shutil

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
import transcript

ROOT = "/tmp/ci-since-fixed"
shutil.rmtree(ROOT, ignore_errors=True)
os.makedirs(ROOT, exist_ok=True)
F = f"{ROOT}/s.jsonl"

_uuid_n = 0
def _uuid():
    global _uuid_n
    _uuid_n += 1
    return f"uu-{_uuid_n:04d}"

def user(t, with_uuid=True):
    o = {"type": "user", "timestamp": "2026-07-17T00:00:00Z",
         "message": {"role": "user", "content": t}}
    if with_uuid:
        o["uuid"] = _uuid()
    return json.dumps(o)

def tool(i):
    return json.dumps({"type": "assistant", "uuid": _uuid(),
                       "timestamp": "2026-07-17T00:00:01Z",
                       "message": {"role": "assistant", "model": "claude-opus-4-8",
                                   "usage": {"input_tokens": 1, "output_tokens": 1},
                                   "content": [{"type": "tool_use", "id": f"t{i}",
                                                "name": "Bash", "input": {"n": i}}]}})

def text(t):
    return json.dumps({"type": "assistant", "uuid": _uuid(),
                       "timestamp": "2026-07-17T00:00:02Z",
                       "message": {"role": "assistant", "model": "claude-opus-4-8",
                                   "usage": {"input_tokens": 1, "output_tokens": 1},
                                   "content": [{"type": "text", "text": t}]}})

def mode(pm):
    # Faithful to the real line shape: no uuid, no timestamp.
    return json.dumps({"type": "permission-mode", "permissionMode": pm, "sessionId": "s"})

def append(lines):
    with open(F, "a") as f:
        for l in lines:
            f.write(l + "\n")

def server_slice(records, after_id):
    """hub-server.py /data: records after the cursor id, plus open resends.
    Unknown cursor -> the full set, flagged, so the client reconciles by id."""
    if after_id is None:
        return records, False
    idx = next((i for i, r in enumerate(records) if r.get("id") == after_id), None)
    if idx is None:
        return records, True
    return [r for r in records[:idx + 1] if r.get("open")] + records[idx + 1:], False

# The client, faithful to transcript-app.html's poll loop.
class Client:
    def __init__(self):
        self.records = []
        self.lastId = None
        self.quietPolls = 0
        self.state = "working"

    def poll(self):
        res = transcript.parse_transcript(F)
        recs, reset = server_slice(res["records"], self.lastId)
        if reset:
            # The cursor names a record that no longer exists — adopt the
            # server's set wholesale; id-keyed expansion state survives.
            self.records = list(recs)
            self.lastId = next((r["id"] for r in reversed(recs)
                                if not r.get("open")), None)
            self.quietPolls = 0
            self.state = "working"
            return len(recs), False
        known = {r["id"]: k for k, r in enumerate(self.records)}
        fresh, grew = [], False
        for r in recs:
            k = known.get(r["id"])
            if k is None:
                fresh.append(r)
                continue
            before = len(self.records[k].get("tools") or [])
            after = len(r.get("tools") or [])
            if after == before:
                continue
            # Adopt the server's version either way (a shrunk group must not
            # stay frozen at its peak); only growth counts as activity.
            self.records[k] = r
            if after > before:
                grew = True
        if fresh:
            self.records.extend(fresh)
            # Never park the cursor ON an open group: one that grows and
            # closes between two polls would fall out of both the open-resend
            # and the after-cursor buckets, losing the growth forever. Anchor
            # at the last CLOSED record so an open group keeps being fetched
            # until it has been seen closed.
            for r in reversed(fresh):
                if not r.get("open"):
                    self.lastId = r["id"]
                    break
        if fresh or grew:
            self.quietPolls = 0
            self.state = "working"
        else:
            self.quietPolls += 1
            if self.quietPolls >= 2:
                self.state = "yourturn"
        return len(fresh), grew

    def tools_seen(self):
        return sum(len(r.get("tools") or []) for r in self.records if r.get("kind") == "tools")

fails = []
def check(name, ok, detail):
    print(f"[{'PASS' if ok else 'FAIL'}] {name}\n       {detail}")
    if not ok:
        fails.append(name)

c = Client()

# Agent starts a burst: 2 tools land.
append([user("go"), tool(1), tool(2)])
c.poll()
check("client catches up mid-burst", c.tools_seen() == 2,
      f"tools seen = {c.tools_seen()} (want 2), cursor={c.lastId}, state={c.state}")

# The burst continues under the SAME record identity — the original data-loss case.
append([tool(3), tool(4), tool(5)])
n, grew = c.poll()
check("grown group is delivered", c.tools_seen() == 5,
      f"tools seen = {c.tools_seen()} (want 5) — was 2 before the fix; "
      f"fresh={n} grew={grew} state={c.state}")

check("growth counts as activity", c.state == "working",
      f"state={c.state} (want working — the agent is mid-burst)")

check("no duplicate records", len([r for r in c.records if r.get('kind') == 'tools']) == 1,
      f"tools groups in state = {len([r for r in c.records if r.get('kind') == 'tools'])} (want 1)")

# Nothing more happens. The UI must eventually say 'your turn' — this is the
# regression the naive fix would have introduced.
c.poll()
s1 = c.state
c.poll()
check("goes idle when the burst stops", c.state == "yourturn",
      f"after 2 quiet polls state={c.state} (want yourturn; after 1 it was {s1}). "
      f"A resend that always counted as activity would pin this at 'working'.")

# Text closes the burst; a new group must still arrive normally. The mode
# flips ride along: uuid-less, timestamp-less lines whose SECOND flip to the
# same value must still mint a distinct id (this was a live-data collision).
append([text("done"), mode("plan"), mode("auto"), mode("plan"), tool(6)])
n, grew = c.poll()
check("post-close records still arrive", c.tools_seen() == 6 and c.state == "working",
      f"tools seen = {c.tools_seen()} (want 6), fresh={n}, state={c.state}")

# ── Identity: every record has a stable, unique, non-positional id ──────────
res = transcript.parse_transcript(F)
ids = [r.get("id") for r in res["records"]]
check("every record carries an id", all(ids),
      f"ids={ids}")
check("ids are unique within a parse", len(ids) == len(set(ids)),
      f"ids={ids}")
res2 = transcript.parse_transcript(F)
check("ids are stable across a re-parse", ids == [r.get("id") for r in res2["records"]],
      "two parses of the same bytes must agree on every id")

# ── Renumber: a mid-file insert shifts every seq; identity must hold ─────────
# Ids must not shift; the id-merge must neither render the tools group twice
# nor drop the appended record. The inserted line itself lands BEFORE the
# cursor — a tail honestly does not deliver history; it appears on full load.
before_ids = set(ids)
lines = open(F).read().splitlines()
lines.insert(1, user("inserted mid-file", with_uuid=False))
with open(F, "w") as fh:
    fh.write("\n".join(lines) + "\n")
append([text("after the insert")])

res3 = transcript.parse_transcript(F)
after_ids = [r["id"] for r in res3["records"]]
check("pre-existing ids survive the renumber", before_ids <= set(after_ids),
      f"missing: {sorted(before_ids - set(after_ids))}")

n, grew = c.poll()
check("appended record survives the renumber",
      any(r.get("text") == "after the insert" for r in c.records),
      f"fresh={n} — a seq-keyed client silently drops this record")
check("nothing renders twice after the renumber",
      len(c.records) == len({r["id"] for r in c.records}) and c.tools_seen() == 6,
      f"records={len(c.records)} unique={len({r['id'] for r in c.records})} tools={c.tools_seen()}")

# A record parsed from a uuid-less line still gets a deterministic id — the
# fallback must be content-derived (crc), never a per-process salted hash.
ins1 = [r for r in res3["records"] if r.get("text") == "inserted mid-file"]
res4 = transcript.parse_transcript(F)
ins2 = [r for r in res4["records"] if r.get("text") == "inserted mid-file"]
check("uuid-less line gets a deterministic id",
      bool(ins1) and bool(ins2) and ins1[0]["id"] == ins2[0]["id"],
      f"parse1={ins1[0]['id'] if ins1 else '-'} parse2={ins2[0]['id'] if ins2 else '-'}")

# ── Vanished cursor: reconcile, don't trust it ───────────────────────────────
c2 = Client()
c2.poll()
c2.lastId = "gone-cursor"
c2.poll()
check("vanished cursor reconciles by id, no dupes",
      len(c2.records) == len({r["id"] for r in c2.records}) and len(c2.records) == len(res4["records"]),
      f"records={len(c2.records)} want {len(res4['records'])}, all unique")

# ── Grow-and-close: growth in the same gap as the close must still arrive ───
open(F, "w").close()
c3 = Client()
append([user("go2"), tool(7)])
c3.poll()
append([tool(8), text("closed it"), tool(9)])
c3.poll()
seen = {t["id"] for r in c3.records if r.get("kind") == "tools"
        for t in r.get("tools") or []}
check("growth delivered when the group closes in the same gap",
      seen == {"t7", "t8", "t9"},
      f"tool ids seen = {sorted(seen)} (want t7,t8,t9) — a cursor parked ON an "
      f"open group loses t8 forever")

# The CLI --since must resend the open group exactly like /data does — it is
# the documented flag; parity gaps trap whoever reaches for it.
import subprocess
res5 = transcript.parse_transcript(F)
last_seq = res5["records"][-1]["seq"]
cli = subprocess.run(
    [sys.executable,
     os.path.join(os.path.dirname(os.path.abspath(transcript.__file__)), "transcript.py"),
     F, "--since", str(last_seq)],
    capture_output=True, text=True)
cli_recs = json.loads(cli.stdout or '{"records": []}').get("records", [])
check("--since CLI resends the open group",
      len(cli_recs) == 1 and cli_recs[0].get("open") is True,
      f"records={len(cli_recs)} (want the 1 open group), "
      f"open={cli_recs[0].get('open') if cli_recs else '-'}")

shutil.rmtree(ROOT, ignore_errors=True)
print("\n" + ("ALL PASS" if not fails else f"FAILURES: {fails}"))
sys.exit(1 if fails else 0)
