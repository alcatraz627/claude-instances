"""Exposes scan.sh's cost functions to the test suite — they live in an embedded
heredoc, so they cannot be imported. Ops: estimate | read_cost | tokens |
agg_sum | poison_scan."""
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
    else:
        print(f"unknown op {op!r}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
