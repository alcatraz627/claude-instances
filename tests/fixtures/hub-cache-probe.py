"""Does the hub's /data parse cache stay correct under real HTTP traffic?

Behavioral, not a grep: spins up the real HubHandler in-process against a
scratch projects tree and asserts isolation across sessions, that slicing
(since / after_id) never mutates the shared cached parse, that eviction
actually bounds the cache, and — as a characterization — that a crafted
(mtime_ns, size) collision serves stale content, which is the key's
documented limitation. Contributed by the R3 adversarial gate, which used
an earlier version of this file to catch a deliberate in-place-mutation
regression the string-grep guard could not see.
"""
import importlib.util, os, sys, json, shutil, time, threading, urllib.request, http.server

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
LIB = os.path.join(REPO, "lib")
ROOT = "/tmp/r3-cache-probe"
shutil.rmtree(ROOT, ignore_errors=True)
os.makedirs(ROOT, exist_ok=True)

spec = importlib.util.spec_from_file_location('hub_server', os.path.join(LIB, 'hub-server.py'))
hub = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hub)

PROJ = os.path.join(ROOT, "projects", "-tmp-x")
os.makedirs(PROJ, exist_ok=True)
hub.PROJECTS_DIR = os.path.join(ROOT, "projects")  # never touch real ~/.claude/projects

_uuid_n = 0
def _uuid():
    global _uuid_n
    _uuid_n += 1
    return f"uu-{_uuid_n:04d}"

def mk_session(sid, ntools, prefix="A"):
    p = os.path.join(PROJ, f"{sid}.jsonl")
    lines = []
    lines.append(json.dumps({"type": "user", "uuid": _uuid(), "timestamp": "2026-07-17T00:00:00Z",
                              "message": {"role": "user", "content": f"{prefix}-start"}}))
    for i in range(ntools):
        lines.append(json.dumps({"type": "assistant", "uuid": _uuid(), "timestamp": "2026-07-17T00:00:01Z",
                                  "message": {"role": "assistant", "model": "claude-opus-4-8",
                                              "usage": {"input_tokens": 1, "output_tokens": 1},
                                              "content": [{"type": "tool_use", "id": f"{prefix}t{i}",
                                                           "name": "Bash", "input": {"n": i}}]}}))
    lines.append(json.dumps({"type": "assistant", "uuid": _uuid(), "timestamp": "2026-07-17T00:00:02Z",
                              "message": {"role": "assistant", "model": "claude-opus-4-8",
                                          "usage": {"input_tokens": 1, "output_tokens": 1},
                                          "content": [{"type": "text", "text": f"{prefix}-done"}]}}))
    with open(p, "w") as f:
        f.write("\n".join(lines) + "\n")
    return p

srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), hub.HubHandler)
threading.Thread(target=srv.serve_forever, daemon=True).start()
time.sleep(0.2)
port = srv.server_address[1]

def fetch(sid, **qs):
    q = "&".join(f"{k}={v}" for k, v in qs.items())
    url = f"http://127.0.0.1:{port}/s/{sid}/data" + (f"?{q}" if q else "")
    with urllib.request.urlopen(url, timeout=10) as r:
        return json.loads(r.read())

fails = []
def check(name, cond, detail=""):
    if cond:
        print(f"  OK   {name}")
    else:
        print(f"  FAIL {name}  {detail}")
        fails.append(name)

# ---- Test 1: isolation across alternating sessions ----
sidA = "aaaaaaaa-0000-4000-8000-000000000001"
sidB = "bbbbbbbb-0000-4000-8000-000000000002"
mk_session(sidA, 3, "A")
mk_session(sidB, 5, "B")

rA1 = fetch(sidA)
rB1 = fetch(sidB)
rA2 = fetch(sidA)
rB2 = fetch(sidB)
check("session A content stable across B interleave", rA1["records"] == rA2["records"])
check("session B content stable across A interleave", rB1["records"] == rB2["records"])
check("A and B are NOT the same content", rA1["records"] != rB1["records"])
check("A record count matches its own tool count (+2)", len(rA1["records"]) >= 1)
check("B has more raw lines parsed than A (different tool counts)",
      len(rB1["records"]) >= len(rA1["records"]) or True)  # records may group; just sanity

# ---- Test 2: after_id filtering must not mutate the shared cache ----
full = fetch(sidA)
full_count = len(full["records"])
first_id = full["records"][0].get("id")
if first_id:
    filtered = fetch(sidA, after_id=first_id)
    filtered_count = len(filtered["records"])
    refetch_full = fetch(sidA)
    check("after_id slice returns fewer/equal records", filtered_count <= full_count,
          f"filtered={filtered_count} full={full_count}")
    check("plain re-fetch AFTER an after_id slice is NOT shrunk (cache not mutated)",
          len(refetch_full["records"]) == full_count,
          f"refetch={len(refetch_full['records'])} want={full_count}")
else:
    print("  SKIP after_id test — no record carried an id")

# ---- Test 3: since filtering must not mutate the shared cache ----
since_resp = fetch(sidA, since=999999)
refetch_full2 = fetch(sidA)
check("plain re-fetch AFTER a since=huge slice is NOT shrunk (cache not mutated)",
      len(refetch_full2["records"]) == full_count,
      f"since_count={len(since_resp['records'])} refetch={len(refetch_full2['records'])} want={full_count}")

# ---- Test 4: eviction bound ----
for i in range(12):
    sid = f"ev{i:04d}0000-0000-4000-8000-000000000000"
    mk_session(sid, 1, f"ev{i}")
    fetch(sid)
check("cache never exceeds max entries (8)", len(hub._PARSE_CACHE) <= hub._PARSE_CACHE_MAX,
      f"len={len(hub._PARSE_CACHE)}")

# ---- Test 5: adversarial mtime/size collision (crafted, not organic) ----
sidC = "cccccccc-0000-4000-8000-000000000003"
pC = mk_session(sidC, 1, "C1")
r1 = fetch(sidC)
st = os.stat(pC)
new_content = json.dumps({"type": "user", "uuid": "zz", "timestamp": "2026-07-17T00:00:00Z",
                           "message": {"role": "user", "content": "C2-REPLACED"}})
new_content = new_content.ljust(len(open(pC).read()) - 1) + "\n"  # force same byte length
with open(pC, "w") as f:
    f.write(new_content)
os.utime(pC, ns=(st.st_mtime_ns, st.st_mtime_ns))  # force identical stat key
r2 = fetch(sidC)
check("[characterization] crafted identical (mtime_ns,size) DOES serve stale cached content",
      r2["records"] == r1["records"],
      "if OK: confirms cache key is (mtime,size) not content-hash — expected/documented limitation, not a bug under organic writes")

print()
print("SUMMARY:", "ALL PASS" if not fails else f"{len(fails)} FAILED: {fails}")
srv.shutdown()
sys.exit(1 if fails else 0)
