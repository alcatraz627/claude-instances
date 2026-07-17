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
        import subprocess, tempfile, shutil
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
        # The wiring, not the function: the five unit guards all call
        # get_aggregate_history directly, so none of them would notice the
        # assemble block quietly reverting to compute_aggregates(history).
        # This runs the WHOLE scan and asserts on the shipped JSON. HOME is
        # redirected at the temp root so the real codex tree can't pollute
        # the counts.
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
    else:
        print(f"unknown op {op!r}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
