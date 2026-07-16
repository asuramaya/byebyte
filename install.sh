#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 asuramaya and byebyte contributors
# byebyte installer — the storage demon: daemon, CLI, healthcheck, updater,
# systemd units. Root-only, and ONLY root-only: this script never re-execs
# itself under sudo (a script that quietly escalates itself is exactly what
# once misattributed the human user to "root" in a sibling repo — see
# coldspot's git log). If you're not root, it says so and stops; you always
# type sudo yourself, exactly once, so there is no ambiguity about who
# actually ran it. The GNOME pill is a SEPARATE, per-account, non-root step —
# `make pill` — since installing a file into your own home never needed root
# in the first place.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo /nonexistent)"
PREFIX="${PREFIX:-/usr/local}"
BINDIR="$PREFIX/bin"
SHAREDIR="$PREFIX/share/byebyte"
UNITDIR="/etc/systemd/system"
EXT_UUID="byebyte@asuramaya"

# ---- root, checked FIRST ------------------------------------------------
# Fail fast and plainly rather than self-elevating.
if [[ $EUID -ne 0 ]]; then
  cat >&2 <<'EOF'
byebyte needs root to install (binaries, systemd units, /etc/byebyte). Re-run
with sudo:

  sudo ./install.sh        (or: sudo make install)

The GNOME pill is a separate, no-root step afterwards — as yourself:

  make pill
  gnome-extensions enable byebyte@asuramaya
EOF
  exit 1
fi

# No published releases yet, so no curl|bash bootstrap (coldspot grows one
# from its release assets) — this installs from a checkout, full stop.
if [[ ! -f "$SRC/bin/byebyted" ]]; then
  echo "install.sh must run from a byebyte checkout (bin/byebyted not found" >&2
  echo "next to it). Clone https://github.com/asuramaya/ByeByte and re-run." >&2
  exit 1
fi

# The only thing that needs to know about a human account is owner_uid in a
# FRESHLY seeded config (the daemon chowns status.json + control.sock to it).
# Since this script never sudos itself, $SUDO_UID is reliable: it's set by
# whichever single sudo call the human actually typed.
OWNER_UID="${SUDO_UID:-1000}"
VERSION="$(tr -d '[:space:]' < "$SRC/VERSION" 2>/dev/null || echo unknown)"

echo "== byebyte ${VERSION} installer =="

# 1. binaries + version marker (root-owned, not group/world writable)
echo "-- binaries -> $BINDIR"
for b in byebyted byebyte byebyte-healthcheck byebyte-update; do
  install -m 0755 -o root -g root "$SRC/bin/$b" "$BINDIR/$b"
done
install -d -m 0755 "$SHAREDIR"
install -m 0644 "$SRC/VERSION" "$SHAREDIR/VERSION"

# 1b. man pages
echo "-- man pages -> $PREFIX/share/man"
install -d -m 0755 "$PREFIX/share/man/man1" "$PREFIX/share/man/man8"
install -m 0644 "$SRC/man/byebyte.1" "$PREFIX/share/man/man1/byebyte.1"
install -m 0644 "$SRC/man/byebyted.8" "$PREFIX/share/man/man8/byebyted.8"

# 2. config: seeded once, then NEVER overwritten (kept across reinstalls).
# Config is the seed, never the master — a tampered one can't weaken the
# daemon anyway (typed, clamped, unknown keys ignored), but the human's
# tuning survives every reinstall.
if [[ -f /etc/byebyte/config.json ]]; then
  echo "-- /etc/byebyte/config.json exists — keeping it untouched"
else
  echo "-- seeding /etc/byebyte/config.json (owner_uid=$OWNER_UID)"
  if [[ -z "${SUDO_UID:-}" ]]; then
    echo "   couldn't tell which account owns the socket (no \$SUDO_UID —"
    echo "   running from a root shell rather than sudo?). Defaulting"
    echo "   owner_uid to 1000; edit /etc/byebyte/config.json if that's wrong."
  fi
  install -d -m 0755 /etc/byebyte
  python3 - "$SRC/config/config.json" /etc/byebyte/config.json "$OWNER_UID" <<'PY'
import json, sys
src, dst, uid = sys.argv[1], sys.argv[2], int(sys.argv[3])
cfg = json.load(open(src))
cfg["owner_uid"] = uid
with open(dst, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY
  chmod 0644 /etc/byebyte/config.json
fi

# 3. systemd: daemon + daily update-CHECK timer. The timer only ever runs
# `byebyte-update --check` — it notifies, it never installs unattended
# (family doctrine: updates are click-to-install).
echo "-- systemd units + enabling"
install -m 0644 "$SRC/systemd/system/byebyted.service"       "$UNITDIR/byebyted.service"
install -m 0644 "$SRC/systemd/system/byebyte-update.service" "$UNITDIR/byebyte-update.service"
install -m 0644 "$SRC/systemd/system/byebyte-update.timer"   "$UNITDIR/byebyte-update.timer"
systemctl daemon-reload
systemctl enable byebyted.service
# `enable --now` on an ALREADY-active unit is a no-op start — it would leave
# the old binary running in memory even though we just overwrote it on disk.
# Detect a re-install and explicitly restart so the new daemon actually runs.
if systemctl is-active --quiet byebyted.service; then
  echo "-- restarting byebyted to load the updated daemon"
  systemctl restart byebyted.service
else
  systemctl start byebyted.service
fi
# The daily update timer only ever CHECKS (notify-only, unprivileged) — but
# even a check that phones GitHub is opt-in, family-wide. Enable deliberately:
#   sudo systemctl enable --now byebyte-update.timer

# 4. verify perms
echo "-- verifying"
verify() { local got; got="$(stat -c '%a' "$1" 2>/dev/null || echo '?')"
  [[ "$got" == "$2" ]] && echo "   OK   $1 ($got)" || echo "   WARN $1 is $got, expected $2"; }
verify "$BINDIR/byebyted" 755
verify /etc/byebyte/config.json 644

cat <<EOF

== byebyte ${VERSION} installed ==
  byebyte status             headroom, burn rate, ETA-to-full per mount
  byebyte-healthcheck        vitals: fresh status.json + a daemon that answers ping
  byebyte-update --check     is a newer release out? (never installs by itself)
  man byebyte / man 8 byebyted   full verb reference, config keys, security model
  Remove:  sudo ./uninstall.sh   (keeps /etc/byebyte + /var/lib/byebyte; --purge drops them)

daily update CHECK is off by default (it's notify-only, never installs). Opt in:
  sudo systemctl enable --now byebyte-update.timer

>>> the GNOME pill is a separate, per-account, NO-ROOT step — as yourself: <<<
  make pill
  gnome-extensions enable ${EXT_UUID}
  (then log out and back in once — Wayland reloads extensions at login)
EOF
