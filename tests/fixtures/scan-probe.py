"""Exposes scan.sh's cost functions to the test suite — they live in an embedded
heredoc, so they cannot be imported. Ops: estimate | read_cost | tokens |
agg_sum | poison_scan | agg_window | agg_cache_reuse | agg_cache_corrupt |
agg_cache_shape | agg_cache_atomic."""
import io, os, sys, json, contextlib

HERE = os.path.dirname(os.path.abspath(__file__))
SCAN = os.path.join(HERE, "..", "..", "lib", "scan.sh")


def load():
    src = open(SCAN, errors="replace").read().splitlines()
    start = next(i for i, l in enumerate(src) if l.startswith("python3 - ")) + 1
    end = next(i for i, l in enumerate(src) if l.strip() == "PYEOF")
    ns = {"__name__": "scanmod"}
    sys.argv = ["scan", "/tmp/scan-probe-nonexistent", "/tmp/x", "/tmp/y", "/tmp", "1"]
    with contextlib.redirect_stdout(io.StringIO()):
        exec(compile("\n".join(src[start:end]), "scan.sh:embedded", "exec"), ns)
    return ns


def fmt(v):
    return "None" if v is None else repr(round(v, 4) if isinstance(v, float) else v)


def _load_agg(projects_dir, cache_path):
    """Exec the embedded module against a synthetic tree + a private summary
    cache (argv[6]). The real codex tree on this machine must not leak into
    the counting ops, so the provider list is trimmed to claude."""
    src = open(SCAN, errors="replace").read().splitlines()
    a = next(i for i, l in enumerate(src) if l.startswith("python3 - ")) + 1
    b = next(i for i, l in enumerate(src) if l.strip() == "PYEOF")
    ns = {"__name__": "aggmod"}
    sys.argv = ["scan", projects_dir, "/tmp/x", "/tmp/y", "/tmp/z", "1", cache_path]
    with contextlib.redirect_stdout(io.StringIO()):
        exec(compile("\n".join(src[a:b]), "scan.sh:embedded", "exec"), ns)
    ns["PROVIDERS"][:] = [p for p in ns["PROVIDERS"] if p["name"] == "claude"]
    return ns


def _mk_sessions(root, n):
    """n one-turn sessions (10 in / 5 out each) under root/projects."""
    d = os.path.join(root, "projects", "-tmp-agg")
    os.makedirs(d, exist_ok=True)
    paths = []
    for i in range(n):
        p = os.path.join(d, f"cafe{i:04d}-0000-4000-8000-000000000000.jsonl")
        with open(p, "w") as fh:
            fh.write(json.dumps({"type": "assistant", "message": {
                "model": "claude-opus-4-8",
                "usage": {"input_tokens": 10, "output_tokens": 5}}}) + "\n")
        paths.append(p)
    return paths


def _mk_ipc_stub(root, mode, payload_path=""):
    """A claude-ipc stand-in for the digest wiring tests. 'absent' behaves like
    today's real binary (help text, exit 2); 'payload' answers digest with the
    given file; 'hang' sleeps past the cap. count always answers 3, and every
    invocation's verb lands in calls.log so a probe can assert what was (not)
    spawned."""
    marker = os.path.join(root, "calls.log")
    path = os.path.join(root, "ipc-stub")
    with open(path, "w") as fh:
        fh.write(f"""#!/bin/bash
echo "$1" >> "{marker}"
case "$1" in
  digest)
    case "{mode}" in
      absent) echo "usage: claude-ipc ..."; exit 2;;
      hang)   sleep 10;;
      gchild) sleep 10 & echo $! > "{root}/gc.pid"; exit 0;;
      *)      cat "{payload_path}"; exit 0;;
    esac;;
  count) echo 3; exit 0;;
esac
exit 0
""")
    os.chmod(path, 0o755)
    return path, marker


def _mk_digest_payload(root, sids, age_s=5, cv=1, sess_over=None):
    """A digest response derived from the VENDORED contract fixture (so the
    probes and the contract can't silently drift apart), re-stamped to age_s
    and carrying one session block per sid."""
    from datetime import datetime, timezone, timedelta
    with open(os.path.join(HERE, "ipc-digest-fixture.json")) as fh:
        fx = json.load(fh)
    base = dict(next(v for k, v in fx["sessions"].items() if k != "_unresolved"))
    base.update(sess_over or {})
    ts = (datetime.now(timezone.utc) - timedelta(seconds=age_s)).strftime(
        '%Y-%m-%dT%H:%M:%S.000Z')
    payload = {"protocol_version": "x", "contract_version": cv, "ts": ts,
               "sessions": {**{sid: dict(base) for sid in sids},
                            "_unresolved": {"aliases": [], "note": ""}}}
    p = os.path.join(root, f"payload-{age_s}-{cv}.json")
    with open(p, "w") as fh:
        json.dump(payload, fh)
    return p


def _ipc_env(root, sid, ns2, stub):
    """Point the loaded module at a scratch alias dir + the stub binary."""
    adir = os.path.join(root, "aliases")
    os.makedirs(adir, exist_ok=True)
    with open(os.path.join(adir, sid), "w") as fh:
        fh.write("test-alias")
    ns2["_IPC_ALIAS_DIR"] = adir
    ns2["_IPC_BIN"] = stub


def main(argv):
    ns = load()
    op = argv[0]
    if op == "estimate":
        # float(), not int() — a corrupt transcript can carry inf/nan through
        # json.loads, and those are exactly the cases worth asserting on.
        model, ti, to = argv[1], float(argv[2]), float(argv[3])
        print(fmt(ns["estimate_cost"](model, ti, to)))
    elif op == "read_cost":
        print(fmt(ns["read_cost"](int(argv[1]))))
    elif op == "turns_big":
        # A transcript is mostly enormous tool_result lines, so reading only the
        # tail used to report a handful of turns as the whole session's total.
        # Build a file well past the old 500KB window and demand an exact count.
        import tempfile, shutil
        n = int(argv[1])
        root = tempfile.mkdtemp(prefix="turns-")
        try:
            d = os.path.join(root, "projects", "-tmp-t")
            os.makedirs(d)
            sid = "bbbbbbbb-0000-0000-0000-00000000000b"
            pad = "x" * 20_000          # a fat tool_result, like the real thing
            with open(os.path.join(d, f"{sid}.jsonl"), "w") as fh:
                for i in range(n):
                    fh.write(json.dumps({"type": "user", "message": {
                        "role": "user", "content": pad}}) + "\n")
                    fh.write(json.dumps({"type": "assistant", "message": {
                        "model": "claude-opus-4-8",
                        "usage": {"input_tokens": 1, "output_tokens": 1},
                        "content": [{"type": "tool_use", "name": "Bash"}]}}) + "\n")
            size = os.path.getsize(os.path.join(d, f"{sid}.jsonl"))
            ns2 = {"__name__": "m"}
            src = open(SCAN, errors="replace").read().splitlines()
            a = next(i for i, l in enumerate(src) if l.startswith("python3 - ")) + 1
            b = next(i for i, l in enumerate(src) if l.strip() == "PYEOF")
            sys.argv = ["scan", os.path.join(root, "projects"), "/tmp/x", "/tmp/y",
                        os.path.join(root, "sl"), "1"]
            with contextlib.redirect_stdout(io.StringIO()):
                exec(compile("\n".join(src[a:b]), "scan", "exec"), ns2)
            r = ns2["get_session_tokens"](999999, "/tmp/t", prefer_sid=sid)
            print(f"{r['turns']}:{r['tool_calls']}:{size > 500_000}")
        finally:
            shutil.rmtree(root, ignore_errors=True)
    elif op == "history_session":
        # claude_parse_session used to count EVERY line as a turn and take its
        # tokens from the last line alone — which is nearly always a
        # tool_result, so a session that spent real tokens reported zero.
        import tempfile, shutil
        n = int(argv[1])
        root = tempfile.mkdtemp(prefix="hist-")
        try:
            f = os.path.join(root, "s.jsonl")
            with open(f, "w") as fh:
                for i in range(n):
                    fh.write(json.dumps({"type": "assistant", "message": {
                        "model": "claude-opus-4-8",
                        "usage": {"input_tokens": 10, "output_tokens": 5}}}) + "\n")
                    # the noise a real transcript is mostly made of
                    fh.write(json.dumps({"type": "user", "message": {
                        "role": "user", "content": "x" * 200}}) + "\n")
                # end on a tool_result, like a real session does
                fh.write(json.dumps({"type": "user", "message": {
                    "role": "user", "content": [{"type": "tool_result", "content": "done"}]}}) + "\n")
            ns2 = load()
            r = ns2["claude_parse_session"](f)
            print(f"{r['turns']}:{r['tokens_in']}:{r['tokens_out']}")
        finally:
            shutil.rmtree(root, ignore_errors=True)
    elif op == "tail":
        print(len(load()["tail_lines"](argv[1], int(argv[2]))))
    elif op == "read_pid_file":
        print(load()["read_pid_file"](int(argv[1]), argv[2]).strip())
    elif op == "local_day":
        # TZ is set by the caller, so this asserts the same way in any zone
        # rather than only passing where it was written.
        print(load()["local_day"](argv[1]))
    elif op == "buckets":
        # A session at 01:00 local belongs to today, even though UTC still says
        # yesterday. Drive compute_aggregates with a synthetic history row.
        from datetime import datetime, timedelta, timezone
        ns2 = load()
        now_loc = datetime.now().astimezone()
        # 01:00 local today -> whatever UTC that is
        one_am = now_loc.replace(hour=1, minute=0, second=0, microsecond=0)
        iso = one_am.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        agg = ns2["compute_aggregates"]([{
            "modified": iso, "model": "opus", "turns": 1,
            "tokens_in": 10, "tokens_out": 5, "cost_usd": 1.0}])
        print(f"{agg['today']['sessions']}:{agg['week']['sessions']}")
    elif op == "tokens":
        print(fmt(ns["token_count"](json.loads(argv[1]))))
    elif op == "poison_scan":
        # The whole scan against a poisoned transcript. The unit guards passed
        # while the scan still emitted a bare Infinity through tokens_in, so
        # this asserts on the real output, not on one function.
        # HUB_IPC_DIGEST=0: this exec runs under the REAL home, and a live
        # digest verb would let the disagreement pass write real ledger lines.
        import subprocess, tempfile, shutil
        os.environ["HUB_IPC_DIGEST"] = "0"
        root = tempfile.mkdtemp(prefix="poison-")
        try:
            d = os.path.join(root, "projects", "-tmp-p")
            os.makedirs(d)
            with open(os.path.join(d, "p-0000-0000-0000-000000000001.jsonl"), "w") as fh:
                fh.write('{"type":"assistant","message":{"model":"claude-opus-4-8",'
                         '"usage":{"input_tokens":Infinity,"output_tokens":NaN}}}\n')
            ns2 = load()
            import io as _io, contextlib as _c
            sys.argv = ["scan", os.path.join(root, "projects"), "/tmp/x", "/tmp/y", "/tmp/z", "0"]
            buf = _io.StringIO()
            src = open(SCAN, errors="replace").read().splitlines()
            a = next(i for i, l in enumerate(src) if l.startswith("python3 - ")) + 1
            b = next(i for i, l in enumerate(src) if l.strip() == "PYEOF")
            with _c.redirect_stdout(buf):
                exec(compile("\n".join(src[a:b]), "scan", "exec"), {"__name__": "m"})
            raw = buf.getvalue()
            try:
                json.loads(raw, parse_constant=lambda c: (_ for _ in ()).throw(ValueError(c)))
                print("STRICT_JSON_OK")
            except ValueError as ex:
                print(f"POISONED:{ex}")
        finally:
            del os.environ["HUB_IPC_DIGEST"]
            shutil.rmtree(root, ignore_errors=True)
    elif op == "agg_sum":
        # The aggregates sum must survive an unpriced (None) session.
        sessions = [{"cost_usd": c} for c in json.loads(argv[1])]
        try:
            print(fmt(round(sum(s.get("cost_usd") or 0 for s in sessions), 4)))
        except TypeError as e:
            print(f"ERROR:{type(e).__name__}")
    elif op == "agg_window":
        # THE R1 assertion: the display list caps at 20 rows; the aggregates
        # must still see every session in the window.
        import tempfile, shutil
        n = int(argv[1])
        root = tempfile.mkdtemp(prefix="aggwin-")
        try:
            _mk_sessions(root, n)
            ns2 = _load_agg(os.path.join(root, "projects"),
                            os.path.join(root, "cache", "s.json"))
            agg = ns2["get_aggregate_history"]()
            hist = ns2["get_session_history"]()
            a = ns2["compute_aggregates"](agg)
            print(f"{len(agg)}:{len(hist)}:{a['today']['sessions']}:{a['today']['tokens_out']}")
        finally:
            shutil.rmtree(root, ignore_errors=True)
    elif op == "agg_e2e":
        # Asserts the real shipped JSON end-to-end (unlike the unit guards,
        # which call the function directly), HOME-redirected so the real
        # codex tree can't pollute the counts.
        import tempfile, shutil
        n = int(argv[1])
        root = tempfile.mkdtemp(prefix="agge2e-")
        old_home = os.environ.get("HOME")
        try:
            _mk_sessions(root, n)
            os.environ["HOME"] = root
            src = open(SCAN, errors="replace").read().splitlines()
            a = next(i for i, l in enumerate(src) if l.startswith("python3 - ")) + 1
            b = next(i for i, l in enumerate(src) if l.strip() == "PYEOF")
            sys.argv = ["scan", os.path.join(root, "projects"), "/tmp/x", "/tmp/y",
                        "/tmp/z", "0", os.path.join(root, "cache", "s.json")]
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                exec(compile("\n".join(src[a:b]), "scan.sh:embedded", "exec"),
                     {"__name__": "e2emod"})
            out = json.loads(buf.getvalue())
            print(f"{out['aggregates']['today']['sessions']}:{len(out['history'])}")
        finally:
            if old_home is not None:
                os.environ["HOME"] = old_home
            shutil.rmtree(root, ignore_errors=True)
    elif op == "agg_sessions_only":
        # Sub-agent transcripts (<sid>/subagents/**.jsonl) live inside a
        # session's directory tree but are workers, not sessions. Recursing
        # into them counted 379 alongside a week's 265 real sessions, and
        # double-counted their tokens on top.
        import tempfile, shutil
        root = tempfile.mkdtemp(prefix="aggnest-")
        try:
            _mk_sessions(root, 3)
            d = os.path.join(root, "projects", "-tmp-agg",
                             "cafe0000-0000-4000-8000-000000000000", "subagents")
            os.makedirs(d)
            for i in range(2):
                with open(os.path.join(d, f"agent-x{i}.jsonl"), "w") as fh:
                    fh.write(json.dumps({"type": "assistant", "message": {
                        "model": "claude-opus-4-8",
                        "usage": {"input_tokens": 100, "output_tokens": 100}}}) + "\n")
            ns2 = _load_agg(os.path.join(root, "projects"),
                            os.path.join(root, "cache", "s.json"))
            agg = ns2["get_aggregate_history"]()
            hist = ns2["get_session_history"]()
            a = ns2["compute_aggregates"](agg)
            print(f"{len(agg)}:{len(hist)}:{a['today']['tokens_out']}")
        finally:
            shutil.rmtree(root, ignore_errors=True)
    elif op == "agg_models_today":
        # The bar renders model_breakdown on the row labeled "Today"
        # (native/Bar.swift), so it must count today's sessions — with the
        # full-window walk feeding it, an unfiltered count silently became
        # "the week's model mix" wearing a Today label.
        import tempfile, shutil, time
        root = tempfile.mkdtemp(prefix="aggmod-")
        try:
            _mk_sessions(root, 2)
            d = os.path.join(root, "projects", "-tmp-agg")
            old = os.path.join(d, "beef0000-0000-4000-8000-000000000000.jsonl")
            with open(old, "w") as fh:
                fh.write(json.dumps({"type": "assistant", "message": {
                    "model": "claude-sonnet-5",
                    "usage": {"input_tokens": 10, "output_tokens": 5}}}) + "\n")
            two_days = time.time() - 2 * 86400
            os.utime(old, (two_days, two_days))
            ns2 = _load_agg(os.path.join(root, "projects"),
                            os.path.join(root, "cache", "s.json"))
            a = ns2["compute_aggregates"](ns2["get_aggregate_history"]())
            print(f"{a['today']['sessions']}:{a['week']['sessions']}:"
                  f"{json.dumps(a['model_breakdown'], sort_keys=True)}")
        finally:
            shutil.rmtree(root, ignore_errors=True)
    elif op == "agg_cache_reuse":
        # Unchanged files must come from the cache, and only the file that
        # grew may re-parse.
        import tempfile, shutil
        n = int(argv[1])
        root = tempfile.mkdtemp(prefix="aggreuse-")
        try:
            paths = _mk_sessions(root, n)
            ns2 = _load_agg(os.path.join(root, "projects"),
                            os.path.join(root, "cache", "s.json"))
            calls = {"n": 0}
            real = ns2["PROVIDERS"][0]["parse_session"]
            def counting(fp):
                calls["n"] += 1
                return real(fp)
            ns2["PROVIDERS"][0]["parse_session"] = counting
            ns2["get_aggregate_history"](); c1 = calls["n"]; calls["n"] = 0
            ns2["get_aggregate_history"](); c2 = calls["n"]; calls["n"] = 0
            with open(paths[0], "a") as fh:
                fh.write(json.dumps({"type": "assistant", "message": {
                    "model": "claude-opus-4-8",
                    "usage": {"input_tokens": 1, "output_tokens": 1}}}) + "\n")
            rows = ns2["get_aggregate_history"](); c3 = calls["n"]
            print(f"{c1}:{c2}:{c3}:{len(rows)}")
        finally:
            shutil.rmtree(root, ignore_errors=True)
    elif op == "agg_cache_corrupt":
        # A damaged cache means a rebuild — never a crash, never a fabricated
        # summary — and the scan leaves a valid file behind.
        import tempfile, shutil
        n = int(argv[1])
        root = tempfile.mkdtemp(prefix="aggcor-")
        try:
            _mk_sessions(root, n)
            cache = os.path.join(root, "cache", "s.json")
            os.makedirs(os.path.dirname(cache))
            with open(cache, "w") as fh:
                fh.write('{"broken')
            ns2 = _load_agg(os.path.join(root, "projects"), cache)
            rows = ns2["get_aggregate_history"]()
            with open(cache) as fh:
                json.load(fh)
            print(f"{len(rows)}:REPAIRED")
        finally:
            shutil.rmtree(root, ignore_errors=True)
    elif op == "agg_cache_shape":
        # Valid JSON, hostile shapes: a matching (mtime,size) key with a
        # garbage summary must re-parse — never crash, never enter the totals.
        # A cached path that no longer exists must be pruned by the rewrite.
        import tempfile, shutil
        n = int(argv[1])
        root = tempfile.mkdtemp(prefix="aggshape-")
        try:
            paths = _mk_sessions(root, n)
            cache = os.path.join(root, "cache", "s.json")
            os.makedirs(os.path.dirname(cache))
            st0, st2 = os.stat(paths[0]), os.stat(paths[2])
            with open(cache, "w") as fh:
                json.dump({
                    paths[0]: {"mtime_ns": st0.st_mtime_ns, "size": st0.st_size,
                               "summary": {"model": 5, "turns": "ten",
                                           "tokens_in": None, "tokens_out": []}},
                    paths[1]: ["not", "a", "dict"],
                    # Type-valid, range-invalid: negative and absurd ints are
                    # exactly what isinstance() alone would wave through.
                    paths[2]: {"mtime_ns": st2.st_mtime_ns, "size": st2.st_size,
                               "summary": {"model": "opus", "turns": 1,
                                           "tokens_in": -999999,
                                           "tokens_out": 10**300}},
                    "/nonexistent/x.jsonl": {"mtime_ns": 1, "size": 1,
                                             "summary": {"model": "opus", "turns": 1,
                                                         "tokens_in": 1, "tokens_out": 1}},
                }, fh)
            ns2 = _load_agg(os.path.join(root, "projects"), cache)
            rows = ns2["get_aggregate_history"]()
            a = ns2["compute_aggregates"](rows)
            with open(cache) as fh:
                saved = json.load(fh)
            pruned = "PRUNED" if "/nonexistent/x.jsonl" not in saved else "STALE"
            print(f"{len(rows)}:{a['today']['tokens_out']}:{pruned}")
        finally:
            shutil.rmtree(root, ignore_errors=True)
    elif op == "agg_cache_atomic":
        # save must be tmp+rename: a dump that dies mid-write leaves the
        # previous cache byte-identical and no tmp litter behind.
        import tempfile, shutil
        n = int(argv[1])
        root = tempfile.mkdtemp(prefix="aggatom-")
        try:
            _mk_sessions(root, n)
            cache = os.path.join(root, "cache", "s.json")
            ns2 = _load_agg(os.path.join(root, "projects"), cache)
            ns2["get_aggregate_history"]()
            with open(cache, "rb") as fh:
                before = fh.read()
            real_json = ns2["json"]
            class Poison:
                def __getattr__(self, k):
                    return getattr(real_json, k)
                @staticmethod
                def dump(obj, fh):
                    fh.write('{"torn')
                    raise OSError("disk full")
            ns2["json"] = Poison()
            ns2["save_summary_cache"]({"x": 1})
            ns2["json"] = real_json
            with open(cache, "rb") as fh:
                after = fh.read()
            litter = [f for f in os.listdir(os.path.dirname(cache)) if ".tmp." in f]
            print(("ATOMIC" if before == after else "TORN")
                  + ":" + ("CLEAN" if not litter else "LITTER"))
        finally:
            shutil.rmtree(root, ignore_errors=True)
    elif op == "ipc_state_field":
        # Broker silence must be UNKNOWN, never 0: a dead broker and an empty
        # inbox are different facts (meld PH1, the unknown-not-zero doctrine
        # applied to the live join).
        import tempfile, shutil
        root = tempfile.mkdtemp(prefix="ipcstate-")
        try:
            sid = "cafe0000-0000-4000-8000-00000000cafe"
            with open(os.path.join(root, sid), "w") as fh:
                fh.write("test-alias")
            ns2 = load()
            ns2["_IPC_ALIAS_DIR"] = root
            ns2["_IPC_BIN"] = "/usr/bin/false"   # exists; broker never answers
            a = ns2["get_ipc_info"](sid, False)
            ns2["_IPC_BIN"] = "/bin/echo"        # answers with no digits: empty inbox
            b = ns2["get_ipc_info"](sid, False)
            print(f"{a.get('inbox')}:{a.get('state')}:{b.get('inbox')}:{b.get('state')}")
        finally:
            shutil.rmtree(root, ignore_errors=True)
    elif op == "ipc_state_kill":
        # HUB_IPC_OVERLAY=0 restores the legacy shape exactly: silent zero,
        # no state key — the Phase-1 kill switch is a real revert.
        import tempfile, shutil
        os.environ['HUB_IPC_OVERLAY'] = '0'
        root = tempfile.mkdtemp(prefix="ipckill-")
        try:
            sid = "cafe0000-0000-4000-8000-00000000cafe"
            with open(os.path.join(root, sid), "w") as fh:
                fh.write("test-alias")
            ns2 = load()
            ns2["_IPC_ALIAS_DIR"] = root
            ns2["_IPC_BIN"] = "/usr/bin/false"
            a = ns2["get_ipc_info"](sid, False)
            print(f"{a.get('inbox')}:{'ABSENT' if 'state' not in a else a.get('state')}")
        finally:
            del os.environ['HUB_IPC_OVERLAY']
            shutil.rmtree(root, ignore_errors=True)
    elif op == "digest_states":
        # The bridge staleness state machine (meld plan v2 section 7): a
        # digest payload is classified before any value is trusted. Unknown
        # must never read as 0, and a version we don't speak is SKEW, a
        # distinct state from unreachable/unknown.
        import json as _j
        from datetime import datetime, timezone, timedelta
        ns2 = load()
        f = ns2["parse_ipc_digest"]
        now = datetime.now(timezone.utc)
        def payload(age_s, cv=1, sessions=None, raw=None):
            if raw is not None:
                return raw
            ts = (now - timedelta(seconds=age_s)).strftime('%Y-%m-%dT%H:%M:%S.000Z')
            return _j.dumps({"protocol_version": "x", "contract_version": cv,
                             "ts": ts,
                             "sessions": sessions if sessions is not None
                             else {"sid-1": {"unread": 2, "owed": []}}})
        cases = [
            f(payload(5))[0],                       # fresh
            f(payload(60))[0],                      # stale (values still usable)
            f(payload(200))[0],                     # unknown (too old)
            f(payload(-120))[0],                    # unknown (future clock skew)
            f(payload(5, cv=99))[0],                # skew
            f(payload(5, cv=0))[0],                 # fresh via N-1 tolerance
            f('{"broken')[0],                       # unknown (malformed)
            f(payload(0, raw='{"contract_version":1,"ts":"2026-01-01T00:00:00Z","sessions":{"s":{"unread":Infinity}}}'))[0],  # unknown (poison constant)
            f(payload(5, sessions=[]))[0],          # unknown (wrong shape)
        ]
        # The mutation half of the staleness guard: a FRESH payload must carry
        # its sessions through, or "always unknown" would pass the state list.
        st, sess = f(payload(5))
        carried = "CARRIED" if sess.get("sid-1", {}).get("unread") == 2 else "DROPPED"
        print(":".join(cases) + ":" + carried)
    elif op == "digest_additive":
        # Additive direction 1 on today's code: with the ipc binary absent the
        # join must return quietly (alias '', count 0) — never raise, never
        # stall. This is the property every later bridge phase must preserve.
        ns2 = load()
        ns2["_IPC_BIN"] = "/nonexistent/claude-ipc-gone"
        try:
            info = ns2["get_ipc_info"]("00000000-0000-4000-8000-000000000000", False)
            print("ABSENT_OK" if isinstance(info, dict) or info is None else f"ODD:{type(info).__name__}")
        except Exception as e:
            print(f"RAISED:{type(e).__name__}")
    elif op == "codex_none":
        # codex rollouts carry no usage keys at all: unknown must read as
        # None, never as "used nothing" — and the aggregate sums must
        # tolerate the None without crashing or fabricating.
        import tempfile, shutil
        from datetime import datetime, timezone
        root = tempfile.mkdtemp(prefix="cxnone-")
        try:
            f = os.path.join(root, "rollout-1.jsonl")
            with open(f, "w") as fh:
                fh.write(json.dumps({"type": "session_meta", "payload": {
                    "session_id": "cx1", "cwd": "/tmp/x",
                    "model_provider": "openai", "cli_version": "1.0"}}) + "\n")
                fh.write(json.dumps({"type": "response_item", "payload": {
                    "type": "message", "role": "assistant"}}) + "\n")
            ns2 = load()
            r = ns2["codex_parse_session"](f)
            row = {"modified": datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
                   "model": "openai/1.0", "turns": r["turns"],
                   "tokens_in": r["tokens_in"], "tokens_out": r["tokens_out"],
                   "cost_usd": None}
            a = ns2["compute_aggregates"]([row])
            print(f"{r['tokens_in']}:{r['tokens_out']}:{r['turns']}:"
                  f"{a['today']['tokens_out']}:{a['today']['sessions']}")
        finally:
            shutil.rmtree(root, ignore_errors=True)
    elif op == "tpath_stale":
        # PID reuse leaves the previous owner's tpath file behind; a pointer
        # file older than the process itself cannot belong to it.
        import tempfile, shutil, time as _t
        pid = 999888
        root = tempfile.mkdtemp(prefix="tpstale-")
        tp = f"/tmp/claude-tpath-{pid}"
        try:
            target = os.path.join(root, "s.jsonl")
            with open(target, "w") as fh:
                fh.write("{}\n")
            with open(tp, "w") as fh:
                fh.write(target)
            ns2 = load()
            ns2["_proc_elapsed"][str(pid)] = "00:10"
            fresh = ns2["read_transcript_path"](pid)
            old = _t.time() - 3600
            os.utime(tp, (old, old))
            stale = ns2["read_transcript_path"](pid)
            print(f"{'OK' if fresh == target else 'FRESH_LOST'}:"
                  f"{'STALE_IGNORED' if stale == '' else 'STALE_TRUSTED'}")
        finally:
            try:
                os.unlink(tp)
            except OSError:
                pass
            shutil.rmtree(root, ignore_errors=True)
    elif op == "digest_dark":
        # The dark launch itself: the real binary today answers `digest` with
        # help + exit 2. That must leave the card in EXACTLY the legacy
        # count-path shape (no digest keys) — while proving the digest was
        # attempted, so the feature lights up the day the peer ships the verb.
        import tempfile, shutil
        root = tempfile.mkdtemp(prefix="ipcdark-")
        try:
            sid = "cafe0000-0000-4000-8000-00000000cafe"
            stub, marker = _mk_ipc_stub(root, "absent")
            ns2 = load()
            _ipc_env(root, sid, ns2, stub)
            out = ns2["get_ipc_info"](sid, False, "/tmp/dcwd")
            calls = open(marker).read().split() if os.path.exists(marker) else []
            shape = "PH1SHAPE" if set(out) == {"alias", "inbox", "state"} else f"KEYS:{sorted(out)}"
            print(f"{out.get('inbox')}:{out.get('state')}:{shape}:"
                  f"{'TRIED' if 'digest' in calls else 'NEVER'}")
        finally:
            shutil.rmtree(root, ignore_errors=True)
    elif op == "digest_live":
        # A fresh digest response sources the card: unread → inbox, owed
        # entries with a real ask_state → the obligations fields, and the
        # per-alias count subprocess is NOT spawned — the digest replaces it.
        import tempfile, shutil
        root = tempfile.mkdtemp(prefix="ipclive-")
        try:
            sid = "cafe0000-0000-4000-8000-00000000cafe"
            payload = _mk_digest_payload(root, [sid], age_s=5, sess_over={
                "unread": 2, "waiting_on": 1, "oldest_deadline_s": 300,
                "liveness_claim": "live",
                "owed": [{"corr_id": "m1", "kind": "query", "age_s": 1200,
                          "reply_by_s": 300, "ask_state": "open"},
                         {"corr_id": "m2", "kind": "query", "age_s": 5,
                          "reply_by_s": 0, "ask_state": "responded"}]})
            stub, marker = _mk_ipc_stub(root, "payload", payload)
            ns2 = load()
            _ipc_env(root, sid, ns2, stub)
            out = ns2["get_ipc_info"](sid, False, "/tmp/dcwd")
            calls = open(marker).read().split() if os.path.exists(marker) else []
            print(f"{out.get('source')}:{out.get('state')}:{out.get('inbox')}:"
                  f"{out.get('owes')}:{out.get('oldest_owed_age_s')}:"
                  f"{out.get('deadline_s')}:{out.get('waiting_on')}:"
                  f"{'NOCOUNT' if 'count' not in calls else 'COUNTED'}")
        finally:
            shutil.rmtree(root, ignore_errors=True)
    elif op == "digest_wire_states":
        # Stale carries dimmed values plus its age (the state machine of plan
        # section 7 governs; parse_ipc_digest has always returned sessions for
        # stale); skew and unknown carry nothing but the state.
        import tempfile, shutil
        root = tempfile.mkdtemp(prefix="ipcwire-")
        try:
            sid = "cafe0000-0000-4000-8000-00000000cafe"
            ns2 = load()
            results = []
            for age, cv in ((60, 1), (5, 99), (300, 1)):
                payload = _mk_digest_payload(root, [sid], age_s=age, cv=cv,
                                             sess_over={"unread": 2})
                stub, _ = _mk_ipc_stub(root, "payload", payload)
                _ipc_env(root, sid, ns2, stub)
                ns2["_ipc_digest_cache"].clear()
                out = ns2["get_ipc_info"](sid, False, "/tmp/dcwd")
                results.append(out)
            a, b, c = results
            hasage = "HASAGE" if isinstance(a.get("age_s"), int) and 40 <= a["age_s"] <= 100 else f"AGE:{a.get('age_s')}"
            print(f"{a.get('state')}:{a.get('inbox')}:{hasage}:"
                  f"{b.get('state')}:{b.get('inbox')}:"
                  f"{c.get('state')}:{c.get('inbox')}")
        finally:
            shutil.rmtree(root, ignore_errors=True)
    elif op == "digest_kill":
        # HUB_IPC_DIGEST=0 keeps the RETIRED count path alive (reversible
        # retirement): count sourcing, and the digest is never even spawned.
        import tempfile, shutil
        os.environ["HUB_IPC_DIGEST"] = "0"
        root = tempfile.mkdtemp(prefix="ipckill2-")
        try:
            sid = "cafe0000-0000-4000-8000-00000000cafe"
            payload = _mk_digest_payload(root, [sid], sess_over={"unread": 9})
            stub, marker = _mk_ipc_stub(root, "payload", payload)
            ns2 = load()
            _ipc_env(root, sid, ns2, stub)
            out = ns2["get_ipc_info"](sid, False, "/tmp/dcwd")
            calls = open(marker).read().split() if os.path.exists(marker) else []
            print(f"{out.get('inbox')}:{out.get('state')}:"
                  f"{'NODIGEST' if 'digest' not in calls else 'SPAWNED'}")
        finally:
            del os.environ["HUB_IPC_DIGEST"]
            shutil.rmtree(root, ignore_errors=True)
    elif op == "digest_overlay_kill":
        # HUB_IPC_OVERLAY=0 is the outer kill switch and outranks the digest
        # path: full legacy shape (silent zero, no state key), no digest spawn.
        import tempfile, shutil
        os.environ["HUB_IPC_OVERLAY"] = "0"
        root = tempfile.mkdtemp(prefix="ipcokill-")
        try:
            sid = "cafe0000-0000-4000-8000-00000000cafe"
            payload = _mk_digest_payload(root, [sid], sess_over={"unread": 9})
            stub, marker = _mk_ipc_stub(root, "payload", payload)
            ns2 = load()
            _ipc_env(root, sid, ns2, stub)
            out = ns2["get_ipc_info"](sid, False, "/tmp/dcwd")
            calls = open(marker).read().split() if os.path.exists(marker) else []
            print(f"{out.get('inbox')}:{'ABSENT' if 'state' not in out else out.get('state')}:"
                  f"{'NODIGEST' if 'digest' not in calls else 'SPAWNED'}")
        finally:
            del os.environ["HUB_IPC_OVERLAY"]
            shutil.rmtree(root, ignore_errors=True)
    elif op == "digest_hang":
        # A hanging broker must cost the scan the 2s cap ONCE — process-group
        # killed (a node tree survives a child-only kill), rendered as
        # 'unreachable', and never followed by a count attempt on top.
        import tempfile, shutil, time as _t
        root = tempfile.mkdtemp(prefix="ipchang-")
        try:
            sid = "cafe0000-0000-4000-8000-00000000cafe"
            stub, marker = _mk_ipc_stub(root, "hang")
            ns2 = load()
            _ipc_env(root, sid, ns2, stub)
            t0 = _t.time()
            out = ns2["get_ipc_info"](sid, False, "/tmp/dcwd")
            dt = _t.time() - t0
            calls = open(marker).read().split() if os.path.exists(marker) else []
            print(f"{out.get('state')}:{out.get('inbox')}:"
                  f"{'NOCOUNT' if 'count' not in calls else 'COUNTED'}:"
                  f"{'FAST' if dt < 4.0 else f'SLOW:{dt:.1f}'}")
        finally:
            shutil.rmtree(root, ignore_errors=True)
    elif op == "digest_grandchild":
        # The nastier hang: the direct child exits fast but leaves a
        # backgrounded grandchild holding the stdout pipe — by kill time the
        # child is a zombie, so a getpgid-at-kill-time approach never sends
        # the killpg and orphans the grandchild (gate finding, 2026-07-20).
        # The cap must still hold AND the whole process group must die.
        import tempfile, shutil, time as _t, signal as _sig
        root = tempfile.mkdtemp(prefix="ipcgc-")
        try:
            sid = "cafe0000-0000-4000-8000-00000000cafe"
            stub, marker = _mk_ipc_stub(root, "gchild")
            ns2 = load()
            _ipc_env(root, sid, ns2, stub)
            t0 = _t.time()
            out = ns2["get_ipc_info"](sid, False, "/tmp/dcwd")
            dt = _t.time() - t0
            _t.sleep(0.3)
            gc_alive = False
            gcpid = None
            try:
                gcpid = int(open(os.path.join(root, "gc.pid")).read().strip())
                os.kill(gcpid, 0)
                gc_alive = True
            except (OSError, ValueError):
                pass
            if gc_alive and gcpid:
                try:
                    os.kill(gcpid, _sig.SIGKILL)
                except OSError:
                    pass
            print(f"{out.get('state')}:{'GC_DEAD' if not gc_alive else 'GC_ALIVE'}:"
                  f"{'FAST' if dt < 2.8 else f'SLOW:{dt:.1f}'}")
        finally:
            shutil.rmtree(root, ignore_errors=True)
    elif op == "digest_one_spawn":
        # One digest spawn covers every session in a cwd — that's the
        # subprocess economy the digest buys over N per-alias counts.
        import tempfile, shutil
        root = tempfile.mkdtemp(prefix="ipcone-")
        try:
            sa = "cafe0000-0000-4000-8000-00000000cafa"
            sb = "cafe0000-0000-4000-8000-00000000cafb"
            payload = _mk_digest_payload(root, [sa, sb], sess_over={"unread": 1})
            stub, marker = _mk_ipc_stub(root, "payload", payload)
            ns2 = load()
            _ipc_env(root, sa, ns2, stub)
            with open(os.path.join(ns2["_IPC_ALIAS_DIR"], sb), "w") as fh:
                fh.write("test-alias-b")
            a = ns2["get_ipc_info"](sa, False, "/tmp/dcwd")
            b = ns2["get_ipc_info"](sb, False, "/tmp/dcwd")
            calls = open(marker).read().split() if os.path.exists(marker) else []
            print(f"{calls.count('digest')}:{a.get('source')}:{b.get('source')}")
        finally:
            shutil.rmtree(root, ignore_errors=True)
    elif op == "disagree_pass":
        # Section 8.4: pid-truth vs liveness claim. Raw lines always (offline-
        # while-live, live-while-gone, live-but-unregistered); agreement stays
        # silent (the mutation half); the card flag needs 2 consecutive scans;
        # and the card's own session_state is never touched — the digest's
        # opinion of liveness must not leak into the physical column.
        import tempfile, shutil
        root = tempfile.mkdtemp(prefix="ipcdis-")
        try:
            sa = "cafe0000-0000-4000-8000-0000000000aa"   # live, ipc says offline
            sb = "cafe0000-0000-4000-8000-0000000000bb"   # live, ipc agrees
            sc = "cafe0000-0000-4000-8000-0000000000cc"   # live, missing from digest
            gone = "cafe0000-0000-4000-8000-0000000000dd" # ipc says live, no pid
            ns2 = load()
            log = os.path.join(root, "raw.jsonl")
            state = os.path.join(root, "state.json")
            ns2["_IPC_DISAGREE_LOG"] = log
            ns2["_IPC_DISAGREE_STATE"] = state

            def mk_live():
                rows = []
                for sid in (sa, sb, sc):
                    rows.append({"session_id": sid, "cwd": "/tmp/dcwd",
                                 "provider": "claude", "session_state": "working",
                                 "ipc": {"alias": "x-" + sid[-2:],
                                         "source": "digest", "state": "fresh"}})
                return rows

            ns2["_ipc_digest_cache"]["/tmp/dcwd"] = ("fresh", {
                sa: {"liveness_claim": "offline"},
                sb: {"liveness_claim": "live"},
                gone: {"liveness_claim": "live"},
                "_unresolved": {"aliases": []},
            }, 2)
            live1 = mk_live()
            ns2["run_ipc_disagreement_pass"](live1)
            n_raw = sum(1 for _ in open(log)) if os.path.exists(log) else 0
            flag1 = "FLAG1" if any("disagree" in (r.get("ipc") or {}) for r in live1) else "NOFLAG"
            live2 = mk_live()
            ns2["run_ipc_disagreement_pass"](live2)
            fa = next(r for r in live2 if r["session_id"] == sa)
            fb = next(r for r in live2 if r["session_id"] == sb)
            flag2 = ("FLAG" + str(fa["ipc"].get("disagree", {}).get("scans"))
                     if "disagree" in fa["ipc"] else "NOFLAG2")
            clean = "SSTATE_OK" if (fa["session_state"] == "working"
                                    and "disagree" not in fb["ipc"]) else "LEAKED"
            # A poisoned state file must not buy a first-scan flag: JSON true
            # passes a bare isinstance(int) check (bool is an int in Python)
            # and true+1 == 2 — the gate proved that skips the debounce.
            poison_ok = []
            for bad in (True, 10**20):
                with open(state, "w") as fh:
                    json.dump({sa: {"streak": bad}}, fh)
                lp = mk_live()
                ns2["run_ipc_disagreement_pass"](lp)
                pa = next(r for r in lp if r["session_id"] == sa)
                poison_ok.append("disagree" not in pa["ipc"])
            poison = "POISON_OK" if all(poison_ok) else "POISON_BYPASS"
            print(f"{n_raw}:{flag1}:{flag2}:{clean}:{poison}")
        finally:
            shutil.rmtree(root, ignore_errors=True)
    else:
        print(f"unknown op {op!r}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
