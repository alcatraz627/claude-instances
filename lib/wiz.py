#!/usr/bin/env python3
"""Smart bulbs on the home network (Philips WiZ): find them, read them, set them.

The Switchboard's Home tab calls this; it can also be run by hand. It speaks
WiZ's local UDP protocol directly (port 38899, JSON messages), the same one
~/Code/Personal/home-server/src/lib/server/wiz.ts used, so there is no cloud,
no account and no credential. Names the owner gives bulbs live in
~/.claude/widgets/.wiz-names.json, keyed by MAC address.

  wiz.py discover [--timeout 3]          JSON list of bulbs with their state
  wiz.py set <ip> key=value ...          keys: state=on|off, dimming=10-100,
                                         temp=2200-6500, scene=1-32
  wiz.py name <mac> "<name>"             save a display name ("" removes it)
  wiz.py scenes                          JSON id-to-name table

Exit 0 with JSON on stdout; exit 1 with {"error": ...} when a bulb does not answer.
"""
import json
import os
import socket
import sys
import time

PORT = 38899
NAMES = os.path.expanduser("~/.claude/widgets/.wiz-names.json")
REPLY_TIMEOUT = 2.0

# WiZ's built-in scene ids, as the bulbs number them.
SCENES = {
    1: "Ocean", 2: "Romance", 3: "Sunset", 4: "Party", 5: "Fireplace", 6: "Cozy",
    7: "Forest", 8: "Pastel Colors", 9: "Wake Up", 10: "Bedtime", 11: "Warm White",
    12: "Daylight", 13: "Cool White", 14: "Night Light", 15: "Focus", 16: "Relax",
    17: "True Colors", 18: "TV Time", 19: "Plant Growth", 20: "Spring", 21: "Summer",
    22: "Fall", 23: "Deep Dive", 24: "Jungle", 25: "Mojito", 26: "Club",
    27: "Christmas", 28: "Halloween", 29: "Candlelight", 30: "Golden White",
    31: "Pulse", 32: "Steampunk",
}


def out(obj, code=0):
    print(json.dumps(obj))
    sys.exit(code)


def load_names():
    try:
        with open(NAMES) as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def local_ip():
    # The address the machine would use to reach the internet: the LAN one.
    # No packet is sent; connect() on UDP only picks a route.
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    finally:
        s.close()


def ask(ip, method, params=None, timeout=REPLY_TIMEOUT):
    """One request to one bulb; its result dict, or None if it did not answer."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        s.sendto(json.dumps({"method": method, "params": params or {}}).encode(), (ip, PORT))
        data, _ = s.recvfrom(4096)
        msg = json.loads(data)
        return msg.get("result") if isinstance(msg, dict) else None
    except (socket.timeout, OSError, ValueError):
        return None
    finally:
        s.close()


def ask_retry(ip, method, params=None, tries=4):
    """A bulb that has just applied a change can miss the next request, so
    reads right after a write get a few spaced attempts."""
    for i in range(tries):
        r = ask(ip, method, params, timeout=0.8)
        if r:
            return r
        time.sleep(0.15 * (i + 1))
    return None


def bulb_state(ip, mac, names):
    r = ask_retry(ip, "getPilot") or {}
    scene = r.get("sceneId")
    return {
        "ip": ip, "mac": mac, "name": names.get(mac) or "",
        "reachable": bool(r),
        "on": bool(r.get("state")),
        "dimming": r.get("dimming"),
        "temp": r.get("temp"),
        "scene": scene if scene else None,
        "scene_name": SCENES.get(scene) if scene else None,
        "rgb": [r.get("r"), r.get("g"), r.get("b")] if r.get("r") is not None else None,
    }


def discover(timeout):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.settimeout(0.25)
    msg = {"method": "registration",
           "params": {"phoneMac": "AAAAAAAAAAAA", "register": False, "phoneIp": local_ip(), "id": "1"}}
    s.sendto(json.dumps(msg).encode(), ("255.255.255.255", PORT))
    found = {}
    end = time.time() + timeout
    while time.time() < end:
        try:
            data, addr = s.recvfrom(4096)
            r = json.loads(data).get("result", {})
            if r.get("mac"):
                found[r["mac"]] = addr[0]
        except socket.timeout:
            pass
        except (OSError, ValueError):
            break
    s.close()
    names = load_names()
    bulbs = [bulb_state(ip, mac, names) for mac, ip in found.items()]
    # Named bulbs first, then by address, so the list order is stable.
    bulbs.sort(key=lambda b: (b["name"] == "", b["name"].lower(), tuple(int(x) for x in b["ip"].split("."))))
    return bulbs


def parse_set(pairs):
    params = {}
    for p in pairs:
        if "=" not in p:
            out({"error": f"expected key=value, got {p}"}, 2)
        k, v = p.split("=", 1)
        try:
            if k == "state":
                if v not in ("on", "off"):
                    raise ValueError
                params["state"] = v == "on"
            elif k == "dimming":
                n = int(v)
                if not 10 <= n <= 100:
                    raise ValueError
                params["dimming"] = n
            elif k == "temp":
                n = int(v)
                if not 2200 <= n <= 6500:
                    raise ValueError
                params["temp"] = n
            elif k == "scene":
                n = int(v)
                if n not in SCENES:
                    raise ValueError
                params["sceneId"] = n
            else:
                out({"error": f"unknown key {k}"}, 2)
        except ValueError:
            out({"error": f"invalid value for {k}: {v}"}, 2)
    if not params:
        out({"error": "nothing to set"}, 2)
    return params


def main():
    args = sys.argv[1:]
    cmd = args[0] if args else "help"
    if cmd == "discover":
        t = 3.0
        if "--timeout" in args:
            t = float(args[args.index("--timeout") + 1])
        out(discover(t))
    elif cmd == "set" and len(args) >= 3:
        ip, params = args[1], parse_set(args[2:])
        r = ask(ip, "setPilot", params)
        if not r or r.get("success") is not True:
            out({"error": f"bulb {ip} did not confirm the change"}, 1)
        mac = (ask_retry(ip, "getSystemConfig") or {}).get("mac", "")
        out(bulb_state(ip, mac, load_names()))
    elif cmd == "name" and len(args) == 3:
        names = load_names()
        if args[2]:
            names[args[1]] = args[2]
        else:
            names.pop(args[1], None)
        tmp = NAMES + ".tmp"
        with open(tmp, "w") as f:
            json.dump(names, f, indent=2)
        os.replace(tmp, NAMES)
        out({"ok": True})
    elif cmd == "scenes":
        out({str(k): v for k, v in SCENES.items()})
    else:
        print(__doc__)
        sys.exit(0 if cmd in ("help", "-h", "--help") else 64)


if __name__ == "__main__":
    main()
