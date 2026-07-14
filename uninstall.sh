#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 asuramaya and byebyte contributors
# byebyte uninstaller. Keeps /etc/byebyte (config) and /var/lib/byebyte
# (state) unless --purge is given. Root-only, and never self-elevates — see
# install.sh for why. Doesn't touch any per-account GNOME pill install (it
# never guesses whose home to reach into): remove the pill as yourself, on
# each account that installed it —
#   gnome-extensions disable byebyte@asuramaya
#   rm -rf ~/.local/share/gnome-shell/extensions/byebyte@asuramaya
set -uo pipefail

PREFIX="${PREFIX:-/usr/local}"
BINDIR="$PREFIX/bin"
SHAREDIR="$PREFIX/share/byebyte"
UNITDIR="/etc/systemd/system"
PURGE=0

for a in "$@"; do
  case "$a" in
    --purge) PURGE=1 ;;
    -h|--help) echo "usage: ./uninstall.sh [--purge]"; exit 0 ;;
    *) echo "unknown argument: $a" >&2; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "byebyte uninstaller needs root — run: sudo ./uninstall.sh" >&2
  exit 1
fi

echo "== byebyte uninstaller =="

echo "-- stopping service + update timer"
systemctl disable --now byebyted.service byebyte-update.timer byebyte-update.service 2>/dev/null || true

echo "-- removing files"
for b in byebyted byebyte byebyte-healthcheck byebyte-update; do
  rm -f "$BINDIR/$b"
done
rm -f "$UNITDIR/byebyted.service" "$UNITDIR/byebyte-update.service" "$UNITDIR/byebyte-update.timer"
rm -rf "$SHAREDIR"
systemctl daemon-reload

if [[ "$PURGE" -eq 1 ]]; then
  echo "-- purging config + state"
  rm -rf /etc/byebyte /var/lib/byebyte
  echo "byebyte fully removed."
else
  echo "byebyte removed. (kept /etc/byebyte and /var/lib/byebyte — use --purge to drop them.)"
fi

cat <<'EOF'

the GNOME pill is per-account and was NOT touched — as yourself, on each
account that installed it:
  gnome-extensions disable byebyte@asuramaya
  rm -rf ~/.local/share/gnome-shell/extensions/byebyte@asuramaya
EOF
