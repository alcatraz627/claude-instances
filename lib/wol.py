#!/usr/bin/env python3
"""Wake-on-LAN: wake a sleeping machine on the home network by its MAC address.

The Switchboard's Machine tab calls this. Saved devices live in
~/.claude/widgets/.wol-targets.json as [{name, mac, broadcast}].

  wol.py list                              JSON list of saved devices
  wol.py add "<name>" <mac> [broadcast]    save a device (broadcast default 255.255.255.255)
  wol.py remove <mac>                      forget a device
  wol.py wake <mac> [broadcast]            send the magic packet (UDP 9 and 7)

A magic packet is six 0xFF bytes then the MAC sixteen times. It only wakes a
machine whose network card has wake-on-LAN turned on, and it gets no reply,
so "sent" is all this can report.
"""
import json
import os
import re
import socket
import sys

TARGETS = os.path.expanduser("~/.claude/widgets/.wol-targets.json")
MAC_RE = re.compile(r"^([0-9a-f]{2}[:-]?){5}[0-9a-f]{2}$", re.I)


def out(obj, code=0):
    print(json.dumps(obj))
    sys.exit(code)


def norm_mac(mac):
    if not MAC_RE.match(mac or ""):
        out({"error": f"not a MAC address: {mac}"}, 2)
    h = re.sub(r"[^0-9a-f]", "", mac.lower())
    return ":".join(h[i:i + 2] for i in range(0, 12, 2))


def load():
    try:
        with open(TARGETS) as f:
            d = json.load(f)
        return d if isinstance(d, list) else []
    except Exception:
        return []


def save(items):
    tmp = TARGETS + ".tmp"
    with open(tmp, "w") as f:
        json.dump(items, f, indent=2)
    os.replace(tmp, TARGETS)


def wake(mac, broadcast):
    packet = b"\xff" * 6 + bytes.fromhex(mac.replace(":", "")) * 16
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    try:
        for port in (9, 7):
            s.sendto(packet, (broadcast, port))
    finally:
        s.close()


def main():
    a = sys.argv[1:]
    cmd = a[0] if a else "help"
    if cmd == "list":
        out(load())
    elif cmd == "add" and len(a) >= 3:
        mac = norm_mac(a[2])
        items = [t for t in load() if t.get("mac") != mac]
        items.append({"name": a[1] or mac, "mac": mac, "broadcast": a[3] if len(a) > 3 else "255.255.255.255"})
        save(items)
        out({"ok": True})
    elif cmd == "remove" and len(a) == 2:
        mac = norm_mac(a[1])
        save([t for t in load() if t.get("mac") != mac])
        out({"ok": True})
    elif cmd == "wake" and len(a) >= 2:
        mac = norm_mac(a[1])
        try:
            wake(mac, a[2] if len(a) > 2 else "255.255.255.255")
        except OSError as e:
            out({"error": f"could not send: {e}"}, 1)
        out({"ok": True, "sent_to": mac})
    else:
        print(__doc__)
        sys.exit(0 if cmd in ("help", "-h", "--help") else 64)


if __name__ == "__main__":
    main()
