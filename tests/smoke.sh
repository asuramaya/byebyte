#!/usr/bin/env bash
# Boot the daemon against the real mounts as an unprivileged user,
# assert the status.json shape, poke the socket (including hostile
# input), and exercise the CLI. House tradition: make smoke.
set -euo pipefail
cd "$(dirname "$0")/.."

RD=$(mktemp -d)
trap 'kill "${DPID:-0}" 2>/dev/null || true; rm -rf "$RD"' EXIT

# fixture tree for the index: one pig, one runt — `why` must rank them
FIX=$RD/tree
mkdir -p "$FIX/big" "$FIX/small"
dd if=/dev/zero of="$FIX/big/blob" bs=1024 count=2048 2>/dev/null
dd if=/dev/zero of="$FIX/small/tiny" bs=1024 count=16 2>/dev/null

# fixture "home" for the M3 registry — NEVER a real path, always $FIX/home,
# fed to the daemon via BYEBYTE_TEST_HOME (honored only when non-root)
HOME_FIX=$FIX/home
mkdir -p "$HOME_FIX/.cache/huggingface/hub/models--test--x"
dd if=/dev/zero of="$HOME_FIX/.cache/huggingface/hub/models--test--x/blob" \
    bs=1024 count=1024 2>/dev/null
mkdir -p "$HOME_FIX/proj-with-marker/node_modules/dep"
: > "$HOME_FIX/proj-with-marker/package.json"
dd if=/dev/zero of="$HOME_FIX/proj-with-marker/node_modules/dep/file.js" \
    bs=1024 count=64 2>/dev/null
mkdir -p "$HOME_FIX/proj-without-marker/node_modules/dep"
dd if=/dev/zero of="$HOME_FIX/proj-without-marker/node_modules/dep/file.js" \
    bs=1024 count=64 2>/dev/null

cat > "$RD/config.json" <<EOF
{"poll_interval": 1, "owner_uid": $(id -u),
 "scan_roots": ["$FIX"], "index_min_bytes": 4096}
EOF

BYEBYTE_RUNTIME_DIR=$RD BYEBYTE_STATE_DIR=$RD/state BYEBYTE_TEST_HOME=$HOME_FIX \
    python3 bin/byebyted --config "$RD/config.json" &
DPID=$!

for _ in $(seq 1 40); do
    [ -s "$RD/status.json" ] && break
    sleep 0.25
done
[ -s "$RD/status.json" ] || { echo "SMOKE FAIL: no status.json"; exit 1; }

python3 - "$RD/status.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["v"] == 1, "bad version"
assert doc["daemon"]["version"], "no daemon version"
assert isinstance(doc["mounts"], list) and doc["mounts"], "no mounts"
for m in doc["mounts"]:
    for key in ("mountpoint", "fstype", "total", "free", "effective_free",
                "burn_bps", "eta_seconds", "state"):
        assert key in m, f"mount missing {key}"
    assert m["state"] in ("ok", "warn", "hot", "edquot"), m["state"]
    assert m["effective_free"] <= m["free"], "effective_free > free"
print("shape ok:", len(doc["mounts"]), "mounts")
PY

python3 - "$RD/control.sock" <<'PY'
import json, socket, sys

def ask(payload):
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    c.settimeout(5)
    c.connect(sys.argv[1])
    c.sendall(payload)
    buf = b""
    while b"\n" not in buf:
        chunk = c.recv(65536)
        if not chunk:
            break
        buf += chunk
    c.close()
    return json.loads(buf.decode())

assert ask(b'{"cmd":"ping"}\n')["ok"] is True, "ping failed"
assert "mounts" in ask(b'{"cmd":"status"}\n'), "status failed"
# hostile input must answer with an error, never crash the daemon
assert "error" in ask(b'not json at all\n'), "garbage not rejected"
assert "error" in ask(b'{"cmd":"rm -rf /"}\n'), "unknown cmd not rejected"
assert ask(b'{"cmd":"ping"}\n')["ok"] is True, "daemon died after abuse"
print("socket ok: ping, status, hostile input survived")
PY

BYEBYTE_RUNTIME_DIR=$RD python3 bin/byebyte status | grep -q "free" \
    || { echo "SMOKE FAIL: CLI status empty"; exit 1; }
BYEBYTE_RUNTIME_DIR=$RD python3 bin/byebyte status --json | python3 -c \
    "import json,sys; json.load(sys.stdin)" \
    || { echo "SMOKE FAIL: CLI json invalid"; exit 1; }

# --- M2: the index — scan the fixture, why ranks the pig, blame sees growth
python3 - "$RD" "$FIX" <<'PY'
import json, os, socket, sys, time

rd, fix = sys.argv[1], sys.argv[2]

def ask(obj):
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    c.settimeout(10)
    c.connect(os.path.join(rd, "control.sock"))
    c.sendall(json.dumps(obj).encode() + b"\n")
    buf = b""
    while b"\n" not in buf:
        chunk = c.recv(65536)
        if not chunk:
            break
        buf += chunk
    c.close()
    return json.loads(buf.decode())

def scan_and_wait():
    r = ask({"cmd": "scan"})
    assert r.get("started") or r.get("running"), r
    for _ in range(120):
        st = ask({"cmd": "status"})
        idx = st.get("index") or {}
        if not idx.get("scanning") and idx.get("last_scan"):
            return idx["last_scan"]
        time.sleep(0.25)
    raise AssertionError("scan never finished")

scan_and_wait()
why = ask({"cmd": "why", "path": fix, "limit": 10})
assert "rows" in why and why["rows"], f"why empty: {why}"
assert why["rows"][0]["path"].endswith("/big"), why["rows"][0]
assert why["rows"][0]["bytes"] >= 2 * 1024 * 1024 * 0.9, why["rows"][0]
paths = [r["path"] for r in why["rows"]]
assert any(p.endswith("/small") for p in paths), paths

since = time.time()
time.sleep(1.1)
os.makedirs(f"{fix}/growth", exist_ok=True)
with open(f"{fix}/growth/spurt", "wb") as f:
    f.write(b"\0" * 3 * 1024 * 1024)
scan_and_wait()
blame = ask({"cmd": "blame", "since": since, "limit": 10})
assert "rows" in blame, blame
growth = [r for r in blame["rows"] if r["path"].endswith("/growth")]
assert growth and growth[0]["delta"] >= 3 * 1024 * 1024 * 0.9, blame["rows"]

# hostile index input: wrong types must answer with an error, not a crash
assert "error" in ask({"cmd": "why", "path": 123}), "bad why path accepted"
assert "error" in ask({"cmd": "blame", "since": "yesterday"}), "bad since accepted"
assert "error" in ask({"cmd": "blame", "since": -5}), "negative since accepted"
assert ask({"cmd": "ping"})["ok"] is True, "daemon died after index abuse"
print("index ok: scan, why ranks the pig, blame sees +3M growth, hostile input survived")
PY

# CLI verbs end-to-end (human output)
BYEBYTE_RUNTIME_DIR=$RD python3 bin/byebyte why "$FIX" | grep -q "/big" \
    || { echo "SMOKE FAIL: CLI why missing /big"; exit 1; }
BYEBYTE_RUNTIME_DIR=$RD python3 bin/byebyte blame --since 1h | grep -q "growth" \
    || { echo "SMOKE FAIL: CLI blame missing growth"; exit 1; }

# --- M3: purge — registry-gated, marker-gated, ledgered, hostile-input-proof
python3 - "$RD" "$FIX" <<'PY'
import json, os, socket, sys

rd, fix = sys.argv[1], sys.argv[2]

def ask(obj):
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    c.settimeout(10)
    c.connect(os.path.join(rd, "control.sock"))
    c.sendall(json.dumps(obj).encode() + b"\n")
    buf = b""
    while b"\n" not in buf:
        chunk = c.recv(65536)
        if not chunk:
            break
        buf += chunk
    c.close()
    return json.loads(buf.decode())

# dry-run: the marked node_modules shows up, the marker-less one never does
dry = ask({"cmd": "purge", "category": "project-artifacts", "dry_run": True})
assert "candidates" in dry, dry
paths = [c["path"] for c in dry["candidates"]]
assert any(p.endswith("proj-with-marker/node_modules") for p in paths), paths
assert not any(p.endswith("proj-without-marker/node_modules") for p in paths), paths
marked = next(c for c in dry["candidates"]
              if c["path"].endswith("proj-with-marker/node_modules"))
assert marked["bytes"] > 0, marked

# hf-hub dry-run finds the fixture model dir too
hf = ask({"cmd": "purge", "category": "hf-hub", "dry_run": True})
hf_paths = [c["path"] for c in hf["candidates"]]
assert any(p.endswith("models--test--x") for p in hf_paths), hf

# execute: it's actually gone, ledger has the line, the unmarked one survives
target = marked["path"]
executed = ask({"cmd": "purge", "category": "project-artifacts", "dry_run": False})
assert executed.get("freed_bytes", 0) > 0, executed
assert not os.path.exists(target), "purge --yes left the directory behind"
assert os.path.exists(os.path.join(fix, "home", "proj-without-marker",
                                   "node_modules")), "purge touched the unmarked one"

ledger_path = os.path.join(rd, "state", "ledger.jsonl")
with open(ledger_path) as f:
    lines = [json.loads(l) for l in f if l.strip()]
line = next(l for l in lines if l["path"] == target)
assert line["category"] == "project-artifacts" and line["status"] == "ok", line
print(f"purge ledger: {line}")

# hostile input: unknown category, a raw path, wrong type — all refused
assert "error" in ask({"cmd": "purge", "category": "raw-path"}), "unknown category accepted"
assert "error" in ask({"cmd": "purge", "category": "/etc/passwd"}), "raw path accepted"
assert "error" in ask({"cmd": "purge", "category": 123}), "non-string category accepted"
assert "error" in ask({"cmd": "purge", "category": "project-artifacts",
                       "dry_run": "yes"}), "non-bool dry_run accepted"
assert ask({"cmd": "ping"})["ok"] is True, "daemon died after purge abuse"
print("purge ok: registry-gated, marker-gated, ledger written, hostile input survived")
PY

# purge --all exits non-zero by design (the refusal IS the success case),
# so capture output first — piping straight into grep under pipefail would
# report the CLI's expected exit(1) as a grep failure
out=$(BYEBYTE_RUNTIME_DIR=$RD python3 bin/byebyte purge --all 2>&1) || true
echo "$out" | grep -q "one category per act" \
    || { echo "SMOKE FAIL: purge --all not refused"; exit 1; }

# --- M3: ghosts — a child holds an unlinked fd open, ghosts names it, then it's gone
python3 - "$RD" <<'PY'
import json, os, socket, subprocess, sys, time

rd = sys.argv[1]

def ask(obj):
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    c.settimeout(10)
    c.connect(os.path.join(rd, "control.sock"))
    c.sendall(json.dumps(obj).encode() + b"\n")
    buf = b""
    while b"\n" not in buf:
        chunk = c.recv(65536)
        if not chunk:
            break
        buf += chunk
    c.close()
    return json.loads(buf.decode())

child = subprocess.Popen([sys.executable, "-c", (
    "import os, tempfile, time\n"
    f"f = tempfile.NamedTemporaryFile(delete=False, dir={rd!r})\n"
    "f.write(b'\\0' * 123456)\n"
    "f.flush()\n"
    "os.unlink(f.name)\n"
    "time.sleep(30)\n"
)])
try:
    holder = None
    for _ in range(40):
        doc = ask({"cmd": "ghosts"})
        holder = next((h for h in doc["holders"] if h["pid"] == child.pid), None)
        if holder:
            break
        time.sleep(0.25)
    assert holder is not None, f"ghosts never saw pid {child.pid}: {doc}"
    assert holder["bytes"] >= 123456 * 0.9, holder
    assert holder["fds"] >= 1, holder
finally:
    child.kill()
    child.wait()

gone = False
for _ in range(40):
    doc = ask({"cmd": "ghosts"})
    if not any(h["pid"] == child.pid for h in doc["holders"]):
        gone = True
        break
    time.sleep(0.25)
assert gone, f"ghost for pid {child.pid} outlived the killed process"
assert ask({"cmd": "ping"})["ok"] is True, "daemon died during ghosts test"
print(f"ghosts ok: named pid {child.pid} holding {holder['bytes']}B, gone after kill")
PY

echo "SMOKE OK"
