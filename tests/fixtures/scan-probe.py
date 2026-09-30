"""Exposes scan.sh's functions to the test suite: they live in an embedded
heredoc, so they cannot be imported. One op per assertion; see main()."""
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


def _load_at(projects_dir):
    """Exec the embedded module against a synthetic projects tree."""
    src = open(SCAN, errors="replace").read().splitlines()
    a = next(i for i, l in enumerate(src) if l.startswith("python3 - ")) + 1
    b = next(i for i, l in enumerate(src) if l.strip() == "PYEOF")
    ns = {"__name__": "atmod"}
    sys.argv = ["scan", projects_dir, "", "", "/tmp/z", "1"]
    with contextlib.redirect_stdout(io.StringIO()):
        exec(compile("\n".join(src[a:b]), "scan.sh:embedded", "exec"), ns)
    return ns


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
        # Optional 4th-6th args: cache read, 5-minute cache write, 1-hour cache write.
        model, ti, to = argv[1], float(argv[2]), float(argv[3])
        extra = [float(x) for x in argv[4:7]]
        print(fmt(ns["estimate_cost"](model, ti, to, *extra)))
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
    elif op == "dedup_usage":
        # Claude Code writes one line per content block, and every line of a
        # message repeats that message's id and usage. Summing per line counted
        # a 3-block message three times; the transcript page (which de-dups by
        # id) showed a quarter of the dropdown's tokens for the same session.
        import tempfile, shutil
        root = tempfile.mkdtemp(prefix="dedup-")
        try:
            f = os.path.join(root, "s.jsonl")
            u = {"input_tokens": 10, "output_tokens": 100, "cache_read_input_tokens": 1000}
            with open(f, "w") as fh:
                for block in ({"type": "text", "text": "hi"},
                              {"type": "tool_use", "name": "Bash", "input": {"command": "ls"}},
                              {"type": "tool_use", "name": "Read", "input": {"file_path": "/a"}}):
                    fh.write(json.dumps({"type": "assistant", "message": {
                        "id": "msg_1", "model": "claude-opus-5-5", "usage": u,
                        "content": [block]}}) + "\n")
                fh.write(json.dumps({"type": "assistant", "message": {
                    "id": "msg_2", "model": "claude-opus-5-5",
                    "usage": {"input_tokens": 10, "output_tokens": 50},
                    "content": [{"type": "text", "text": "done"}]}}) + "\n")
            ns2 = load()
            r = ns2["read_transcript"](f)
            h = ns2["claude_parse_session"](f)
            print(f"live={r['turns']}:{r['input_tokens']}:{r['output_tokens']}:{r['cache_read']}:{r['tool_calls']}"
                  f"|hist={h['turns']}:{h['tokens_in']}:{h['tokens_out']}")
        finally:
            shutil.rmtree(root, ignore_errors=True)
    elif op == "subagents":
        # A sub-agent is its own transcript under <sid>/subagents/, not a child
        # process; child processes are background shells. Running means written
        # recently. Prints: no dir, one fresh + one stale, missing transcript path.
        import tempfile, shutil, time
        root = tempfile.mkdtemp(prefix="subag-")
        try:
            ns2 = load()
            count = ns2["count_active_subagents"]
            main = os.path.join(root, "sid.jsonl")
            open(main, "w").close()
            none = count(main)
            d = os.path.join(root, "sid", "subagents")
            os.makedirs(d)
            open(os.path.join(d, "agent-fresh.jsonl"), "w").close()
            stale = os.path.join(d, "agent-stale.jsonl")
            open(stale, "w").close()
            old = time.time() - 600
            os.utime(stale, (old, old))
            open(os.path.join(d, "agent-fresh.meta.json"), "w").close()
            print(f"{none}:{count(main)}:{count('')}")
        finally:
            shutil.rmtree(root, ignore_errors=True)
    elif op == "history_identity":
        # An ended session must keep the name, project and model it showed while
        # live: its title from the transcript, its project from the real cwd
        # (the folder name decodes '-' ambiguously), and its model family with
        # the full id kept. Live sessions never use up history slots.
        import tempfile, shutil
        root = tempfile.mkdtemp(prefix="hid-")
        try:
            proj = os.path.join(root, "projects", "-Users-x-my-app")
            os.makedirs(proj)

            def write(sid, turns, title=None, model="claude-fable-5-1"):
                with open(os.path.join(proj, f"{sid}.jsonl"), "w") as fh:
                    fh.write(json.dumps({"type": "user", "cwd": "/Users/x/my-app",
                                         "message": {"role": "user", "content": "go"}}) + "\n")
                    for i in range(turns):
                        fh.write(json.dumps({"type": "assistant", "message": {
                            "id": f"{sid}-{i}", "model": model,
                            "usage": {"input_tokens": 1, "output_tokens": 1}}}) + "\n")
                    if title:
                        fh.write(json.dumps({"type": "custom-title", "customTitle": title}) + "\n")
            write("ended-1", 5, title="nice-name")
            write("stub-1", 2)
            write("live-1", 6)
            ns2 = _load_at(os.path.join(root, "projects"))
            rows = ns2["get_session_history"](live_sids={"live-1"})
            r = rows[0] if rows else {}
            live_absent = "live_absent" if all(x["session_id"] != "live-1" for x in rows) else "live_present"
            print(f"{len(rows)}|{r.get('name')}|{r.get('project')}|{r.get('model')}|{r.get('model_full')}|{live_absent}"
                  f"|{ns2['short_model']('claude-opus-5-5')},{ns2['short_model']('claude-sonnet-4-6')},{ns2['short_model']('opus')}")
        finally:
            shutil.rmtree(root, ignore_errors=True)
    elif op == "subagent_cost":
        # A session's cost includes its sub-agents' own transcripts; one on an
        # unpriced model makes the total unknown rather than too low.
        import tempfile, shutil
        root = tempfile.mkdtemp(prefix="subcost-")
        try:
            def write(path, model):
                with open(path, "w") as fh:
                    fh.write(json.dumps({"type": "assistant", "message": {
                        "id": "m", "model": model,
                        "usage": {"input_tokens": 1_000_000, "output_tokens": 0}}}) + "\n")
            main = os.path.join(root, "s.jsonl")
            write(main, "claude-opus-5-5")
            os.makedirs(os.path.join(root, "s", "subagents"))
            write(os.path.join(root, "s", "subagents", "agent-a.jsonl"), "claude-haiku-4-5")
            ns2 = load()
            t = ns2["read_transcript"](main)
            with_agent = ns2["session_cost"]("claude-opus-5-5", t, main)
            write(os.path.join(root, "s", "subagents", "agent-b.jsonl"), "some-future-model")
            unknown = ns2["session_cost"]("claude-opus-5-5", t, main)
            print(f"{fmt(with_agent)}:{fmt(unknown)}")
        finally:
            shutil.rmtree(root, ignore_errors=True)
    elif op == "machine_facts":
        # A statusline fact every live row shares is about the machine, so it is
        # said once; a row whose value differs keeps it; one row proves nothing.
        ns2 = load()
        split = ns2["split_machine_facts"]

        def row(mcp, pm2):
            return {"statusline": {"mcp_down": mcp, "pm2_errored": pm2, "scratchpad_count": "44",
                                   "ctx_remaining": "50"}}
        rows = [row("a,b", "1"), row("a,b", "1"), row("a,b", "2")]
        m = split(rows)
        kept = [r["statusline"]["pm2_errored"] for r in rows]
        one = [row("a,b", "1")]
        m1 = split(one)
        print(f"{sorted(m.items())}|{[r['statusline']['mcp_down'] for r in rows]}|{kept}"
              f"|ctx={rows[0]['statusline']['ctx_remaining']}|single={m1}:{one[0]['statusline']['mcp_down']}")
    elif op == "read_pid_file":
        print(load()["read_pid_file"](int(argv[1]), argv[2]).strip())
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
                # Four turns, so the history list does not hide it as a stub.
                fh.write(('{"type":"assistant","message":{"model":"claude-opus-4-8",'
                          '"usage":{"input_tokens":Infinity,"output_tokens":NaN}}}\n') * 4)
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
    elif op == "history_stubs":
        # Ended list hides stubs: sessions of 0 to 3 turns never appear.
        import tempfile, shutil
        root = tempfile.mkdtemp(prefix="stubs-")
        try:
            d = os.path.join(root, "projects", "-tmp-stubs")
            os.makedirs(d)
            for t in (0, 2, 3, 4, 10):
                with open(os.path.join(d, f"dddd{t:04d}-0000-4000-8000-000000000000.jsonl"), "w") as fh:
                    fh.write(json.dumps({"type": "user", "message": {"content": "hi"}}) + "\n")
                    for _ in range(t):
                        fh.write(json.dumps({"type": "assistant", "message": {
                            "model": "claude-opus-4-8"}}) + "\n")
            ns2 = _load_at(os.path.join(root, "projects"))
            print(",".join(str(h["turns"]) for h in
                           sorted(ns2["get_session_history"](), key=lambda h: h["turns"])))
        finally:
            shutil.rmtree(root, ignore_errors=True)
    elif op == "prompt_filter":
        # The last prompt is what the owner typed: never a task notification,
        # a skill body, hook feedback or a <command-*> wrapper.
        import tempfile, shutil
        root = tempfile.mkdtemp(prefix="prompt-")
        def u(text, **kw):
            return json.dumps({"type": "user", "message": {"role": "user", "content": text}, **kw})
        cases = {
            "A": [u("fix the login bug"),
                  u("<task-notification> <task-id>a1</task-id> done</task-notification>",
                    origin={"kind": "task-notification"}),
                  u("<task-notification> <task-id>a2</task-id></task-notification>"),
                  u("Base directory for this skill: /x/y", isMeta=True),
                  u("Base directory for this skill: /x/z"),
                  u("Stop hook feedback: answer the request", isMeta=True)],
            "B": [u("first"),
                  u("<command-message>catchup</command-message>\n<command-name>/catchup</command-name>\n"
                    "<command-args>at notes.md</command-args>"),
                  u("<local-command-stdout>ok</local-command-stdout>")],
            "C": [u("<task-notification>x</task-notification>"),
                  u("<system-reminder>only a reminder</system-reminder>")],
        }
        try:
            ns2 = load()
            out = []
            for k, lines in cases.items():
                p = os.path.join(root, k + ".jsonl")
                with open(p, "w") as fh:
                    fh.write("\n".join(lines) + "\n")
                out.append(f"{k}={ns2['read_transcript'](p)['last_prompt'] or '-'}")
            print("|".join(out))
        finally:
            shutil.rmtree(root, ignore_errors=True)
    elif op == "liveness":
        # Ghost rows: a live row must be an interactive Claude session. The
        # fixture is a fake process table plus a fake ~/.claude/sessions, run
        # through the real get_live_instances. Only 1006 (valid session file)
        # and 1007 (young claude on a terminal, file not written yet) may appear.
        import tempfile, shutil, time as _t
        root = tempfile.mkdtemp(prefix="live-")
        try:
            now = _t.time()
            fmt_ps = lambda t: _t.strftime('%a %b %d %H:%M:%S %Y', _t.localtime(t))
            fmt_file = lambda t: _t.strftime('%a %b %d %H:%M:%S %Y', _t.gmtime(t))
            old, young, day_ago = now - 3600, now - 5, now - 86400
            # 1009: a young claude with no terminal (run by a tool or script).
            ps_rows = [
                (1001, "??", old, "/Applications/Codex.app/Contents/Resources/codex app-server"),
                (1002, "ttys001", young, "claude -p --model sonnet --output-format json You enforce a style ledger"),
                (1003, "ttys001", young, "claude --print summarize this"),
                (1005, "ttys002", old, "/usr/bin/vim notes.txt"),
                (1006, "ttys003", old, "claude --model opus -n real"),
                (1007, "ttys004", young, "claude --model opus"),
                (1008, "ttys005", old, "claude --model opus"),
                (1009, "??", young, "claude mcp list"),
            ]
            ps_text = "\n".join(f"{p:>6} {tty:<8} {fmt_ps(t)}     {cmd}" for p, tty, t, cmd in ps_rows)
            sdir = os.path.join(root, "sessions")
            os.makedirs(sdir)
            def sess(pid, started, kind, sid):
                with open(os.path.join(sdir, f"{pid}.json"), "w") as fh:
                    json.dump({"pid": pid, "sessionId": sid, "cwd": "/tmp/live-fx",
                               "procStart": fmt_file(started), "kind": kind,
                               "name": f"n{pid}", "status": "busy",
                               "updatedAt": int(now * 1000),
                               "statusUpdatedAt": int(now * 1000)}, fh)
            sess(1002, young, "print", "aaaaaaaa-0000-4000-8000-000000001002")   # headless worker's file
            sess(1004, old, "interactive", "aaaaaaaa-0000-4000-8000-000000001004")  # stale: pid gone
            sess(1005, day_ago, "interactive", "aaaaaaaa-0000-4000-8000-000000001005")  # pid reused
            sess(1006, old, "interactive", "aaaaaaaa-0000-4000-8000-000000001006")
            ns2 = load()
            ns2["SESSIONS_DIR"] = sdir
            ns2["_ps_snapshot"] = lambda: ps_text
            rows = ns2["get_live_instances"]()
            print(",".join(f"{r['pid']}:{r['kind']}:{r['session_id'][-4:] or '-'}:{r['name'] or '-'}"
                           for r in sorted(rows, key=lambda r: r['pid'])))
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
        # pid-truth vs ipc's liveness claim. Nothing is written to a ledger (the
        # old raw log grew to 69 MB with no reader); agreement stays silent; the
        # card flag needs DISAGREE_DEBOUNCE consecutive scans; and the card's own
        # session_state is never touched by the digest's opinion.
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
            early = []
            for _ in range(5):
                lv = mk_live()
                ns2["run_ipc_disagreement_pass"](lv)
                early.append(any("disagree" in (r.get("ipc") or {}) for r in lv))
            flag1 = "FLAGGED_EARLY" if any(early) else "NOFLAG5"
            live2 = mk_live()
            ns2["run_ipc_disagreement_pass"](live2)
            n_raw = "NOLOG" if not os.path.exists(log) and "_IPC_DISAGREE_LOG" not in ns2 else "LOG"
            fa = next(r for r in live2 if r["session_id"] == sa)
            fb = next(r for r in live2 if r["session_id"] == sb)
            flag2 = ("FLAG" + str(fa["ipc"].get("disagree", {}).get("scans"))
                     if "disagree" in fa["ipc"] else "NOFLAG6")
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
