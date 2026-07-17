"""Does the since= fix deliver the grown group AND still go idle?

Two failure modes, opposite directions:
  1. the original bug — tools appended to an already-seen seq never arrive
  2. the naive fix — always resending the open group means records is never
     empty, so the client's quietPolls never increments and the UI never
     returns to 'your turn'

Simulates the real client loop (transcript-app.html:1164-1190) against a
live-appended fixture. Throwaway files under /tmp only.
"""
import os, sys, json, shutil

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
import transcript

ROOT = "/tmp/ci-since-fixed"
shutil.rmtree(ROOT, ignore_errors=True)
os.makedirs(ROOT, exist_ok=True)
F = f"{ROOT}/s.jsonl"

def user(t):
    return json.dumps({"type": "user", "timestamp": "2026-07-17T00:00:00Z",
                       "message": {"role": "user", "content": t}})

def tool(i):
    return json.dumps({"type": "assistant", "timestamp": "2026-07-17T00:00:01Z",
                       "message": {"role": "assistant", "model": "claude-opus-4-8",
                                   "usage": {"input_tokens": 1, "output_tokens": 1},
                                   "content": [{"type": "tool_use", "id": f"t{i}",
                                                "name": "Bash", "input": {"n": i}}]}})

def text(t):
    return json.dumps({"type": "assistant", "timestamp": "2026-07-17T00:00:02Z",
                       "message": {"role": "assistant", "model": "claude-opus-4-8",
                                   "usage": {"input_tokens": 1, "output_tokens": 1},
                                   "content": [{"type": "text", "text": t}]}})

def append(lines):
    with open(F, "a") as f:
        for l in lines:
            f.write(l + "\n")

# The client, faithful to transcript-app.html's poll loop.
class Client:
    def __init__(self):
        self.records = []
        self.lastSeq = 0
        self.quietPolls = 0
        self.state = "working"

    def poll(self):
        res = transcript.parse_transcript(F)
        recs = [r for r in res["records"] if r["seq"] > self.lastSeq or r.get("open")]
        fresh = [r for r in recs if r["seq"] > self.lastSeq]
        tail = [r for r in recs if r["seq"] <= self.lastSeq]

        grew = False
        for r in tail:
            i = next((k for k, x in enumerate(self.records) if x["seq"] == r["seq"]), -1)
            if i < 0:
                continue
            if len(r.get("tools") or []) <= len(self.records[i].get("tools") or []):
                continue
            self.records[i] = r
            grew = True

        if fresh:
            self.lastSeq = fresh[-1]["seq"]
            self.records.extend(fresh)

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
      f"tools seen = {c.tools_seen()} (want 2), cursor={c.lastSeq}, state={c.state}")

# The burst continues under the SAME seq — the original data-loss case.
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

# Text closes the burst; a new group must still arrive normally.
append([text("done"), tool(6)])
n, grew = c.poll()
check("post-close records still arrive", c.tools_seen() == 6 and c.state == "working",
      f"tools seen = {c.tools_seen()} (want 6), fresh={n}, state={c.state}")

shutil.rmtree(ROOT, ignore_errors=True)
print("\n" + ("ALL PASS" if not fails else f"FAILURES: {fails}"))
sys.exit(1 if fails else 0)
