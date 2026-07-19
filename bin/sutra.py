"""sutra — the shared runtime backbone of the pill family.

One canonical source, vendored byte-identical into each pill (ByeByte,
RAMstein, coldspot, phanspeed, kast, gestalt) so every .deb stays
self-contained with zero external dependency. `make vendor` in a pill copies
this file in; a CI hash check keeps the copies from drifting. When all pills
sit at the same sutra version they share ONE hash — that shared hash is the
family's proof they agree on the substrate.

What sutra owns — the substrate every pill daemon repeats, and the part we
refuse to hand-fix six times:
  * ControlServer — the SO_PEERCRED-gated newline-JSON control socket
    (the security seam: peer check, bounded reads, hostile-input framing)
  * load_config    — the seed-never-master typed+clamped config loader
  * write_status   — the atomic (tmp+rename) status.json writer
  * ewma_rate      — the EWMA burn-rate accumulator
  * request        — the client side of the socket, for CLIs and healthchecks
  * read_status    — read status.json without the daemon
  * runtime_paths / stop_event — the small main() scaffolding

What sutra does NOT own, by design: domain polling, the sqlite index, the
verbs, the pill. Those are each pill's own organs. Sutra is the skeleton.

Threat model (inherited verbatim from the pill daemons): an unprivileged
local process abusing a root daemon over an AF_UNIX socket. Every field is
hostile until proven otherwise; a bad request answers {"error": ...} and the
connection dies, never the daemon.

stdlib only, by constitution. GPLv3.
"""

import grp
import json
import math
import os
import pwd
import re
import signal
import socket
import struct
import threading

SUTRA_VERSION = "0.1.0"


# --- config: the seed, never the master -------------------------------------
# A pill owns its DEFAULTS/CLAMPS; sutra owns the loading discipline. The file
# can tune numbers within clamps, swap list values, and set validated strings —
# it can never add a key the daemon doesn't already know or push one past its
# clamp. Unknown keys and wrong types fall back to the default, silently.

def load_config(path, defaults, clamps, str_patterns=None):
    """Load JSON config over `defaults`, clamping numerics to `clamps`.

    str_patterns: optional {key: regex} — a str-valued key is accepted only
    if it matches (no pattern → any string). bool defaults take bools;
    list defaults take lists-of-str; numeric defaults take non-bool
    numbers clamped to (lo, hi). Anything else keeps the default.
    """
    str_patterns = str_patterns or {}
    cfg = dict(defaults)
    try:
        with open(path) as f:
            raw = json.load(f)
    except (OSError, ValueError):
        return cfg
    if not isinstance(raw, dict):
        return cfg
    for key, default in defaults.items():
        if key not in raw:
            continue
        val = raw[key]
        if isinstance(default, bool):
            # bool is a subclass of int — must be tested before numerics
            if isinstance(val, bool):
                cfg[key] = val
        elif isinstance(default, list):
            if isinstance(val, list) and all(isinstance(x, str) for x in val):
                cfg[key] = val
        elif isinstance(default, str):
            pat = str_patterns.get(key)
            if isinstance(val, str) and (pat is None or re.match(pat, val)):
                cfg[key] = val
        elif isinstance(default, (int, float)):
            if isinstance(val, (int, float)) and not isinstance(val, bool):
                lo, hi = clamps[key]
                cfg[key] = type(default)(min(hi, max(lo, val)))
    return cfg


# --- runtime paths + stop scaffolding ---------------------------------------

def runtime_paths(env_var, default):
    """(runtime_dir, status_path, socket_path) with an env override."""
    runtime_dir = os.environ.get(env_var, default)
    return (runtime_dir,
            os.path.join(runtime_dir, "status.json"),
            os.path.join(runtime_dir, "control.sock"))


def stop_event():
    """A threading.Event set on SIGTERM/SIGINT — the main loop's off switch."""
    stop = threading.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stop.set())
    return stop


# --- status.json: atomically written, least-disclosure perms ----------------

def write_status(status_path, doc, owner=None, mode=0o640):
    """Write `doc` as compact JSON to status_path, atomically (tmp+rename).

    owner: (uid, gid) to chown to when running as root — use -1 to leave a
    side alone. A uid-model pill passes (owner_uid, -1); a group-model pill
    (coldspot) passes (0, group_gid); a user daemon passes None. mode is the
    file mode: 0640 (owner+group read) when there's an owner to reach it, or
    pass 0644 when nobody's chowned so the file stays readable. chmod lands
    before chown, so tightening the mode can't be undone by the ownership
    change (phanspeed's ordering).
    """
    tmp = status_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(doc, f, separators=(",", ":"))
        f.write("\n")
    os.chmod(tmp, mode)
    if owner is not None and os.getuid() == 0:
        os.chown(tmp, owner[0], owner[1])
    os.replace(tmp, status_path)


# --- EWMA burn rate ---------------------------------------------------------

def ewma_rate(prev, value, now, tau):
    """One EWMA step over a monotonic-ish `value` whose growth is the burn.

    Pass the quantity whose INCREASE is the rate you want (disk: used bytes;
    memory: total-avail). Returns (new_state, burn_per_second). Seed the first
    call with prev=None (burn 0), then feed the returned state back each tick.
    tau is the time constant in seconds; a longer tau smooths harder so one
    big spike doesn't panic the ETA.
    """
    burn = 0.0
    if prev is not None:
        dt = max(1e-3, now - prev["t"])
        rate = (value - prev["v"]) / dt
        alpha = 1.0 - math.exp(-dt / tau)
        burn = alpha * rate + (1.0 - alpha) * prev["ewma"]
    return {"t": now, "v": value, "ewma": burn}, burn


# --- the control socket -----------------------------------------------------
# The security seam. SO_PEERCRED-gated by a pluggable `authz(uid, gid) -> bool`
# (allow_uids for the uid-model pills, allow_group for coldspot), on top of the
# 0660 file mode; bounded reads, JSON objects only. ping/status are answered
# here for everyone; every other command is handed to the pill's dispatch,
# which returns a dict, returns None for "not my command", or raises on
# hostile input — either way the failure becomes {"error": ...}, never a crash.

def allow_uids(uids):
    """authz: a peer is allowed iff its uid is in `uids` (include 0 for root).
    The model for ByeByte / RAMstein / phanspeed — pair with socket_owner
    (owner_uid, -1)."""
    allowed = set(uids)
    return lambda uid, _gid: uid in allowed


def allow_group(group_name):
    """authz: root always; else a peer whose PRIMARY group is `group_name` or
    who is a listed member of it. Default deny. coldspot's model — the group is
    looked up from the passwd/group db (the peer's real primary group), not
    trusted from the connection's egid. Pair with socket_owner (0, group_gid)."""
    def authz(uid, _gid):
        if uid == 0:
            return True
        try:
            g = grp.getgrnam(group_name)
            pw = pwd.getpwuid(uid)
        except (KeyError, OSError):
            return False
        return pw.pw_gid == g.gr_gid or pw.pw_name in g.gr_mem
    return authz


class ControlServer(threading.Thread):
    MAX_LINE = 4096

    def __init__(self, socket_path, authz, version, dispatch,
                 get_status=None, socket_owner=None):
        super().__init__(daemon=True)
        self._path = socket_path
        self._authz = authz
        self._version = version
        self._dispatch = dispatch
        self._get_status = get_status
        try:
            os.unlink(socket_path)
        except FileNotFoundError:
            pass
        self.srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.srv.bind(socket_path)
        os.chmod(socket_path, 0o660)
        if socket_owner is not None and os.getuid() == 0:
            os.chown(socket_path, socket_owner[0], socket_owner[1])
        # a deep-ish backlog so a burst of rapid connects is absorbed by the
        # kernel queue instead of bouncing clients with EAGAIN (the originals
        # shipped listen(4)/listen(8) — sutra raises it once for every pill)
        self.srv.listen(64)

    def run(self):
        while True:
            try:
                conn, _ = self.srv.accept()
            except OSError:
                return
            threading.Thread(target=self.handle, args=(conn,),
                             daemon=True).start()

    def handle(self, conn):
        try:
            creds = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED,
                                    struct.calcsize("3i"))
            _pid, peer_uid, peer_gid = struct.unpack("3i", creds)
            if not self._authz(peer_uid, peer_gid):
                raise PermissionError("peer not allowed")
            conn.settimeout(5)
            data = b""
            while b"\n" not in data:
                chunk = conn.recv(1024)
                if not chunk:
                    break
                data += chunk
                if len(data) > self.MAX_LINE:
                    raise ValueError("line too long")
            req = json.loads(data.decode("utf-8").splitlines()[0] or "{}")
            if not isinstance(req, dict):
                raise ValueError("not an object")
            cmd = req.get("cmd")
            if cmd == "ping":
                resp = {"ok": True, "version": self._version}
            elif cmd == "status":
                resp = self._get_status() if self._get_status else \
                    {"error": "no status"}
            else:
                resp = self._dispatch(cmd, req)
                if resp is None:
                    resp = {"error": "unknown command"}
        except Exception as exc:  # noqa: BLE001 — hostile input, never crash
            resp = {"error": type(exc).__name__}
        try:
            conn.sendall((json.dumps(resp, separators=(",", ":")) + "\n")
                         .encode())
        except OSError:
            pass
        finally:
            conn.close()


# --- the client side --------------------------------------------------------
# What a verb CLI, the healthcheck, and the pill's fallback all repeat: one
# JSON line to the socket, one JSON line back. Returns the parsed dict, or
# None if the socket is unreachable or the reply isn't JSON.

def request(socket_path, payload, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(socket_path)
        conn.sendall(json.dumps(payload).encode() + b"\n")
        buf = b""
        while b"\n" not in buf:
            chunk = conn.recv(65536)
            if not chunk:
                break
            buf += chunk
        conn.close()
        return json.loads(buf.decode())
    except (OSError, ValueError):
        return None


def read_status(status_path):
    """Read and parse status.json, or None. The daemon-less fallback path."""
    try:
        with open(status_path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None
