#!/usr/bin/env python3
"""
Adversarial test harness for byebyted (phanspeed shape: a fails[] list,
phase-by-phase prints, "ALL ATTACKS DEFENDED" or a SystemExit(1)).

Unlike phanspeed's Daemon, byebyted has no importable handle_cmd() to fuzz
directly — its dispatch lives inline in Control.handle() against a real
socket. So this harness boots the REAL daemon as a subprocess (same as
make smoke) against an ephemeral fixture, then attacks the socket itself:
every M2/M3/M4 command with hostile field values, plus the classic phases
(oversized/garbage/nested/stall). Asserts the daemon never crashes and
always answers ping afterward. Fixture-only, never a real path.

Run as your normal user:  python3 tests/attack_socket.py
"""
import json
import os
import socket
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
fails = []

RD = tempfile.mkdtemp(prefix="byebyte-attack-")
FIX = os.path.join(RD, "tree")
os.makedirs(os.path.join(FIX, "home"), exist_ok=True)
with open(os.path.join(RD, "config.json"), "w") as f:
    json.dump({"poll_interval": 1, "owner_uid": os.getuid(),
               "scan_roots": [FIX], "index_min_bytes": 4096}, f)

env = dict(os.environ)
env["BYEBYTE_RUNTIME_DIR"] = RD
env["BYEBYTE_STATE_DIR"] = os.path.join(RD, "state")
env["BYEBYTE_TEST_HOME"] = os.path.join(FIX, "home")
proc = subprocess.Popen(
    [sys.executable, os.path.join(HERE, "bin", "byebyted"),
     "--config", os.path.join(RD, "config.json")],
    env=env)

SOCK = os.path.join(RD, "control.sock")
for _ in range(80):
    if os.path.exists(SOCK):
        break
    time.sleep(0.1)
else:
    print("byebyted never created its socket")
    raise SystemExit(1)
time.sleep(0.3)


def ask(payload, timeout=8):
    """One request/response over a fresh connection. payload: bytes or dict."""
    if isinstance(payload, dict):
        payload = json.dumps(payload).encode() + b"\n"
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(SOCK)
    if payload is not None:
        s.sendall(payload)
    buf = b""
    try:
        while b"\n" not in buf:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
    except socket.timeout:
        pass
    s.close()
    try:
        return json.loads(buf.decode())
    except ValueError:
        return None


def alive(where):
    r = ask({"cmd": "ping"})
    if not (isinstance(r, dict) and r.get("ok") is True):
        fails.append(f"[{where}] daemon not answering ping: {r!r}")
        return False
    return True


# ------------------------------------------------------------- command surface
print("== command-surface hostile fuzz (scan/why/blame/purge/ghosts/"
      "ballast/kernels/advise/burn/sweep) ==")
HOSTILE = [
    {"cmd": "status"}, {"cmd": "scan"}, {"cmd": "scan", "extra": "garbage"},
    {"cmd": "why"}, {"cmd": "why", "path": 123}, {"cmd": "why", "path": []},
    {"cmd": "why", "limit": -1}, {"cmd": "why", "limit": "lots"},
    {"cmd": "why", "limit": 99999999}, {"cmd": "why", "path": "A" * 3000},
    {"cmd": "blame"}, {"cmd": "blame", "since": "yesterday"},
    {"cmd": "blame", "since": -5}, {"cmd": "blame", "since": None},
    {"cmd": "blame", "since": True}, {"cmd": "blame", "limit": -1},
    {"cmd": "purge"}, {"cmd": "purge", "category": 123},
    {"cmd": "purge", "category": "/etc/passwd"},
    {"cmd": "purge", "category": "not-a-real-category"},
    {"cmd": "purge", "category": ["hf-hub"]},
    {"cmd": "purge", "category": "hf-hub", "dry_run": "yes"},
    {"cmd": "purge", "category": "hf-hub", "dry_run": 1},
    {"cmd": "purge", "category": None},
    {"cmd": "ghosts"}, {"cmd": "ghosts", "extra": [1, 2, 3]},
    {"cmd": "ballast"}, {"cmd": "ballast", "action": "explode"},
    {"cmd": "ballast", "action": 123}, {"cmd": "ballast", "action": None},
    {"cmd": "kernels"}, {"cmd": "kernels", "extra": {"a": 1}},
    {"cmd": "advise"}, {"cmd": "advise", "extra": "garbage"},
    {"cmd": "burn", "seconds": 0}, {"cmd": "burn", "seconds": 31},
    {"cmd": "burn", "seconds": -5}, {"cmd": "burn", "seconds": "ten"},
    {"cmd": "burn", "seconds": 1, "limit": -1},
    {"cmd": "burn", "seconds": None},
    # sweep_categories is empty in this fixture's config (nothing armed), so
    # even {"dry": false} can never touch disk here — safe to fuzz freely
    {"cmd": "sweep"}, {"cmd": "sweep", "dry": "yes"}, {"cmd": "sweep", "dry": 1},
    {"cmd": "sweep", "dry": None}, {"cmd": "sweep", "dry": []},
    {"cmd": "sweep", "history": True, "limit": -1},
    {"cmd": "sweep", "history": True, "limit": "lots"},
    {"cmd": "sweep", "history": "yes"},
    {"cmd": "wat"}, {"cmd": 123}, {"cmd": None}, {}, {"cmd": []},
]
for msg in HOSTILE:
    try:
        r = ask(msg)
        if not isinstance(r, dict):
            fails.append(f"non-dict/garbage response to {msg}: {r!r}")
    except Exception as e:
        fails.append(f"ask() raised on {msg}: {e!r}")
if not alive("command-surface fuzz"):
    pass
print(f"   {len(HOSTILE)} hostile command messages, daemon alive: "
      f"{not any('command-surface' in f or 'ask() raised' in f for f in fails)}")

# ---------------------------------------------------------------- oversized
print("== oversized ==")
big = b'{"cmd":"why","path":"' + b"A" * (200 * 1024) + b'"}\n'
r = ask(big)
if not (isinstance(r, dict) and "error" in r):
    fails.append(f"oversized message not refused: {r!r}")
alive("after oversized")
print(f"   200KB payload refused, daemon alive: {alive('oversized tail')}")

# ------------------------------------------------------------------ garbage
print("== garbage / non-object ==")
for p in (b"not json at all\n", b"[1,2,3]\n", b'"just a string"\n', b"42\n",
          b"null\n", b"\x00\xff\x02\n", b"\n", b"   \n", b'{"cmd":\n'):
    r = ask(p)
    if not (isinstance(r, dict) and "error" in r):
        fails.append(f"garbage input not refused ({p!r}): {r!r}")
alive("after garbage")
print(f"   {9} garbage payloads refused, daemon alive: {alive('garbage tail')}")

# ------------------------------------------------------------------- nested
print("== nested ==")
# Deep enough to matter (the scanner bumps recursionlimit to 20000, so a
# shallower payload wouldn't touch that path) but still under MAX_LINE
# (4096B) so it reaches the JSON parser instead of being refused as
# oversized first — exercising a genuinely different code path than the
# oversized phase above.
depth = 1000
nested = (b'{"cmd":"why","path":' + b"[" * depth + b"1" + b"]" * depth
          + b'}\n')
assert len(nested) < 4096, "nested payload must stay under MAX_LINE"
r = ask(nested)
if not isinstance(r, dict):
    fails.append(f"nested payload got non-dict/no response: {r!r}")
alive("after nested")
print(f"   depth-{depth} nested payload handled, daemon alive: "
      f"{alive('nested tail')}")

# --------------------------------------------------------------------- stall
print("== stall (partial message, slow-drip client) ==")
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(10)
s.connect(SOCK)
s.sendall(b'{"cmd":"sta')  # deliberately incomplete, no trailing newline
# a stalled client must never block a fresh, well-behaved one
if not alive("during stall"):
    fails.append("a stalled connection blocked a concurrent one")
time.sleep(6)  # past the server's 5s per-connection read timeout
try:
    s.settimeout(2)
    s.recv(4096)
except (socket.timeout, OSError):
    pass
s.close()
if not alive("after stall"):
    fails.append("daemon did not recover after a stalled client")
print(f"   stalled client isolated, daemon alive throughout: {alive('stall tail')}")

# ---------------------------------------------------------------------- done
proc.terminate()
try:
    proc.wait(timeout=5)
except subprocess.TimeoutExpired:
    proc.kill()
    proc.wait()

print()
if fails:
    print("FAILURES:")
    for f in fails:
        print("  -", f)
    raise SystemExit(1)
print("ALL ATTACKS DEFENDED ✔")
