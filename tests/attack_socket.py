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
import atexit
import json
import os
import shutil
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
    # ballast_gb: 0 -- this fixture's config never set it, so every run
    # that found >8G free (ballast_build's own "comfortable" gate) silently
    # built a REAL 2G pre-allocated reserve under state/ballast/ nobody was
    # testing for. Found leaking 16 of these on the operator's real /tmp,
    # ~2.1G apiece, some untouched for a week (msg 3196/3200). Nothing here
    # exercises ballast, so it's off, not just cleaned up after.
    # tmpfs_mounts: [] -- left at the default (["/tmp", "/dev/shm"]) this
    # fixture's scan/why/blame fuzzing would walk the REAL /tmp and
    # /dev/shm too (9e71be7: the index now unions scan_roots with
    # tmpfs_mounts), including the real byebyte-attack-* corpus this same
    # script is the one leaking. Never intended, and never needed to
    # exercise anything below -- the hostile fuzz targets are the socket's
    # own parsing, not tmpfs coverage.
    json.dump({"poll_interval": 1, "owner_uid": os.getuid(),
               "scan_roots": [FIX], "tmpfs_mounts": [], "index_min_bytes": 4096,
               "ballast_gb": 0}, f)

env = dict(os.environ)
env["BYEBYTE_RUNTIME_DIR"] = RD
env["BYEBYTE_STATE_DIR"] = os.path.join(RD, "state")
env["BYEBYTE_TEST_HOME"] = os.path.join(FIX, "home")
proc = subprocess.Popen(
    [sys.executable, os.path.join(HERE, "src", "bin", "byebyted"),
     "--config", os.path.join(RD, "config.json")],
    env=env)


def _cleanup():
    # Runs at interpreter exit no matter which path got there -- normal
    # completion, an early `raise SystemExit(1)` (the old code had one
    # before the socket even appears, at RD's very first use, that skipped
    # cleanup entirely), or an uncaught exception. The prior version only
    # tore down `proc` at the bottom of a linear script and never removed
    # RD at all, on any path: every run left its ephemeral dir behind.
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    shutil.rmtree(RD, ignore_errors=True)


atexit.register(_cleanup)

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
print("== command-surface hostile fuzz (scan/why/blame/purge/declare/reserve/"
      "journal-cap/fstrim-schedule/tmp-size/ghosts/ballast/kernels/advise/"
      "burn/sweep) ==")
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
    # this fixture's only scan_root is FIX, and nothing real lives in it
    # (just an empty "home" subdir) -- every one of these is refused
    # before touching disk either way, by the compiled-in floor or by the
    # "outside every configured scan root" envelope, safe to fuzz freely
    # including dry_run: False (the invariant has to hold past --yes too)
    {"cmd": "declare"}, {"cmd": "declare", "path": 123},
    {"cmd": "declare", "path": None}, {"cmd": "declare", "path": []},
    {"cmd": "declare", "path": ""}, {"cmd": "declare", "path": "A" * 3000},
    {"cmd": "declare", "path": "/"}, {"cmd": "declare", "path": "/", "dry_run": False},
    {"cmd": "declare", "path": "/home", "dry_run": False},
    {"cmd": "declare", "path": "/etc/passwd", "dry_run": False},
    {"cmd": "declare", "path": "../../../../etc/passwd", "dry_run": False},
    {"cmd": "declare", "path": "/dev/shm", "dry_run": False},
    {"cmd": "declare", "path": "nonexistent-relative-path"},
    {"cmd": "declare", "dry_run": "yes"}, {"cmd": "declare", "dry_run": 1},
    # reserve's own real-device reads (tune2fs -l) need root to even READ,
    # let alone write -- this harness runs unprivileged, so every one of
    # these fails closed at the permission-denied read, long before any
    # write is attempted, safe to fuzz including percent 0/negative/huge
    {"cmd": "reserve"}, {"cmd": "reserve", "mountpoint": 123},
    {"cmd": "reserve", "mountpoint": None}, {"cmd": "reserve", "mountpoint": ""},
    {"cmd": "reserve", "mountpoint": "/", "percent": 0, "dry_run": False},
    {"cmd": "reserve", "mountpoint": "/", "percent": -5, "dry_run": False},
    {"cmd": "reserve", "mountpoint": "/", "percent": 99999, "dry_run": False},
    {"cmd": "reserve", "mountpoint": "/", "percent": "five"},
    {"cmd": "reserve", "mountpoint": "/", "percent": None, "dry_run": False},
    {"cmd": "reserve", "mountpoint": "/etc", "percent": 1, "dry_run": False},
    {"cmd": "reserve", "mountpoint": "nonexistent-mount", "percent": 1},
    {"cmd": "reserve", "dry_run": "yes"}, {"cmd": "reserve", "dry_run": 1},
    # journal-cap writes under /etc/systemd/journald.conf.d, unreachable to
    # this unprivileged harness's daemon -- dry_run=False fails closed at
    # the permission-denied write, same shape as reserve's real-device
    # reads above, safe to fuzz freely including malformed sizes
    {"cmd": "journal-cap"}, {"cmd": "journal-cap", "size": 123},
    {"cmd": "journal-cap", "size": None}, {"cmd": "journal-cap", "size": ""},
    {"cmd": "journal-cap", "size": "abc"}, {"cmd": "journal-cap", "size": "0M"},
    {"cmd": "journal-cap", "size": "-5G"}, {"cmd": "journal-cap", "size": "A" * 3000},
    {"cmd": "journal-cap", "size": "1G", "dry_run": False},
    {"cmd": "journal-cap", "size": "1G", "dry_run": "yes"},
    {"cmd": "journal-cap", "size": "1G", "dry_run": 1},
    # fstrim-schedule is DELIBERATELY fuzzed dry_run-only, unlike its layer-3
    # siblings above: reserve/declare/journal-cap all route their real-apply
    # path through a fixture-controlled argument (mountpoint/path/a redirect
    # env var) that keeps an unprivileged real-apply attempt sandboxed away
    # from anything that matters. fstrim-schedule takes no such argument --
    # the unit is a hardcoded "fstrim.timer" at the dispatch layer, by
    # design (see byebyted's own comment on _FSTRIM_UNIT) -- so dry_run:
    # False here would be a real, unsandboxed `systemctl disable --now
    # fstrim.timer` attempt against the actual box this harness runs on.
    # is-enabled/show are read-only and safe to fuzz; the write path is
    # exercised for real by smoke.sh's own root-gated throwaway-unit
    # fixture instead, never by this unprivileged fuzzer.
    {"cmd": "fstrim-schedule"}, {"cmd": "fstrim-schedule", "enabled": 123},
    {"cmd": "fstrim-schedule", "enabled": "yes"}, {"cmd": "fstrim-schedule", "enabled": []},
    {"cmd": "fstrim-schedule", "dry_run": "yes"}, {"cmd": "fstrim-schedule", "dry_run": 1},
    # tmp-size writes under /etc/systemd/system/tmp.mount.d, unreachable to
    # this unprivileged harness's daemon -- same shape as journal-cap (a
    # config-file write, not a live act like fstrim-schedule's toggle), so
    # dry_run: False fails closed at the permission-denied write too
    {"cmd": "tmp-size"}, {"cmd": "tmp-size", "size": 123},
    {"cmd": "tmp-size", "size": None}, {"cmd": "tmp-size", "size": ""},
    {"cmd": "tmp-size", "size": "abc"}, {"cmd": "tmp-size", "size": "0M"},
    {"cmd": "tmp-size", "size": "-5G"}, {"cmd": "tmp-size", "size": "A" * 3000},
    {"cmd": "tmp-size", "size": "2G", "dry_run": False},
    {"cmd": "tmp-size", "size": "2G", "dry_run": "yes"},
    {"cmd": "tmp-size", "size": "2G", "dry_run": 1},
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
# proc/RD teardown happens in _cleanup(), registered with atexit above --
# it fires here on the normal path same as before, and also on every early
# exit this script has (see _cleanup's own comment).
print()
if fails:
    print("FAILURES:")
    for f in fails:
        print("  -", f)
    raise SystemExit(1)
print("ALL ATTACKS DEFENDED ✔")
