#!/usr/bin/env bash
# Boot the daemon against the real mounts as an unprivileged user,
# assert the status.json shape, poke the socket (including hostile
# input), and exercise the CLI. House tradition: make smoke.
set -euo pipefail
cd "$(dirname "$0")/.."

# Four of byebyted's test-only escape hatches (BYEBYTE_TEST_HOME,
# BYEBYTE_TEST_BOOT, the ballast_bytes config override, BYEBYTE_TEST_TOCTOU_DELAY)
# are non-root-only BY DESIGN — the real daemon must never let an env var or
# config value redirect where a privileged process touches disk, or slow down
# its own act loop for anyone but a test harness. That's correct and stays
# untouched; it just means `sudo make smoke` can't point root at these
# fixtures, so those specific sections relax to real-data-agnostic assertions
# (still meaningful, just not fixture-exact) when run as root.
ROOT_SMOKE=0
[ "$(id -u)" -eq 0 ] && ROOT_SMOKE=1

RD=$(mktemp -d)
# burn needs a REAL disk-backed path: /proc/pid/io's write_bytes only moves
# for actual block-layer I/O — tmpfs (what $RD/mktemp default to here) never
# touches it, so the fixture data file lives under /var/tmp instead.
BURN_FIX=$(mktemp -d --tmpdir=/var/tmp byebyte-smoke-burn.XXXXXX)
# a GENUINELY cross-device root for the TOCTOU re-verification below (msg
# 3205's second finding): 5f81f00's revalidate-before-delete work was
# reasoned against a walk rooted at "/", and 9e71be7 now lets the indexer
# (and, via scan_roots below, purge's own detectors) walk a tmpfs root
# too. "The logic may well still hold" is not the same statement as it
# holding — /dev/shm is real, world-writable tmpfs on every Linux box,
# confirmed a different device from both / and /tmp (alfred's own
# stat -c '%d %n': 64513 /, 48 /tmp, 27 /dev/shm), so this is never an
# accident of where $RD happened to land.
SHM_FIX=$(mktemp -d --tmpdir=/dev/shm byebyte-smoke-shm.XXXXXX)

# ONE trap, registered ONCE, covering every resource this script can ever
# hold -- including ones the btrfs/reserve sections below don't set up
# until much later. A trap registered only at each section's own success
# path (the previous shape here, and the shape attack_socket.py's leak
# also had) never fires on a failing assertion: `set -e` exits before
# reaching that cleanup call, and the loop device/mount survives the
# process (alfred, msg 3245 -- his own `sudo make smoke` run left a
# mounted loop device and 106M of stale fixtures behind this exact way,
# worse than a plain leaked directory, on the real machine). BTRFS_LOOPDEV
# and RESERVE_LOOPDEV are pre-declared empty here so later `set -u`
# references are always safe, and so this ONE function can tell "never
# ran" from "ran and is still mounted" regardless of when in the script's
# lifetime it fires.
BTRFS_LOOPDEV=""
RESERVE_LOOPDEV=""
_cleanup_all() {
    # `set +e` for this whole function, not `|| true` sprinkled per line --
    # found the hard way (alfred, msg 3249): BURN_FIX survived a real run
    # because this function is REDUNDANTLY called at actual script exit
    # even when the btrfs/reserve sections already tore themselves down on
    # their own success path (they reset *_LOOPDEV to "" but never reset
    # *_IMG/*_MNT) -- so `rmdir "$BTRFS_MNT"` here ran a SECOND time against
    # an already-removed directory, failed, and -- being the last command
    # actually executed in its `[ -n ] && rmdir ...` list -- triggered set -e
    # and killed this function before it ever reached the final rm -rf.
    # Reproduced directly: an already-removed dir's rmdir failing here does
    # abort the function early under set -e, confirmed with an isolated
    # repro before trusting this diagnosis. A cleanup function's whole job
    # is best-effort teardown of things that may already be half-gone --
    # every command in it failing is an expected, ordinary outcome, never a
    # reason to abandon the rest of the cleanup.
    set +e
    # `kill "${DPID:-0}"` (the original form here) is a real hazard, not just
    # an unguarded failure: if DPID is ever unset, that expands to `kill 0`,
    # and pid 0 means "every process in the caller's own process group" --
    # signaling this whole script, not a no-op. Never reachable in the
    # ordinary run (DPID is set right after the daemon starts, long before
    # anything here could fail), but a trap fires on EVERY exit path,
    # including ones before that point, so it's real and worth naming.
    [ -n "${DPID:-}" ] && kill "$DPID" 2>/dev/null
    if [ -n "$BTRFS_LOOPDEV" ]; then
        sudo -n umount "${BTRFS_MNT:-}" 2>/dev/null
        sudo -n losetup -d "$BTRFS_LOOPDEV" 2>/dev/null
    fi
    [ -n "${BTRFS_IMG:-}" ] && rm -f "$BTRFS_IMG" 2>/dev/null
    [ -n "${BTRFS_MNT:-}" ] && rmdir "$BTRFS_MNT" 2>/dev/null
    if [ -n "$RESERVE_LOOPDEV" ]; then
        sudo -n umount "${EXT4_MNT:-}" 2>/dev/null
        sudo -n losetup -d "$RESERVE_LOOPDEV" 2>/dev/null
    fi
    [ -n "${EXT4_IMG:-}" ] && rm -f "$EXT4_IMG" 2>/dev/null
    [ -n "${EXT4_MNT:-}" ] && rmdir "$EXT4_MNT" 2>/dev/null
    [ -n "${RESERVE_STATE:-}" ] && rm -rf "$RESERVE_STATE" 2>/dev/null
    rm -rf "$RD" "$BURN_FIX" "$SHM_FIX" 2>/dev/null
    return 0
}
trap '_cleanup_all' EXIT
if [ "$(stat -c '%d' "$RD")" = "$(stat -c '%d' "$SHM_FIX")" ]; then
    echo "SMOKE FAIL: SHM_FIX is not actually a different device from RD -- the cross-device TOCTOU test would be meaningless here"
    exit 1
fi

# fixture tree for the index: one pig, one runt — `why` must rank them
FIX=$RD/tree
mkdir -p "$FIX/big" "$FIX/small"
dd if=/dev/zero of="$FIX/big/blob" bs=1024 count=2048 2>/dev/null
dd if=/dev/zero of="$FIX/small/tiny" bs=1024 count=16 2>/dev/null

# a SIBLING of $FIX, deliberately outside scan_roots, fed to the daemon as
# its own tmpfs_mounts entry below -- proves _index_roots() actually unions
# tmpfs_mounts into what gets walked (the real bug: DEFAULTS["scan_roots"]
# is ["/"], a tmpfs mount is a different device, and the indexer used to
# skip any subtree on a different device outright -- see ruling ddccc9be,
# live-verified as /tmp being invisible to `why` on the operator's own box
# despite `status` correctly showing it burning 733.7M/day)
TMPFS_FIX=$RD/tmpfs_fixture
mkdir -p "$TMPFS_FIX/ram_blob_dir"
dd if=/dev/zero of="$TMPFS_FIX/ram_blob_dir/blob" bs=1024 count=512 2>/dev/null

# project-artifacts fixture ON the real cross-device root ($SHM_FIX), for
# the TOCTOU re-verification below. UNMARKED for now, same reason as
# proj-toctou below: a marker from the start would make the earlier real
# purge call (which acts on every candidate detect() finds) delete it as
# collateral before the race test ever runs.
mkdir -p "$SHM_FIX/proj-toctou-shm/node_modules/dep"
dd if=/dev/zero of="$SHM_FIX/proj-toctou-shm/node_modules/dep/file.js" \
    bs=1024 count=64 2>/dev/null

# declare's own fixtures: a legit scratch target (happy path) and a
# separate one held back for declare's own TOCTOU race, same reasoning as
# proj-toctou above. Live under SHM_FIX, not FIX -- FIX is $RD/tree, and RD
# doubles as RUNTIME_DIR for this whole harness (a test-only convenience;
# no real deployment nests scan_roots inside its own /run/byebyte), so
# anything under FIX trips declare()'s OWN correct own-runtime/state-dir
# refusal for a reason that has nothing to do with what these two fixtures
# are for. SHM_FIX has no such collision.
mkdir -p "$SHM_FIX/declare_target/dep"
dd if=/dev/zero of="$SHM_FIX/declare_target/dep/blob" bs=1024 count=32 2>/dev/null
mkdir -p "$SHM_FIX/declare_toctou"
dd if=/dev/zero of="$SHM_FIX/declare_toctou/blob" bs=1024 count=32 2>/dev/null
# declare's own version of the verify-deleted fixture, see the comment
# where proj-verify-fail is created for what this proves and why
mkdir -p "$SHM_FIX/declare_verify_fail/locked"
dd if=/dev/zero of="$SHM_FIX/declare_verify_fail/locked/blob" bs=1024 count=32 2>/dev/null

# fixture "home" for the M3 registry — NEVER a real path, always $FIX/home,
# fed to the daemon via BYEBYTE_TEST_HOME (honored only when non-root)
HOME_FIX=$FIX/home
mkdir -p "$HOME_FIX/.cache/huggingface/hub/models--test--x"
dd if=/dev/zero of="$HOME_FIX/.cache/huggingface/hub/models--test--x/blob" \
    bs=1024 count=1024 2>/dev/null
# a real descendant of home_fix, for declare's own "must NOT over-refuse
# anything actually inside $HOME" check — dedicated rather than reusing
# another test's fixture, so it doesn't depend on test ordering or on
# something else having left it untouched
mkdir -p "$HOME_FIX/declare_descendant_ok"
dd if=/dev/zero of="$HOME_FIX/declare_descendant_ok/blob" bs=1024 count=8 2>/dev/null
mkdir -p "$HOME_FIX/proj-with-marker/node_modules/dep"
: > "$HOME_FIX/proj-with-marker/package.json"
dd if=/dev/zero of="$HOME_FIX/proj-with-marker/node_modules/dep/file.js" \
    bs=1024 count=64 2>/dev/null
mkdir -p "$HOME_FIX/proj-without-marker/node_modules/dep"
dd if=/dev/zero of="$HOME_FIX/proj-without-marker/node_modules/dep/file.js" \
    bs=1024 count=64 2>/dev/null
# a THIRD copy, UNMARKED for now, held back for the TOCTOU test below --
# the marker is written there only when that test is ready to use it. If it
# carried a marker from the start, the earlier real purge call above (which
# acts on every project-artifacts candidate detect() finds, not just the one
# it asserts about) would delete it as collateral damage before this test
# ever runs.
mkdir -p "$HOME_FIX/proj-toctou/node_modules/dep"
dd if=/dev/zero of="$HOME_FIX/proj-toctou/node_modules/dep/file.js" \
    bs=1024 count=64 2>/dev/null

# a FOURTH copy, for proving purge/declare actually VERIFY a delete rather
# than trusting _rm_tree's own silence (msg 3234's bug). locked/ gets its
# write bit stripped at test time -- os.unlink inside it then fails with
# EACCES, which _walk_delete's own per-entry `except OSError: continue`
# swallows by design, so this reliably reproduces "delete() returned
# without raising, but nothing was actually deleted" without needing root
# or a real systemd sandbox.
mkdir -p "$HOME_FIX/proj-verify-fail/node_modules/locked"
dd if=/dev/zero of="$HOME_FIX/proj-verify-fail/node_modules/locked/blob" \
    bs=1024 count=32 2>/dev/null

# fixture /boot for the kernels verb — NEVER the real /boot. Includes the
# actually-running kernel (so we can prove it's still refused as a
# candidate even though it's "installed") plus a fake newest and a fake old.
BOOT_FIX=$RD/boot
mkdir -p "$BOOT_FIX"
touch "$BOOT_FIX/vmlinuz-$(uname -r)"
touch "$BOOT_FIX/vmlinuz-1.0.0-fakeold-generic"
touch "$BOOT_FIX/vmlinuz-9.9.9-fakenew-generic"

# the ballast_bytes test override is non-root-only by design (root must
# never let it redirect a real build) — under root it's silently ignored
# and byebyted would try to build the real ballast_gb-sized (multi-GB, by
# default) reserve at startup instead. Disable ballast outright under root
# rather than risk that real allocation tripping this box's tmpfs quota.
BALLAST_CFG='"ballast_bytes": 1048576'
[ "$ROOT_SMOKE" -eq 1 ] && BALLAST_CFG='"ballast_gb": 0'

# WARNING before you add a category here: owner_uid: $(id -u) reads as
# hermetic and isn't -- under `sudo make smoke` it's 0, so an ARMED
# category resolving through _resolve_owner_home() (hf-hub, pip-cache,
# uv-cache, thumbnails -- anything routed through _detect_cache_dir) acts
# on root's own real home, not a fixture (BYEBYTE_TEST_HOME is correctly
# refused under root, by design). hf-hub is the only one armed today, and
# it's only safe from the sweep test's own root_smoke branch skipping the
# real-delete path outright -- see that comment (search
# "NOT exercised further under root") for the live incident that found
# this. Adding a second category here without the identical guard risks
# deleting a REAL user's real cache under a root smoke run.
cat > "$RD/config.json" <<EOF
{"poll_interval": 1, "owner_uid": $(id -u),
 "scan_roots": ["$FIX", "$SHM_FIX"], "tmpfs_mounts": ["$TMPFS_FIX"],
 "index_min_bytes": 4096, $BALLAST_CFG,
 "sweep_categories": ["hf-hub"]}
EOF

BYEBYTE_RUNTIME_DIR=$RD BYEBYTE_STATE_DIR=$RD/state BYEBYTE_TEST_HOME=$HOME_FIX \
    BYEBYTE_TEST_BOOT=$BOOT_FIX \
    BYEBYTE_TEST_TOCTOU_DELAY=0.3 \
    python3 src/bin/byebyted --config "$RD/config.json" &
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
assert "available" in doc["burn"] and "top_paths" in doc["burn"], doc.get("burn")
assert isinstance(doc["burn"]["top_paths"], list), doc["burn"]
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

BYEBYTE_RUNTIME_DIR=$RD python3 src/bin/byebyte status | grep -q "free" \
    || { echo "SMOKE FAIL: CLI status empty"; exit 1; }
BYEBYTE_RUNTIME_DIR=$RD python3 src/bin/byebyte status --json | python3 -c \
    "import json,sys; json.load(sys.stdin)" \
    || { echo "SMOKE FAIL: CLI json invalid"; exit 1; }

# --- M2: the index — scan the fixture, why ranks the pig, blame sees growth
python3 - "$RD" "$FIX" "$TMPFS_FIX" <<'PY'
import json, os, socket, sys, time

rd, fix, tmpfs_fix = sys.argv[1], sys.argv[2], sys.argv[3]

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

# tmpfs_mounts union: tmpfs_fix is a SIBLING of fix, outside scan_roots --
# only reachable at all if _index_roots() actually unions tmpfs_mounts in.
# scan_and_wait() above already covers it, since _scan_all() walks every
# root from one call (ruling ddccc9be / c116036c: why /tmp used to answer
# "nothing above the index threshold" on the operator's real box for
# exactly this reason -- the index never had this root at all)
tmpfs_why = ask({"cmd": "why", "path": tmpfs_fix, "limit": 10})
assert tmpfs_why.get("total") and tmpfs_why["total"] >= 512 * 1024 * 0.9, \
    f"tmpfs_mounts union failed -- why found nothing under {tmpfs_fix}: {tmpfs_why}"
assert "rows" in tmpfs_why and tmpfs_why["rows"], f"tmpfs why empty: {tmpfs_why}"
assert tmpfs_why["rows"][0]["path"].endswith("ram_blob_dir"), tmpfs_why["rows"][0]

# hostile index input: wrong types must answer with an error, not a crash
assert "error" in ask({"cmd": "why", "path": 123}), "bad why path accepted"
assert "error" in ask({"cmd": "blame", "since": "yesterday"}), "bad since accepted"
assert "error" in ask({"cmd": "blame", "since": -5}), "negative since accepted"
assert ask({"cmd": "ping"})["ok"] is True, "daemon died after index abuse"
print("index ok: scan, why ranks the pig, blame sees +3M growth, hostile input survived")
PY

# CLI verbs end-to-end (human output)
BYEBYTE_RUNTIME_DIR=$RD python3 src/bin/byebyte why "$FIX" | grep -q "/big" \
    || { echo "SMOKE FAIL: CLI why missing /big"; exit 1; }
BYEBYTE_RUNTIME_DIR=$RD python3 src/bin/byebyte blame --since 1h | grep -q "growth" \
    || { echo "SMOKE FAIL: CLI blame missing growth"; exit 1; }

# --- M3: purge — registry-gated, marker-gated, ledgered, hostile-input-proof
python3 - "$RD" "$FIX" "$ROOT_SMOKE" <<'PY'
import json, os, socket, sys

rd, fix, root_smoke = sys.argv[1], sys.argv[2], sys.argv[3] == "1"

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

# hf-hub dry-run finds the fixture model dir too — except under root,
# where _resolve_owner_home() correctly refuses BYEBYTE_TEST_HOME (by
# design) and reads the REAL owner's real home instead. dry_run is
# read-only either way, so this is still safe; it just can't be fixture-exact
hf = ask({"cmd": "purge", "category": "hf-hub", "dry_run": True})
if root_smoke:
    assert isinstance(hf.get("candidates"), list), hf
else:
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
line = next(l for l in lines if l["target"] == target)
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
out=$(BYEBYTE_RUNTIME_DIR=$RD python3 src/bin/byebyte purge --all 2>&1) || true
echo "$out" | grep -q "one category per act" \
    || { echo "SMOKE FAIL: purge --all not refused"; exit 1; }

# --- M3.1: TOCTOU — a candidate whose marker vanishes between detect() and
# delete() must be SKIPPED, not deleted. The daemon was started above with
# BYEBYTE_TEST_TOCTOU_DELAY=0.3, pausing between detect() and the act loop so
# this window is real and reproducible instead of raced blind (thread d4c05b6e:
# _delete_tree_entry used to hand candidate["path"] straight to _rm_tree with
# no re-check at all).
if [ "$ROOT_SMOKE" -eq 1 ]; then
    echo "toctou test skipped under root: BYEBYTE_TEST_TOCTOU_DELAY is refused for root by design (see the root-hatch note above), so there is no window to land the race in"
else
python3 - "$RD" "$HOME_FIX" <<'PY'
import json, os, socket, sys, threading, time

rd, home_fix = sys.argv[1], sys.argv[2]

def ask(obj, timeout=10):
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    c.settimeout(timeout)
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

target = os.path.join(home_fix, "proj-toctou", "node_modules")
marker = os.path.join(home_fix, "proj-toctou", "package.json")
assert os.path.isdir(target), "toctou fixture missing before the race"

# the marker goes in here, not at fixture-setup time -- see the comment
# where proj-toctou is created
open(marker, "w").close()

# sanity: detect() must see it as a real candidate before the rug gets pulled
dry = ask({"cmd": "purge", "category": "project-artifacts", "dry_run": True})
paths = [c["path"] for c in dry["candidates"]]
assert target in paths, f"toctou fixture not detected: {paths}"

result = {}
def run_purge():
    result["doc"] = ask({"cmd": "purge", "category": "project-artifacts",
                         "dry_run": False}, timeout=15)

t = threading.Thread(target=run_purge)
t.start()
# land inside byebyted's own 0.3s detect-to-act pause -- generous relative to
# a socket round-trip plus a five-entry detect() on this fixture
time.sleep(0.05)
os.unlink(marker)
t.join(timeout=15)
assert not t.is_alive(), "purge call never returned"

doc = result["doc"]
item = next((r for r in doc["results"] if r["path"] == target), None)
assert item is not None, f"toctou candidate missing from results: {doc}"
assert item.get("skipped") is True and item["ok"] is False, \
    f"stale candidate was not skipped: {item}"
assert os.path.isdir(target), \
    "revalidate() let a stale candidate through -- directory was deleted"

ledger_path = os.path.join(rd, "state", "ledger.jsonl")
with open(ledger_path) as f:
    lines = [json.loads(l) for l in f if l.strip()]
line = next(l for l in lines if l["target"] == target)
assert line["status"] == "skipped", line

assert ask({"cmd": "ping"})["ok"] is True, "daemon died during the TOCTOU race"
print("toctou ok: marker pulled mid-purge -> revalidate() skipped it, "
      "directory survived, ledgered as skipped")
PY
fi

# --- M3.2: TOCTOU on a GENUINELY cross-device root (msg 3205's second
# finding). 5f81f00's revalidate-before-delete, _rm_tree's never-cross-
# devices rule, and _verify_inside's containment check were all reasoned
# against a walk rooted at "/" -- after 9e71be7 the indexer (and, via
# scan_roots including $SHM_FIX above, purge's own detectors) walk a tmpfs
# root too. "The logic may well still hold" was alfred's own words for why
# that's not good enough on its own -- same race as M3.1, same assertions,
# against a candidate on $SHM_FIX (/dev/shm, confirmed a different device
# from $RD at the top of this script, not an accident of where mktemp
# happened to put either one).
if [ "$ROOT_SMOKE" -eq 1 ]; then
    echo "cross-device toctou test skipped under root, same reason as M3.1"
else
python3 - "$RD" "$SHM_FIX" <<'PY'
import json, os, socket, sys, threading, time

rd, shm_fix = sys.argv[1], sys.argv[2]

def ask(obj, timeout=10):
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    c.settimeout(timeout)
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

target = os.path.join(shm_fix, "proj-toctou-shm", "node_modules")
marker = os.path.join(shm_fix, "proj-toctou-shm", "package.json")
assert os.path.isdir(target), "cross-device toctou fixture missing before the race"
assert os.stat(target).st_dev != os.stat(rd).st_dev, \
    "SHM_FIX is not actually cross-device from RD -- this test proves nothing"

open(marker, "w").close()

dry = ask({"cmd": "purge", "category": "project-artifacts", "dry_run": True})
paths = [c["path"] for c in dry["candidates"]]
assert target in paths, f"cross-device toctou fixture not detected: {paths}"

result = {}
def run_purge():
    result["doc"] = ask({"cmd": "purge", "category": "project-artifacts",
                         "dry_run": False}, timeout=15)

t = threading.Thread(target=run_purge)
t.start()
time.sleep(0.05)
os.unlink(marker)
t.join(timeout=15)
assert not t.is_alive(), "purge call never returned"

doc = result["doc"]
item = next((r for r in doc["results"] if r["path"] == target), None)
assert item is not None, f"cross-device toctou candidate missing from results: {doc}"
assert item.get("skipped") is True and item["ok"] is False, \
    f"stale cross-device candidate was not skipped: {item}"
assert os.path.isdir(target), \
    "revalidate() let a stale cross-device candidate through -- directory was deleted"

ledger_path = os.path.join(rd, "state", "ledger.jsonl")
with open(ledger_path) as f:
    lines = [json.loads(l) for l in f if l.strip()]
line = next(l for l in lines if l["target"] == target)
assert line["status"] == "skipped", line

assert ask({"cmd": "ping"})["ok"] is True, "daemon died during the cross-device TOCTOU race"
print("cross-device toctou ok (/dev/shm, confirmed different device from RD): "
      "marker pulled mid-purge -> revalidate() skipped it, directory survived, "
      "ledgered as skipped")
PY
fi

# --- M4: declare — path-exact, category-free, compiled-in floor (msg 3205,
# msg 3214). The floor has three rules: (1) DERIVED — refuse $HOME itself or
# any ancestor of it; (2) DERIVED — refuse any mount point; (3) enumerated —
# the FHS system dirs neither of the above can derive. Tested against the
# fixture's own fake $HOME (BYEBYTE_TEST_HOME=$HOME_FIX) so rule 1 is
# exercised precisely (ancestor / equal / descendant), not against the real
# system's /home, which this sandbox may not even have permission to probe
# meaningfully. Gated on BYEBYTE_TEST_TOCTOU_DELAY same as M3.1/M3.2 —
# declare's own TOCTOU race needs the non-root-only pause to land inside a
# real window rather than racing it blind.
if [ "$ROOT_SMOKE" -eq 1 ]; then
    echo "declare test skipped under root, same reason as M3.1/M3.2"
else
python3 - "$RD" "$FIX" "$HOME_FIX" "$SHM_FIX" <<'PY'
import json, os, socket, sys, threading, time

rd, fix, home_fix, shm_fix = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

def ask(obj, timeout=10):
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    c.settimeout(timeout)
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

# rule 1, ancestor case: fix is a real ancestor of home_fix (home_fix ==
# fix/home) -- must be refused, and refused BY RULE 1 specifically, not by
# the "outside scan roots" envelope (fix IS a configured scan root, so the
# envelope would happily allow it; only the compiled-in floor stops this)
r = ask({"cmd": "declare", "path": fix, "dry_run": True})
assert "error" in r and "ancestor" in r["error"], f"ancestor-of-home not refused: {r}"

# rule 1, equal case
r = ask({"cmd": "declare", "path": home_fix, "dry_run": True})
assert "error" in r and "HOME" in r["error"], f"$HOME itself not refused: {r}"

# rule 1 must NOT over-refuse a real descendant of home -- only ancestors
# and home itself are denied, everything inside home is exactly what this
# verb exists to declare. Checked against _declare_denied_reason() DIRECTLY
# (import, not the live socket): this test's own RD doubles as BOTH
# RUNTIME_DIR and the ancestor of the whole fixture tree (FIX=$RD/tree),
# a test-harness convenience no real deployment would have -- declare()'s
# SEPARATE own-runtime/state-dir check would legitimately also fire for
# anything under $HOME_FIX here, for a reason that has nothing to do with
# rule 1. Importing isolates the one thing this assertion is actually
# about.
import importlib.util
from importlib.machinery import SourceFileLoader
# src/bin/byebyted has no .py suffix, so spec_from_file_location can't infer
# a loader from the extension -- hand it one explicitly (same pattern used
# further down this file for the loop-device fixture import).
loader = SourceFileLoader("byebyted_mod", "src/bin/byebyted")
spec = importlib.util.spec_from_loader("byebyted_mod", loader)
byebyted_mod = importlib.util.module_from_spec(spec)
loader.exec_module(byebyted_mod)
os.environ["BYEBYTE_TEST_HOME"] = home_fix
descendant = os.path.join(home_fix, "declare_descendant_ok")
reason = byebyted_mod._declare_denied_reason(
    os.path.realpath(descendant), {"owner_uid": os.getuid()})
assert reason is None, f"rule 1 wrongly refused a real descendant of $HOME: {reason}"

# rule 2, derived: any mount point, tested against the real /dev/shm (not
# this fixture's own SHM_FIX subdirectory, which isn't a mount point
# itself -- /dev/shm always is, on every Linux box, CI included)
r = ask({"cmd": "declare", "path": "/dev/shm", "dry_run": True})
assert "error" in r and "mount point" in r["error"], f"a real mount point not refused: {r}"

# rule 3, the enumerated remainder -- /etc is not an ancestor of this
# fixture's fake $HOME and is not a mount point on most boxes, so only the
# hand-written list catches it
r = ask({"cmd": "declare", "path": "/etc", "dry_run": True})
assert "error" in r and "compiled-in floor" in r["error"], \
    f"/etc not refused by the enumerated floor: {r}"

# happy path: a real, legitimate scratch target -- dry-run, then --yes
target = os.path.join(shm_fix, "declare_target")
dry = ask({"cmd": "declare", "path": target, "dry_run": True})
assert "error" not in dry, dry
assert dry["bytes"] > 0 and dry["is_dir"] is True, dry
real_act = ask({"cmd": "declare", "path": target, "dry_run": False})
assert real_act.get("ok") is True, real_act
assert not os.path.exists(target), "declare --yes left the directory behind"
ledger_path = os.path.join(rd, "state", "ledger.jsonl")
with open(ledger_path) as f:
    lines = [json.loads(l) for l in f if l.strip()]
line = next(l for l in lines if l["target"] == target)
assert line["category"] == "declare" and line["status"] == "ok", line

# TOCTOU: swap the declared path for a symlink DURING byebyted's own
# detect-to-act pause (BYEBYTE_TEST_TOCTOU_DELAY=0.3, same window as
# M3.1/M3.2) -- the swap must land inside declare()'s own re-check, not
# before the call even starts, or this proves nothing about the race
# (declare's upfront `not os.path.islink(path)` guard would catch an
# already-swapped path trivially and this test would never touch the
# window at all)
toctou_target = os.path.join(shm_fix, "declare_toctou")
elsewhere = os.path.join(shm_fix, "declare_toctou_elsewhere")
assert os.path.isdir(toctou_target), "declare toctou fixture missing before the race"

dry = ask({"cmd": "declare", "path": toctou_target, "dry_run": True})
assert "error" not in dry, f"toctou fixture not declarable before the race: {dry}"

result = {}
def run_declare():
    result["doc"] = ask({"cmd": "declare", "path": toctou_target,
                         "dry_run": False}, timeout=15)

t = threading.Thread(target=run_declare)
t.start()
# land inside byebyted's own 0.3s pause, same margin as M3.1/M3.2
time.sleep(0.05)
os.rename(toctou_target, elsewhere)
os.symlink(elsewhere, toctou_target)
t.join(timeout=15)
assert not t.is_alive(), "declare call never returned"

doc = result["doc"]
assert doc.get("skipped") is True and doc.get("ok") is False, \
    f"symlink swap mid-flight was not caught by revalidation: {doc}"
assert os.path.islink(toctou_target), \
    "declare deleted through a symlink its own revalidate() should have caught"

ledger_path = os.path.join(rd, "state", "ledger.jsonl")
with open(ledger_path) as f:
    lines = [json.loads(l) for l in f if l.strip()]
line = next(l for l in lines if l["target"] == toctou_target)
assert line["category"] == "declare" and line["status"] == "skipped", line

os.unlink(toctou_target)
os.rename(elsewhere, toctou_target)  # restore, tidy for anything reading fix's tree later

assert ask({"cmd": "ping"})["ok"] is True, "daemon died during declare's tests"
print("declare ok: derived home-ancestor/mount-point rules + enumerated "
      "floor all refuse correctly, a real descendant is never over-refused, "
      "happy path frees and ledgers, symlink swap refused outright")
PY
fi

# --- M3.5: verify-deleted — purge/sweep/declare must confirm a candidate is
# actually GONE before ledgering "ok", not trust that delete() returning
# without raising means it worked (msg 3234: ProtectSystem=strict made /tmp
# read-only to byebyted's real unit, _rm_tree's own per-entry `except
# OSError: continue` swallowed every resulting EROFS, and purge/declare both
# reported "freed" while deleting nothing at all, live on the operator's
# machine). Reproduced here without root or a real systemd sandbox: chmod a
# subdirectory read-only so os.unlink inside it fails with EACCES, the exact
# shape _walk_delete already tolerates per-entry by design. NON-ROOT ONLY --
# real root bypasses file permission bits entirely (that's what
# CAP_DAC_OVERRIDE is for), so this specific simulation can't reproduce
# anything under root; ROOT_SMOKE has its own coverage of the real
# capability grant elsewhere.
if [ "$ROOT_SMOKE" -eq 1 ]; then
    echo "verify-deleted test skipped under root: chmod-based permission failure doesn't apply to root, which bypasses file mode bits entirely (that's what CAP_DAC_OVERRIDE is for in the real unit)"
else
python3 - "$RD" "$HOME_FIX" "$SHM_FIX" <<'PY'
import json, os, socket, stat, sys

rd, home_fix, shm_fix = sys.argv[1], sys.argv[2], sys.argv[3]

def ask(obj, timeout=10):
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    c.settimeout(timeout)
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

# --- purge/project-artifacts side ---
target_dir = os.path.join(home_fix, "proj-verify-fail", "node_modules")
locked = os.path.join(target_dir, "locked")
marker = os.path.join(home_fix, "proj-verify-fail", "package.json")
assert os.path.isdir(locked), "verify-fail fixture missing before the test"
open(marker, "w").close()

dry = ask({"cmd": "purge", "category": "project-artifacts", "dry_run": True})
paths = [c["path"] for c in dry["candidates"]]
assert target_dir in paths, f"verify-fail fixture not detected: {paths}"

os.chmod(locked, stat.S_IRUSR | stat.S_IXUSR)  # r-x------: contents un-removable
try:
    real = ask({"cmd": "purge", "category": "project-artifacts", "dry_run": False})
finally:
    os.chmod(locked, stat.S_IRWXU)  # restore before any cleanup ever touches it

item = next((r for r in real["results"] if r["path"] == target_dir), None)
assert item is not None, f"verify-fail candidate missing from results: {real}"
assert item["ok"] is False, \
    f"purge reported ok on a delete that silently failed: {item}"
assert os.path.isdir(target_dir) and os.path.isdir(locked) \
    and os.path.exists(os.path.join(locked, "blob")), \
    "the locked subtree was not actually supposed to survive intact"

ledger_path = os.path.join(rd, "state", "ledger.jsonl")
with open(ledger_path) as f:
    lines = [json.loads(l) for l in f if l.strip()]
line = next(l for l in lines if l["target"] == target_dir)
assert line["status"] == "error", line
print("verify-deleted (purge) ok: a silently-failed _rm_tree is reported "
      "ok=False and ledgered error, not a false ok")

# --- declare side ---
d_target = os.path.join(shm_fix, "declare_verify_fail")
d_locked = os.path.join(d_target, "locked")
assert os.path.isdir(d_locked), "declare verify-fail fixture missing before the test"

dry = ask({"cmd": "declare", "path": d_target, "dry_run": True})
assert "error" not in dry, dry

os.chmod(d_locked, stat.S_IRUSR | stat.S_IXUSR)
try:
    real = ask({"cmd": "declare", "path": d_target, "dry_run": False})
finally:
    os.chmod(d_locked, stat.S_IRWXU)

assert real.get("ok") is False, \
    f"declare reported ok on a delete that silently failed: {real}"
assert os.path.isdir(d_target) and os.path.exists(os.path.join(d_locked, "blob")), \
    "the locked subtree was not actually supposed to survive intact"

ledger_path = os.path.join(rd, "state", "ledger.jsonl")
with open(ledger_path) as f:
    lines = [json.loads(l) for l in f if l.strip()]
line = next(l for l in lines if l["target"] == d_target)
assert line["status"] == "error", line
print("verify-deleted (declare) ok: same proof, same result")

assert ask({"cmd": "ping"})["ok"] is True, "daemon died during verify-deleted tests"
PY
fi

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

def ghost_for_pid(doc, pid):
    for g in doc["holders"]:
        h = next((h for h in g["holders"] if h["pid"] == pid), None)
        if h:
            return g, h
    return None, None

child = subprocess.Popen([sys.executable, "-c", (
    "import os, tempfile, time\n"
    f"f = tempfile.NamedTemporaryFile(delete=False, dir={rd!r})\n"
    "f.write(b'\\0' * 123456)\n"
    "f.flush()\n"
    "os.unlink(f.name)\n"
    "time.sleep(30)\n"
)])
try:
    ghost = holder = None
    for _ in range(40):
        doc = ask({"cmd": "ghosts"})
        ghost, holder = ghost_for_pid(doc, child.pid)
        if ghost:
            break
        time.sleep(0.25)
    assert ghost is not None, f"ghosts never saw pid {child.pid}: {doc}"
    assert ghost["bytes"] >= 123456 * 0.9, ghost
    assert holder["fds"] >= 1, holder
    ghost_bytes = ghost["bytes"]
finally:
    child.kill()
    child.wait()

gone = False
for _ in range(40):
    doc = ask({"cmd": "ghosts"})
    still, _ = ghost_for_pid(doc, child.pid)
    if still is None:
        gone = True
        break
    time.sleep(0.25)
assert gone, f"ghost for pid {child.pid} outlived the killed process"
assert ask({"cmd": "ping"})["ok"] is True, "daemon died during ghosts test"
print(f"ghosts ok: named pid {child.pid} holding {ghost_bytes}B, gone after kill")
PY

# --- V2.M1: ghosts dedup — one deleted file shared by two pids is ONE ghost
# with two holders, and its bytes are counted once, not twice
python3 - "$RD" <<'PY'
import json, os, socket, sys, tempfile, time

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

f = tempfile.NamedTemporaryFile(delete=False, dir=rd)
f.write(b"\0" * 65536)
f.flush()
os.unlink(f.name)

pid = os.fork()
if pid == 0:
    time.sleep(30)  # child: inherits the same fd/inode, holds it open
    os._exit(0)

try:
    match = None
    for _ in range(40):
        doc = ask({"cmd": "ghosts"})
        candidates = [g for g in doc["holders"]
                      if {h["pid"] for h in g["holders"]} >= {os.getpid(), pid}]
        if candidates:
            match = candidates[0]
            break
        time.sleep(0.25)
    assert match is not None, f"dedup ghost never saw both pids: {doc}"
    assert len(candidates) == 1, f"same inode double-counted: {candidates}"
    assert match["bytes"] >= 65536 * 0.9, match
    assert len(match["holders"]) == 2, match
finally:
    os.kill(pid, 9)
    os.waitpid(pid, 0)
    f.close()

assert ask({"cmd": "ping"})["ok"] is True, "daemon died during ghosts dedup test"
print(f"ghosts dedup ok: one ghost, {len(match['holders'])} holders, "
      f"{match['bytes']}B counted once")
PY

# --- V2.M2: btrfs truth — pure parsing first (always runs, no privilege),
# then a real loop-device fixture (skips cleanly without root/tooling)
python3 - <<'PY'
import importlib.util, sys
from importlib.machinery import SourceFileLoader

# src/bin/byebyted has no .py suffix, so spec_from_file_location can't infer a
# loader from the extension — hand it one explicitly. byebyted's own sutra
# bootstrap preamble (BOOTSTRAP.md) runs as part of exec_module below and
# puts src/share/byebyte/lib on sys.path itself, so `import sutra` inside it
# resolves without any help from this harness.
loader = SourceFileLoader("byebyted_mod", "src/bin/byebyted")
spec = importlib.util.spec_from_loader("byebyted_mod", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)

subvols = mod._parse_subvol_list(
    "ID 256 gen 10 top level 5 path live\n"
    "ID 257 gen 12 top level 5 path snap1\n")
assert subvols == {256: "live", 257: "snap1"}, subvols

qgroups = mod._parse_qgroup_show(
    "qgroupid         rfer         excl     max_rfer     max_excl \n"
    "--------         ----         ----     --------     -------- \n"
    "0/256        1073741824    536870912         none         none \n"
    "0/257         536870912    536870912         none         none \n")
assert qgroups == {256: {"referenced": 1073741824, "exclusive": 536870912},
                   257: {"referenced": 536870912, "exclusive": 536870912}}, qgroups

# a garbled/unexpected line is skipped, never fatal
assert mod._parse_subvol_list("not a subvolume line at all\n") == {}
assert mod._parse_qgroup_show("garbage\n") == {}

# `subvolume show`'s Parent UUID field: '-' (no parent) is not a snapshot,
# a real UUID is (V2.M3 root-run found `list -as` unreliable — this
# stabler, longer-documented field replaced it as the snapshot signal)
not_a_snap = mod._parse_subvol_show_parent_uuid(
    "live\n\tName: \t\t\tlive\n\tUUID: \t\t\tabc\n\tParent UUID: \t\t-\n")
assert not_a_snap == "-", not_a_snap
is_a_snap = mod._parse_subvol_show_parent_uuid(
    "snap1\n\tName: \t\t\tsnap1\n"
    "\tParent UUID: \t\tf47ac10b-58cc-4372-a567-0e02b2c3d479\n")
assert is_a_snap == "f47ac10b-58cc-4372-a567-0e02b2c3d479", is_a_snap
assert mod._parse_subvol_show_parent_uuid("garbage\n") is None
print("btrfs parsing ok: subvolume/qgroup/parent-uuid lines parsed, garbage lines skipped")
PY

# The live-mount section is gated on real capability (tools present AND
# passwordless sudo works), never inferred CI-vs-local: `sudo -n true`
# used to stand in for "am I in a constrained environment", and that proxy
# is inverted on the one environment that matters. A dev box typically has
# NEITHER passwordless sudo NOR btrfs-progs, so it skips harmlessly.
# GitHub-hosted runners typically have BOTH (passwordless sudo is the
# runner-user default, and ubuntu-latest ships btrfs-progs), so the old
# gate let CI alone attempt the real loop-device mount -- and CI's
# sandboxing doesn't support it, so it died there instead of skipping.
# Explicit and honest: never attempt the live mount under CI, regardless
# of what capability-probing would otherwise say.
btrfs_ready=1
for tool in losetup mkfs.btrfs btrfs; do
    command -v "$tool" >/dev/null 2>&1 || btrfs_ready=0
done
if [ -n "${CI:-}" ]; then
    echo "btrfs section: skipped (CI environment -- loop-device btrfs mounting" \
         "is not supported under GitHub Actions' sandboxing, confirmed by direct" \
         "reproduction; this is a real, disclosed coverage gap, not a false skip)"
elif [ "$btrfs_ready" -eq 1 ] && sudo -n true 2>/dev/null; then
    BTRFS_IMG=$(mktemp --tmpdir=/var/tmp byebyte-smoke-btrfs.XXXXXX.img)
    BTRFS_MNT=$(mktemp -d --tmpdir=/var/tmp byebyte-smoke-btrfs-mnt.XXXXXX)
    # explicit, immediate cleanup on the paths below, and resets
    # BTRFS_LOOPDEV to "" afterward so the top-level _cleanup_all trap's
    # own later attempt (its safety net for any path that doesn't reach
    # here, e.g. a failing assertion) finds nothing left to do
    cleanup_btrfs() {
        # every line guarded with || true: a cleanup function's own commands
        # failing (already unmounted, already detached) is ordinary, never a
        # reason for `set -e` to cut the rest of the cleanup short (found via
        # the identical bug one function up, _cleanup_all -- see its comment)
        [ -n "$BTRFS_LOOPDEV" ] && { sudo -n umount "$BTRFS_MNT" 2>/dev/null || true; }
        [ -n "$BTRFS_LOOPDEV" ] && { sudo -n losetup -d "$BTRFS_LOOPDEV" 2>/dev/null || true; }
        rm -f "$BTRFS_IMG" || true
        rmdir "$BTRFS_MNT" 2>/dev/null || true
        BTRFS_LOOPDEV=""
    }
    btrfs_live=0
    if truncate -s 300M "$BTRFS_IMG" \
        && BTRFS_LOOPDEV=$(sudo -n losetup --show -f "$BTRFS_IMG" 2>/dev/null) \
        && sudo -n mkfs.btrfs -q "$BTRFS_LOOPDEV" >/dev/null 2>&1 \
        && sudo -n mount "$BTRFS_LOOPDEV" "$BTRFS_MNT" 2>/dev/null; then
        btrfs_live=1
    fi
    if [ "$btrfs_live" -eq 1 ]; then
        sudo -n btrfs subvolume create "$BTRFS_MNT/live" >/dev/null
        dd if=/dev/zero of="$BTRFS_MNT/live/blob" bs=1M count=32 2>/dev/null
        sudo -n btrfs subvolume snapshot -r "$BTRFS_MNT/live" "$BTRFS_MNT/snap1" >/dev/null
        sudo -n rm -f "$BTRFS_MNT/live/blob"
        sudo -n btrfs quota enable "$BTRFS_MNT" >/dev/null 2>&1 || true
        sudo -n btrfs quota rescan -w "$BTRFS_MNT" >/dev/null 2>&1 || true

        # read as root, same as the real daemon always does in production
        sudo -n python3 - "$(pwd)/src/bin/byebyted" "$BTRFS_MNT" <<'PY'
import importlib.util, os, sys
from importlib.machinery import SourceFileLoader

daemon_path, mnt = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.dirname(daemon_path))
loader = SourceFileLoader("byebyted_mod", daemon_path)
spec = importlib.util.spec_from_loader("byebyted_mod", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)

info = mod.btrfs_info(mnt)
assert info["available"], info
assert info["snapshots"] >= 1, info
if info.get("quotas_enabled"):
    assert info.get("pinned_bytes") and info["pinned_bytes"] >= 32 * 1024 * 1024 * 0.9, info
    print(f"btrfs ok: {info['subvolumes']} subvol(s), {info['snapshots']} snapshot(s), "
          f"{info['pinned_bytes']}B pinned")
else:
    print(f"btrfs ok (quotas unavailable in this env): {info['subvolumes']} subvol(s), "
          f"{info['snapshots']} snapshot(s)")
PY
        cleanup_btrfs
    else
        cleanup_btrfs
        echo "btrfs section: skipped (loop/mkfs.btrfs/mount failed under sudo -n)"
    fi
else
    echo "btrfs section: skipped (no passwordless sudo, or btrfs-progs not installed" \
         "-- this is the normal local-dev-box case, not a CI concern)"
fi

# --- V3.M1: reserve — ext2/3/4 reserved-blocks, layer 3's reference verb.
# Same capability gate and same CI honesty as the btrfs section above (loop-
# device mounting is not supported under GitHub Actions' sandboxing,
# confirmed by direct reproduction there) -- never inferred, always explicit.
reserve_ready=1
for tool in tune2fs losetup mkfs.ext4; do
    command -v "$tool" >/dev/null 2>&1 || reserve_ready=0
done
if [ -n "${CI:-}" ]; then
    echo "reserve section: skipped (CI environment -- loop-device mounting is not" \
         "supported under GitHub Actions' sandboxing, same as the btrfs section" \
         "above; a real, disclosed coverage gap, not a false skip)"
elif [ "$reserve_ready" -eq 1 ] && sudo -n true 2>/dev/null; then
    EXT4_IMG=$(mktemp --tmpdir=/var/tmp byebyte-smoke-ext4.XXXXXX.img)
    EXT4_MNT=$(mktemp -d --tmpdir=/var/tmp byebyte-smoke-ext4-mnt.XXXXXX)
    RESERVE_STATE=$(mktemp -d --tmpdir=/var/tmp byebyte-smoke-reserve-state.XXXXXX)
    # explicit, immediate cleanup on the paths below, and resets
    # RESERVE_LOOPDEV to "" afterward so the top-level _cleanup_all trap's
    # own later attempt (its safety net for any path that doesn't reach
    # here, e.g. a failing assertion -- msg 3245, alfred's own `sudo make
    # smoke` run left a mounted loop device and 106M behind exactly this
    # way, since neither cleanup function was ever registered as a trap)
    # finds nothing left to do
    cleanup_reserve() {
        # every line guarded with || true -- see cleanup_btrfs's own comment
        [ -n "$RESERVE_LOOPDEV" ] && { sudo -n umount "$EXT4_MNT" 2>/dev/null || true; }
        [ -n "$RESERVE_LOOPDEV" ] && { sudo -n losetup -d "$RESERVE_LOOPDEV" 2>/dev/null || true; }
        rm -f "$EXT4_IMG" || true
        rmdir "$EXT4_MNT" 2>/dev/null || true
        rm -rf "$RESERVE_STATE" || true
        RESERVE_LOOPDEV=""
    }
    reserve_live=0
    if truncate -s 64M "$EXT4_IMG" \
        && RESERVE_LOOPDEV=$(sudo -n losetup --show -f "$EXT4_IMG" 2>/dev/null) \
        && sudo -n mkfs.ext4 -q "$RESERVE_LOOPDEV" >/dev/null 2>&1 \
        && sudo -n mount "$RESERVE_LOOPDEV" "$EXT4_MNT" 2>/dev/null; then
        reserve_live=1
    fi
    if [ "$reserve_live" -eq 1 ]; then
        # read as root, same as the real daemon always does in production
        sudo -n env BYEBYTE_STATE_DIR="$RESERVE_STATE" \
            python3 - "$(pwd)/src/bin/byebyted" "$EXT4_MNT" "$RESERVE_LOOPDEV" <<'PY'
import importlib.util, os, sys
from importlib.machinery import SourceFileLoader

daemon_path, mnt, dev = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, os.path.dirname(daemon_path))
loader = SourceFileLoader("byebyted_mod", daemon_path)
spec = importlib.util.spec_from_loader("byebyted_mod", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)

cfg = {"exclude_mounts": [], "tmpfs_mounts": [], "include_fstypes": ["ext4"]}

original = mod._tune2fs_reserved_percent(dev)
assert original is not None, "could not read the fixture's own reserved-blocks percent"

# dry-run: reports current without touching anything
dry = mod.reserve(mnt, 1, True, cfg)
assert dry.get("current_percent") == original, dry
assert dry.get("proposed_percent") == 1, dry
assert mod._tune2fs_reserved_percent(dev) == original, \
    "dry-run touched the filesystem"

# the compiled-in floor: 0% is refused even with dry_run=False, e2fsprogs'
# own silent acceptance of it is exactly why this guard has to exist here
refused = mod.reserve(mnt, 0, False, cfg)
assert "error" in refused, f"0% was not refused: {refused}"
assert mod._tune2fs_reserved_percent(dev) == original, \
    "a refused request still changed the filesystem"

# real apply: the reference measurement is statvfs itself, before and after
before = os.statvfs(mnt)
avail_before = before.f_bavail * before.f_frsize
real = mod.reserve(mnt, 1, False, cfg)
assert real.get("ok") is True, real
assert real["prior_percent"] == original, real
after_percent = mod._tune2fs_reserved_percent(dev)
# tolerance, not exact equality (alfred, msg 3236): tune2fs -m sets
# reserved blocks by INTEGER block-count truncation, so "1%" reads back as
# whatever percentage that many whole blocks actually are on THIS
# filesystem's block count -- 0.99% on a 512M image is correct behavior,
# not a bug. statvfs moving (below) is the real claim; this is a coarse
# sanity check that the requested value roughly landed, not the proof.
assert abs(after_percent - 1) < 0.5, \
    f"reserve asked for 1% but tune2fs now reports {after_percent}%"
after = os.statvfs(mnt)
avail_after = after.f_bavail * after.f_frsize
assert avail_after > avail_before, \
    "reserve reported ok but statvfs avail did not actually move"
assert real["avail_delta_bytes"] == avail_after - avail_before, real

# ledgered, with both the prior and new percent visible in the target
ledger_path = os.path.join(os.environ["BYEBYTE_STATE_DIR"], "ledger.jsonl")
with open(ledger_path) as f:
    lines = [__import__("json").loads(l) for l in f if l.strip()]
line = next(l for l in lines if l["category"] == "reserve" and "->1%" in l["target"])
assert line["status"] == "ok", line

# round trip back to the original -- byte-exact avail restoration, same
# proof method
restore = mod.reserve(mnt, original, False, cfg)
assert restore.get("ok") is True, restore
final = os.statvfs(mnt)
avail_final = final.f_bavail * final.f_frsize
assert avail_final == avail_before, \
    f"round trip did not restore byte-exact: {avail_before} -> {avail_final}"

# poll_mount() must publish reserved_percent for an ext4 mount -- this is
# the pill's own SEGMENT strip's data source (status.json, not a per-render
# subprocess call), so a mount the daemon can't read tune2fs for must not
# silently look identical to one that just isn't ext2/3/4 -- both the pill
# and this assertion treat None/absent as "don't show the control", but the
# fixture here IS readable, so the field must actually be populated.
poll_cfg = dict(mod.DEFAULTS)
poll_cfg.update({"exclude_mounts": [], "tmpfs_mounts": [], "include_fstypes": ["ext4"]})
row = mod.poll_mount({"mountpoint": mnt, "fstype": "ext4", "device": dev},
                      {}, poll_cfg, poll_cfg["owner_uid"], __import__("time").time())
assert row is not None, "poll_mount returned nothing for a live ext4 mount"
assert row.get("reserved_percent") == mod._tune2fs_reserved_percent(dev), \
    f"poll_mount's reserved_percent disagrees with a fresh tune2fs read: {row}"

print(f"reserve ok: {original}% -> 1% -> {original}%, statvfs avail moved and "
      f"restored byte-exact ({avail_after - avail_before}B), 0% refused by the "
      "compiled-in floor, ledgered with prior+new percent, poll_mount publishes "
      f"reserved_percent ({row['reserved_percent']}%)")
PY
        cleanup_reserve
    else
        cleanup_reserve
        echo "reserve section: skipped (loop/mkfs.ext4/mount failed under sudo -n)"
    fi
else
    echo "reserve section: skipped (no passwordless sudo, or e2fsprogs not installed" \
         "-- this is the normal local-dev-box case, not a CI concern)"
fi

# --- V3.M2: journal-cap — bound journald's own disk footprint. Unlike
# reserve/btrfs above, this needs neither root nor real tooling: its own
# non-root-only BYEBYTE_TEST_JOURNALD_DIR/_DROPIN_DIR hooks (same class as
# BYEBYTE_TEST_HOME/_BOOT) point the whole verb at throwaway directories and
# skip the real systemctl/journalctl calls outright, so this always runs.
python3 - <<'PY'
import importlib.util, os, shutil, sys, tempfile
from importlib.machinery import SourceFileLoader

state_dir = tempfile.mkdtemp(prefix="byebyte-smoke-jcap-state-")
os.environ["BYEBYTE_STATE_DIR"] = state_dir  # STATE_DIR is a module-level
                                              # constant -- must be set BEFORE
                                              # exec_module, not just before
                                              # each journal_cap() call

loader = SourceFileLoader("byebyted_mod_jcap", "src/bin/byebyted")
spec = importlib.util.spec_from_loader("byebyted_mod_jcap", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)

journal_dir = tempfile.mkdtemp(prefix="byebyte-smoke-jcap-journal-")
dropin_dir = tempfile.mkdtemp(prefix="byebyte-smoke-jcap-dropin-")
try:
    with open(os.path.join(journal_dir, "fake.journal"), "wb") as f:
        f.write(b"x" * 65536)
    os.environ["BYEBYTE_TEST_JOURNALD_DIR"] = journal_dir
    os.environ["BYEBYTE_TEST_JOURNALD_DROPIN_DIR"] = dropin_dir
    cfg = {}

    # hostile input: refused regardless of dry_run, before any file touched.
    # "5" (bare byte count, no suffix) is deliberately NOT on this list --
    # _SIZE_RE's [KMGT]? suffix is optional, matching journalctl's own
    # --vacuum-size= accepting a bare byte count, so it's valid input, not
    # hostile.
    for bad in ("abc", "0M", "-5G", "5X", "5.5G", "M5", ""):
        r = mod.journal_cap(bad, True, cfg)
        assert "error" in r, f"'{bad}' should have been refused: {r}"
    assert not os.listdir(dropin_dir), "a refused size still wrote a drop-in"

    # missing journal dir: refused by name, not a crash
    os.environ["BYEBYTE_TEST_JOURNALD_DIR"] = os.path.join(journal_dir, "nope")
    missing = mod.journal_cap("500M", True, cfg)
    assert "error" in missing and "does not exist" in missing["error"], missing
    os.environ["BYEBYTE_TEST_JOURNALD_DIR"] = journal_dir

    # dry-run: reports current (none yet) + usage, touches nothing
    dry = mod.journal_cap("500M", True, cfg)
    assert dry.get("current_cap") is None, dry
    assert dry.get("proposed_cap") == "500M", dry
    assert dry.get("usage_bytes") == 65536, dry
    assert not os.listdir(dropin_dir), "dry-run wrote a drop-in"

    # real apply: writes the drop-in, skips the (nonexistent here) real
    # systemctl/journalctl calls under the test hooks, and says so honestly
    # rather than silently pretending a reload happened
    real = mod.journal_cap("500M", False, cfg)
    assert real.get("ok") is True, real
    assert real["prior_cap"] is None and real["new_cap"] == "500M", real
    assert "test target" in (real.get("reload_skipped") or ""), real
    dropin_path = os.path.join(dropin_dir, "90-byebyte.conf")
    with open(dropin_path) as f:
        contents = f.read()
    assert "SystemMaxUse=500M" in contents, contents

    # round trip: a second dry-run now reads the cap back from the drop-in
    # it just wrote -- the same read-your-own-write proof reserve's fixture
    # uses, just via a config file instead of statvfs
    after = mod.journal_cap("1G", True, cfg)
    assert after.get("current_cap") == "500M", after

    # ledgered, both directions
    ledger_path = os.path.join(state_dir, "ledger.jsonl")
    with open(ledger_path) as f:
        lines = [__import__("json").loads(l) for l in f if l.strip()]
    line = next(l for l in lines if l["category"] == "journal-cap")
    assert line["status"] == "ok" and "->500M" in line["target"], line

    print("journal-cap ok: hostile sizes refused, missing journal dir refused, "
          "dry-run touched nothing, real apply wrote the drop-in and skipped the "
          "real reload honestly, round-trip read its own write back, ledgered")
finally:
    shutil.rmtree(journal_dir, ignore_errors=True)
    shutil.rmtree(dropin_dir, ignore_errors=True)
    shutil.rmtree(state_dir, ignore_errors=True)
PY

# --- M3: ballast — built at startup (test override: bytes, not gigabytes),
# release frees it. "Zero writes before unlink" on the release path is
# verified by code review (ballast_release() in byebyted: only os.stat reads
# precede each os.unlink; the ledger — the only write — lands after every
# slab is already gone), per the spec's code-review fallback.
#
# The byte-size override is non-root-only by design (same class as
# BYEBYTE_TEST_HOME/BOOT) — under root it's refused and byebyted would try
# to build the real ballast_gb-sized (multi-GB) reserve instead, which isn't
# appropriate for a fast smoke pass and risks tripping this box's own tmpfs
# quota. Skip cleanly under root rather than attempt it.
if [ "$ROOT_SMOKE" -eq 1 ]; then
    echo "ballast section: skipped under root (byte-size test override is" \
         "non-root-only by design; a real multi-GB build isn't appropriate" \
         "for a smoke pass)"
else
python3 - "$RD" <<'PY'
import json, os, socket, sys

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

st = ask({"cmd": "ballast", "action": "status"})
assert st["slabs"], f"ballast never built: {st}"
assert st["total_bytes"] >= 1048576 * 0.9, st
ballast_dir = os.path.join(rd, "state", "ballast")
assert os.path.isdir(ballast_dir) and os.listdir(ballast_dir), "no slab files on disk"

rel = ask({"cmd": "ballast", "action": "release"})
assert rel["freed_bytes"] >= 1048576 * 0.9, rel
assert not os.listdir(ballast_dir), "release left slab files behind"

ledger_path = os.path.join(rd, "state", "ledger.jsonl")
with open(ledger_path) as f:
    lines = [json.loads(l) for l in f if l.strip()]
assert any(l["category"] == "ballast" and l["status"] == "released"
           for l in lines), lines

assert ask({"cmd": "ping"})["ok"] is True, "daemon died during ballast test"
print(f"ballast ok: built {st['total_bytes']}B, released {rel['freed_bytes']}B, ledgered")
PY
fi

# --- M3: kernels — running kernel and newest are never candidates
python3 - "$RD" "$ROOT_SMOKE" <<'PY'
import json, os, socket, sys

rd, root_smoke = sys.argv[1], sys.argv[2] == "1"

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

doc = ask({"cmd": "kernels"})
versions = {c["version"] for c in doc["candidates"]}
assert doc["running"] not in versions, doc
assert doc["newest"] not in versions, doc
if root_smoke:
    # _boot_dir() correctly refuses BYEBYTE_TEST_BOOT for root (by design,
    # same class as BYEBYTE_TEST_HOME) and reads the REAL /boot instead —
    # kernels() never mutates, so this is safe; just not fixture-exact.
    # The invariant that matters (never the running/newest kernel) still
    # holds and is asserted above regardless of which /boot this is.
    pass
else:
    assert doc["newest"] == "9.9.9-fakenew-generic", doc
    assert "1.0.0-fakeold-generic" in versions, doc
    assert "9.9.9-fakenew-generic" not in versions, doc
    if doc["candidates"]:
        assert "apt autoremove --purge" in (doc.get("apt_line") or ""), doc
assert ask({"cmd": "ping"})["ok"] is True, "daemon died during kernels test"
print(f"kernels ok: running={doc['running']} newest={doc['newest']} "
      f"candidates={sorted(versions)}")
PY

# --- M3: advise — rule engine shape + the fast-grower rule, driven by the
# M2 growth fixture (3MB added in ~1.1s reliably blows the 2G/day threshold)
python3 - "$RD" <<'PY'
import json, os, socket, sys

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

doc = ask({"cmd": "advise"})
assert isinstance(doc.get("findings"), list), doc
growers = [f for f in doc["findings"] if f["rule"] == "fast_grower"]
assert growers and growers[0]["path"].endswith("/growth"), doc["findings"]
assert ask({"cmd": "ping"})["ok"] is True, "daemon died during advise test"
print(f"advise ok: {len(doc['findings'])} finding(s), fast_grower on "
      f"{growers[0]['path']}")
PY

BYEBYTE_RUNTIME_DIR=$RD python3 src/bin/byebyte advise | grep -q "growth" \
    || { echo "SMOKE FAIL: CLI advise missing growth grower"; exit 1; }

# --- M4: burn — a real disk-backed writer is named at its actual rate
# V2.M3: on root (CAP_SYS_ADMIN), it's also named by directory (fanotify,
# background-aggregated since daemon startup); off root, that's absent —
# the clean-degrade path, exactly as documented.
python3 - "$RD" "$BURN_FIX" "$ROOT_SMOKE" <<'PY'
import json, os, socket, subprocess, sys, time

rd, burn_fix, root_smoke = sys.argv[1], sys.argv[2], sys.argv[3] == "1"

def ask(obj, timeout=10):
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    c.settimeout(timeout)
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
    "import os, time\n"
    f"f = open({os.path.join(burn_fix, 'churn')!r}, 'wb')\n"
    "chunk = b'\\0' * (2 * 1024 * 1024)\n"
    "end = time.time() + 6\n"
    "while time.time() < end:\n"
    "    f.write(chunk)\n"
    "    f.flush()\n"
    "    os.fsync(f.fileno())\n"
    "    time.sleep(0.15)\n"  # ~13MB/s nominal — wide margin over the 4MB/s bar
)])
try:
    time.sleep(0.3)  # let it start writing before the sample window opens
    doc = ask({"cmd": "burn", "seconds": 3}, timeout=15)
    writer = next((w for w in doc["writers"] if w["pid"] == child.pid), None)
    assert writer is not None, f"burn never saw pid {child.pid}: {doc}"
    assert writer["bytes_per_sec"] >= 4 * 1024 * 1024, writer
    if root_smoke:
        # fanotify only starts with CAP_SYS_ADMIN — under real root it
        # should have been aggregating events for this writer since the
        # child's first write, well before this 3s sample window even opens
        assert writer.get("top_path"), f"no top_path under root: {writer}"
        assert os.path.realpath(writer["top_path"]) == os.path.realpath(burn_fix), writer
    else:
        assert "top_path" not in writer, \
            f"top_path present without CAP_SYS_ADMIN: {writer}"
finally:
    child.kill()
    child.wait()

# hostile input: bad seconds/limit types and out-of-range values, daemon alive
assert "error" in ask({"cmd": "burn", "seconds": 0}), "seconds=0 accepted"
assert "error" in ask({"cmd": "burn", "seconds": "ten"}), "non-int seconds accepted"
assert "error" in ask({"cmd": "burn", "seconds": 5, "limit": -1}), "limit=-1 accepted"
assert ask({"cmd": "ping"})["ok"] is True, "daemon died after burn abuse"
path_note = f", top_path={writer['top_path']}" if writer.get("top_path") else " (no fanotify)"
print(f"burn ok: named pid {child.pid} at {writer['bytes_per_sec']/1e6:.1f}MB/s{path_note}, "
      "hostile input survived")
PY

BYEBYTE_RUNTIME_DIR=$RD python3 src/bin/byebyte burn --seconds 1 --json | python3 -c \
    "import json,sys; json.load(sys.stdin)" \
    || { echo "SMOKE FAIL: CLI burn json invalid"; exit 1; }

# --- V2.M4: sweep — dry-run previews unarmed categories, armed ones act for
# real, both ledgered. hf-hub is armed via config.json's sweep_categories
# (set at the top); every other category stays unarmed here, so both paths
# are exercised in one pass. Runs AFTER the M3 purge section on purpose — that
# section's own hf-hub dry-run check needs the fixture still intact, and this
# one is what finally deletes it (for real, since it's armed).
python3 - "$RD" "$FIX" "$ROOT_SMOKE" <<'PY'
import json, os, socket, sys

rd, fix, root_smoke = sys.argv[1], sys.argv[2], sys.argv[3] == "1"

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

hf_hub_path = os.path.join(fix, "home", ".cache", "huggingface", "hub", "models--test--x")
if not root_smoke:
    assert os.path.isdir(hf_hub_path), "fixture vanished before the sweep test ran"

# forced dry (dry=True): NOTHING acts, even the armed category -- always
# safe regardless of root, dry_run never touches disk
preview = ask({"cmd": "sweep", "dry": True})
by_cat = {r["category"]: r for r in preview["results"]}
assert by_cat["hf-hub"]["armed"] is True, by_cat["hf-hub"]
assert by_cat["hf-hub"]["dry_run"] is True, by_cat["hf-hub"]
assert by_cat["pip-cache"]["armed"] is False, by_cat["pip-cache"]
if root_smoke:
    # _resolve_owner_home() correctly refuses BYEBYTE_TEST_HOME under root
    # (by design) and reads the REAL owner's real home instead -- no reason
    # to expect it holds our fixture's models--test--x, or any hf-hub
    # content at all, so only the response's SHAPE is checked (msg 3249:
    # sweep never had the root_smoke carve-out the M3 purge section above
    # already does for this exact function -- ported down)
    assert isinstance(by_cat["hf-hub"].get("candidates"), list), by_cat["hf-hub"]
else:
    assert by_cat["hf-hub"]["total_bytes"] > 0, by_cat["hf-hub"]
    assert os.path.isdir(hf_hub_path), "forced-dry sweep touched disk"

if root_smoke:
    # NOT exercised further under root: sweep_categories arms hf-hub, and a
    # real dry=False call here acts on whatever _resolve_owner_home()
    # resolves to under root. This fixture's config.json sets owner_uid to
    # $(id -u) -- under plain `make smoke` that's the dev's own uid, but
    # under `sudo make smoke` it's 0, so _resolve_owner_home(0) correctly
    # calls _owner_home(0) and gets /root, NOT the operator's real home.
    # /root/.cache/huggingface/hub happening not to exist is what actually
    # kept this test from being destructive the first time it ran as root
    # (alfred, msg 3255, measured directly rather than assumed) -- the
    # OPERATOR'S OWN real 8.2G hf-hub cache lives at
    # /home/$OPERATOR/.cache/huggingface and was never at risk only because
    # root's own account happens to have never pulled a model on this
    # particular machine. On a box where root ever had, this exact test
    # would have deleted it for real. pip-cache, uv-cache and thumbnails
    # route through the identical _detect_cache_dir -> _resolve_owner_home
    # path and are exposed the SAME way the instant any of them is added to
    # sweep_categories above -- do not add one without also confirming this
    # root_smoke branch (or an equivalent) still guards it. The general
    # rule this earns: a smoke fixture that ARMS a destructive category
    # must never resolve its target through the invoking user's real
    # identity -- owner_uid: $(id -u) reads as hermetic and isn't, because
    # under sudo it silently becomes the one account (root) whose home
    # nobody thinks to check. Skipped outright here rather than trusted to
    # keep being lucky about what root's own home happens to contain -- a
    # real, disclosed coverage gap for this one category under root, not a
    # false skip. The armed-delete mechanism itself IS exercised for real
    # elsewhere in this suite regardless of root (M3's project-artifacts
    # purge above, whose detector walks scan_roots directly and never
    # touches owner_home).
    summary = ("sweep ok (root): forced-dry preview correct in shape; armed "
              "real-delete against hf-hub not exercised under root -- see "
              "the comment above this block for why")
else:
    # real run (dry=False): hf-hub (armed) acts for real; everything else previews
    real = ask({"cmd": "sweep", "dry": False})
    by_cat = {r["category"]: r for r in real["results"]}
    hf = by_cat["hf-hub"]
    assert hf["armed"] is True and hf["dry_run"] is False, hf
    assert hf["freed_bytes"] > 0, hf
    assert not os.path.isdir(hf_hub_path), "sweep armed hf-hub but didn't delete it"
    unarmed = by_cat["pip-cache"]
    assert unarmed["dry_run"] is True and unarmed["armed"] is False, unarmed

    # kernels: always report-only regardless of anything in sweep_categories —
    # running apt-get to remove one for real is a separate authorization, never
    # bundled into this milestone (see byebyted.py's sweep() docstring)
    kern = by_cat["kernels"]
    assert kern["dry_run"] is True and kern["armed"] is False, kern

    # ledger: the forced-dry preview AND the real act both left a line
    ledger_path = os.path.join(rd, "state", "ledger.jsonl")
    with open(ledger_path) as f:
        lines = [json.loads(l) for l in f if l.strip()]
    assert any(l["category"] == "sweep:hf-hub" and l["status"] == "dry_run" for l in lines), \
        f"the forced-dry preview never ledgered hf-hub: {lines}"
    assert any(l["category"] == "sweep:hf-hub" and l["status"] == "ok" for l in lines), \
        f"the real sweep act never ledgered hf-hub: {lines}"

    # history: replays the ledger lines just written, target field (not the
    # legacy path alias — these are freshly-written, post-ruling lines)
    hist = ask({"cmd": "sweep", "history": True, "limit": 10})
    hist_lines = hist["history"]
    assert any(l["category"] == "sweep:hf-hub" and l["status"] == "ok"
               and l["target"] == hf_hub_path for l in hist_lines), hist_lines
    summary = (f"sweep ok: dry-run previews unarmed categories, armed hf-hub "
              f"freed {hf['freed_bytes']}B for real, both paths ledgered, "
              "history replays")

# hostile input: non-bool dry — refused; daemon alive after -- safe and
# identical either way, never touches disk
assert "error" in ask({"cmd": "sweep", "dry": "yes"}), "non-bool dry accepted"
assert ask({"cmd": "ping"})["ok"] is True, "daemon died during sweep test"
print(summary)
PY

BYEBYTE_RUNTIME_DIR=$RD python3 src/bin/byebyte sweep --dry --json | python3 -c \
    "import json,sys; json.load(sys.stdin)" \
    || { echo "SMOKE FAIL: CLI sweep json invalid"; exit 1; }
if [ "$ROOT_SMOKE" -eq 1 ]; then
    echo "CLI sweep --history hf-hub check skipped under root: the real hf-hub" \
         "act above is itself skipped under root (see the python block's own" \
         "comment), so there is no guaranteed sweep:hf-hub ledger line to find"
else
BYEBYTE_RUNTIME_DIR=$RD python3 src/bin/byebyte sweep --history | grep -q "sweep:hf-hub" \
    || { echo "SMOKE FAIL: CLI sweep --history missing hf-hub"; exit 1; }
fi

# --- M4: make deb — builds a real .deb; contents include bins+units+man.
# Builds and inspects only — never installed. The log path is per-invocation
# unique: a shared dev box runs concurrent smoke passes (root and
# unprivileged, different agents) against the SAME checkout, and a fixed
# path let one process's log clobber another's — real failure, innocent-
# looking evidence. DEBFILE is derived the same deterministic way the
# Makefile derives it (never "most recently modified" — with concurrent
# same-version builds that's ambiguous too).
DEBLOG=$(mktemp --tmpdir=/tmp byebyte-smoke-deb-build.XXXXXX.log)
make deb > "$DEBLOG" 2>&1 \
    || { echo "SMOKE FAIL: make deb failed"; cat "$DEBLOG"; rm -f "$DEBLOG"; exit 1; }
rm -f "$DEBLOG"
DEBFILE="build/deb/byebyte_$(tr -d '[:space:]' < packaging/VERSION)_all.deb"
CONTENTS=$(dpkg-deb --contents "$DEBFILE")
for want in usr/bin/byebyted usr/bin/byebyte usr/bin/byebyte-healthcheck \
            usr/bin/byebyte-update \
            usr/share/byebyte/lib/sutra.py usr/share/byebyte/lib/sutra.version \
            usr/share/byebyte/lib/sutra.commit \
            usr/share/byebyte/lib/sutra_update.py usr/share/byebyte/lib/sutra_update.version \
            usr/share/byebyte/lib/sutra_update.commit \
            usr/share/byebyte/lib/sutra_xen.py usr/share/byebyte/lib/sutra_xen.version \
            usr/share/byebyte/lib/sutra_xen.commit \
            usr/share/byebyte/allowed_signers \
            usr/share/byebyte/extension/byebyte@asuramaya/extension.js \
            usr/share/byebyte/extension/byebyte@asuramaya/pill.js \
            lib/systemd/system/byebyted.service \
            lib/systemd/system/byebyte-update.service \
            lib/systemd/system/byebyte-update.timer \
            lib/systemd/system/byebyte-sweep.service \
            lib/systemd/system/byebyte-sweep.timer \
            usr/share/man/man1/byebyte.1 usr/share/man/man8/byebyted.8 \
            etc/byebyte/config.json; do
    echo "$CONTENTS" | grep -q "$want" \
        || { echo "SMOKE FAIL: deb missing $want"; exit 1; }
done
echo "deb ok: $DEBFILE built, contents verified (never installed)"

echo "SMOKE OK"
