"""Does repeated navigation stay cheap? The hub's latency contract under
real HTTP traffic.

Behavioral, not a grep: spins up the real HubHandler in-process against a
scratch projects tree and asserts the four properties that keep repeat
visits fast — the parse cache holds a whole fleet without thrashing,
concurrent peeks of one session share a single parse, an unchanged
transcript answers 304 to a conditional GET, and a stale /api/sessions
serves instantly while one background scan refreshes it. The one allowed
slow path is the true-cold first scan.
"""
import importlib.util, os, sys, json, shutil, time, threading, urllib.request, urllib.error, http.server

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
LIB = os.path.join(REPO, "lib")
ROOT = "/tmp/hub-perf-probe"
shutil.rmtree(ROOT, ignore_errors=True)
os.makedirs(ROOT, exist_ok=True)

spec = importlib.util.spec_from_file_location('hub_server', os.path.join(LIB, 'hub-server.py'))
hub = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hub)

PROJ = os.path.join(ROOT, "projects", "-tmp-x")
os.makedirs(PROJ, exist_ok=True)
hub.PROJECTS_DIR = os.path.join(ROOT, "projects")

_uuid_counter = {"n": 0}
def _next_uuid():
    _uuid_counter["n"] += 1
    return f"uu-{_uuid_counter['n']:04d}"

def write_session(sid, ntools, prefix="A"):
    p = os.path.join(PROJ, f"{sid}.jsonl")
    lines = [json.dumps({"type": "user", "uuid": _next_uuid(), "timestamp": "2026-07-17T00:00:00Z",
                         "message": {"role": "user", "content": f"{prefix}-start"}})]
    for i in range(ntools):
        lines.append(json.dumps({"type": "assistant", "uuid": _next_uuid(), "timestamp": "2026-07-17T00:00:01Z",
                                 "message": {"role": "assistant", "model": "claude-opus-4-8",
                                             "usage": {"input_tokens": 1, "output_tokens": 1},
                                             "content": [{"type": "tool_use", "id": f"{prefix}t{i}",
                                                          "name": "Bash", "input": {"n": i}}]}}))
    with open(p, "w") as f:
        f.write("\n".join(lines) + "\n")
    return p

# Count real parses through a shim so cache hits are observable facts.
_parse_calls = {"n": 0}
_real_parse = hub.transcript.parse_transcript
def _counting_parse(target, *a, **kw):
    _parse_calls["n"] += 1
    return _real_parse(target, *a, **kw)
hub.transcript.parse_transcript = _counting_parse

srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), hub.HubHandler)
threading.Thread(target=srv.serve_forever, daemon=True).start()
time.sleep(0.2)
port = srv.server_address[1]

def http_get(path, headers=None):
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()

fails = []
def expect(name, cond, detail=""):
    if cond:
        print(f"  OK   {name}")
    else:
        print(f"  FAIL {name}  {detail}")
        fails.append(name)

# ---- Test 1: a fleet-sized set of transcripts must not thrash the cache ----
FLEET = 20
sids = [f"fl{i:04d}00-0000-4000-8000-000000000000" for i in range(FLEET)]
for i, sid in enumerate(sids):
    write_session(sid, 2, f"fl{i}")
    http_get(f"/s/{sid}/data")
_parse_calls["n"] = 0
for sid in sids:
    http_get(f"/s/{sid}/data")
expect("second sweep over 20 unchanged transcripts parses NOTHING",
       _parse_calls["n"] == 0, f"re-parsed {_parse_calls['n']}/20")

# ---- Test 1b: the entry cap is also a byte cap (48 parsed transcripts of
# pathological size must not become resident memory the old 8-cap prevented) --
hub._PARSE_CACHE_BYTES_MAX = 1  # any real file exceeds this
write_session("bb000000-0000-4000-8000-000000000001", 2, "bb1")
write_session("bb000000-0000-4000-8000-000000000002", 2, "bb2")
http_get("/s/bb000000-0000-4000-8000-000000000001/data")
http_get("/s/bb000000-0000-4000-8000-000000000002/data")
expect("byte bound evicts down to the newest entry under pathological sizes",
       len(hub._PARSE_CACHE) == 1, f"len={len(hub._PARSE_CACHE)}")
hub._PARSE_CACHE_BYTES_MAX = 256 * 1024 * 1024
for sid in sids[:5]:
    http_get(f"/s/{sid}/data")

# ---- Test 1c: eviction is LRU, not FIFO — a re-touched entry survives an
# eviction a FIFO would have handed it (the gate proved the fleet test alone
# cannot see ordering; this is the discriminating case) ----
hub._PARSE_CACHE_MAX = 3
hub._PARSE_CACHE.clear()
lr = [f"1c{i:04d}00-0000-4000-8000-000000000000" for i in range(4)]
for i, sid in enumerate(lr[:3]):
    write_session(sid, 1, f"lr{i}")
    http_get(f"/s/{sid}/data")
http_get(f"/s/{lr[0]}/data")            # re-touch the oldest
write_session(lr[3], 1, "lr3")
http_get(f"/s/{lr[3]}/data")            # forces one eviction
_parse_calls["n"] = 0
http_get(f"/s/{lr[0]}/data")
survived = _parse_calls["n"] == 0
http_get(f"/s/{lr[1]}/data")
evicted = _parse_calls["n"] == 1
expect("LRU keeps the re-touched entry and evicts the cold one",
       survived and evicted, f"touched-reparsed={not survived} cold-cached={not evicted}")
hub._PARSE_CACHE_MAX = 48

# ---- Test 1d: transcript paths resolve once, not once per request — the
# recursive projects-tree glob must not run again for a known session ----
_glob_calls = {"n": 0}
_real_glob = hub.glob.glob
def _counting_glob(*a, **kw):
    _glob_calls["n"] += 1
    return _real_glob(*a, **kw)
hub.glob.glob = _counting_glob
sidG = "1d000000-0000-4000-8000-000000000000"
write_session(sidG, 1, "g")
http_get(f"/s/{sidG}/data")
_glob_calls["n"] = 0
http_get(f"/s/{sidG}/data")
expect("a known session's repeat request runs zero tree globs",
       _glob_calls["n"] == 0, f"globs={_glob_calls['n']}")

# ---- Test 2: concurrent peeks of one uncached session share one parse ----
sidX = "cafe0000-0000-4000-8000-0000000000ee"
write_session(sidX, 30, "X")
_parse_calls["n"] = 0
barrier = threading.Barrier(6)
def _peek():
    barrier.wait()
    http_get(f"/s/{sidX}/data")
threads = [threading.Thread(target=_peek) for _ in range(6)]
for t in threads: t.start()
for t in threads: t.join()
expect("6 concurrent peeks of one cold session = exactly 1 parse",
       _parse_calls["n"] == 1, f"parsed {_parse_calls['n']} times")

# ---- Test 3: conditional GET on an unchanged transcript answers 304 ----
st1, h1, b1 = http_get(f"/s/{sidX}/data")
etag = h1.get("ETag")
expect("/data carries an ETag", bool(etag), f"headers={sorted(h1)}")
if etag:
    st2, h2, b2 = http_get(f"/s/{sidX}/data", {"If-None-Match": etag})
    expect("matching If-None-Match answers 304 with empty body",
           st2 == 304 and not b2, f"status={st2} body={len(b2)}B")
    with open(os.path.join(PROJ, f"{sidX}.jsonl"), "a") as f:
        f.write(json.dumps({"type": "user", "uuid": _next_uuid(),
                            "timestamp": "2026-07-17T00:00:03Z",
                            "message": {"role": "user", "content": "grown"}}) + "\n")
    st3, h3, b3 = http_get(f"/s/{sidX}/data", {"If-None-Match": etag})
    expect("a grown file ignores the stale ETag and answers 200 fresh",
           st3 == 200 and h3.get("ETag") not in (None, etag), f"status={st3}")
    # The ETag names the RESPONSE, not the file: carrying the base URL's tag
    # to a sliced query must never buy a 304 (a false one returns an empty
    # body where filtered records belong — the gate proved it over HTTP).
    st4, h4, _ = http_get(f"/s/{sidX}/data?since=999999")
    st5, _, _ = http_get(f"/s/{sidX}/data?since=999999",
                         {"If-None-Match": h3.get("ETag") or ""})
    expect("a base-URL ETag against a sliced query answers 200, never 304",
           st4 == 200 and st5 == 200 and h4.get("ETag") != h3.get("ETag"),
           f"plain={st4} crossed={st5}")

# ---- Test 4: stale /api/sessions serves instantly, one background refresh ----
SLOW = os.path.join(ROOT, "slow-scan.sh")
with open(SLOW, "w") as f:
    f.write('#!/bin/bash\nsleep 1.2\necho \'{"live": [], "live_count": 0, "history": [], "aggregates": {}, "marker": "fresh-from-slow-scan"}\'\n')
os.chmod(SLOW, 0o755)
hub.SCAN_SCRIPT = SLOW
hub._scan_cache["data"] = {"live": [], "marker": "stale-snapshot"}
hub._scan_cache["at"] = time.time() - 60
t0 = time.time()
st, h, body = http_get("/api/sessions")
dt = time.time() - t0
# sessions_payload() whitelists fields, so content markers are observed on
# the module cache; HTTP timing is the serve-stale discriminator.
expect("stale cache answers instantly (served stale, not blocked on the scan)",
       dt < 0.4 and st == 200, f"took {dt:.2f}s status={st}")
deadline = time.time() + 5
while time.time() < deadline and hub._scan_cache["data"].get("marker") != "fresh-from-slow-scan":
    time.sleep(0.1)
expect("a background refresh lands the fresh scan shortly after",
       hub._scan_cache["data"].get("marker") == "fresh-from-slow-scan",
       f"marker={hub._scan_cache['data'].get('marker')}")

# ---- Test 5: only ONE background scan for a burst of stale hits ----
CNT = os.path.join(ROOT, "scan-count")
with open(SLOW, "w") as f:
    f.write(f'#!/bin/bash\necho x >> "{CNT}"\nsleep 0.8\necho \'{{"live": [], "live_count": 0, "history": [], "aggregates": {{}}, "marker": "burst"}}\'\n')
hub._scan_cache["data"] = {"live": [], "marker": "stale-snapshot"}
hub._scan_cache["at"] = time.time() - 60
threads = [threading.Thread(target=lambda: http_get("/api/sessions")) for _ in range(8)]
for t in threads: t.start()
for t in threads: t.join()
time.sleep(1.5)
n_scans = len(open(CNT).read().split()) if os.path.exists(CNT) else 0
expect("8 concurrent stale hits trigger exactly 1 scan", n_scans == 1, f"scans={n_scans}")

# ---- Test 6: the true-cold first request still blocks and returns fresh ----
hub._scan_cache["data"] = None
hub._scan_cache["at"] = 0.0
t0 = time.time()
st, h, body = http_get("/api/sessions")
dt = time.time() - t0
expect("cold start blocks once and returns the real scan, never a fabricated empty",
       dt >= 0.7 and hub._scan_cache["data"].get("marker") == "burst",
       f"took {dt:.2f}s cache-marker={(hub._scan_cache['data'] or {}).get('marker')}")

# ---- Test 7: a scan emitting invalid UTF-8 must not wedge the refresher —
# text=True raises UnicodeDecodeError (outside the original caught tuple),
# and a stuck single-flight flag would serve stale forever with no recovery.
with open(SLOW, "wb") as f:
    f.write(b'#!/bin/bash\necho x >> "' + CNT.encode() + b'"\nprintf "\\xff\\xfe garbage"\n')
os.chmod(SLOW, 0o755)
hub._scan_cache["data"] = {"live": [], "marker": "stale-snapshot"}
hub._scan_cache["at"] = time.time() - 60
n_before = len(open(CNT).read().split()) if os.path.exists(CNT) else 0
http_get("/api/sessions")
deadline = time.time() + 4
while time.time() < deadline and hub._scan_refreshing["on"]:
    time.sleep(0.1)
flag_cleared = not hub._scan_refreshing["on"]
hub._scan_cache["at"] = time.time() - 60
http_get("/api/sessions")
time.sleep(1.0)
n_after = len(open(CNT).read().split()) if os.path.exists(CNT) else 0
expect("a garbage-emitting scan clears the flag and later refreshes retry",
       flag_cleared and n_after >= n_before + 2
       and hub._scan_cache["data"].get("marker") == "stale-snapshot",
       f"flag_cleared={flag_cleared} scans={n_after - n_before} "
       f"marker={hub._scan_cache['data'].get('marker')}")

print()
print("SUMMARY:", "ALL PASS" if not fails else f"{len(fails)} FAILED: {fails}")
srv.shutdown()
shutil.rmtree(ROOT, ignore_errors=True)
sys.exit(1 if fails else 0)
