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

cat > "$RD/config.json" <<EOF
{"poll_interval": 1, "owner_uid": $(id -u),
 "scan_roots": ["$FIX"], "index_min_bytes": 4096}
EOF

BYEBYTE_RUNTIME_DIR=$RD BYEBYTE_STATE_DIR=$RD/state \
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

echo "SMOKE OK"
