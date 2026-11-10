#!/usr/bin/env bash
# Backup 3x-ui database and TLS certificates into a tarball.
# Does not include client configs from the live process beyond x-ui.db (the db
# contains UUIDs and keys — treat the archive as secret, chmod 600).
set -euo pipefail

OUT="${1:-}"
STAMP="$(date +%Y%m%d-%H%M%S)"
if [ -z "$OUT" ]; then
  OUT="/root/backups/x-ui-${STAMP}.tar.gz"
fi
mkdir -p "$(dirname "$OUT")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/x-ui" "$TMP/cert" "$TMP/meta"
if [ -f /etc/x-ui/x-ui.db ]; then
  install -m 600 /etc/x-ui/x-ui.db "$TMP/x-ui/x-ui.db"
else
  echo "WARNING: /etc/x-ui/x-ui.db not found" >&2
fi
if [ -d /root/cert ]; then
  cp -a /root/cert/. "$TMP/cert/" || true
fi
{
  echo "created_at=$(date -Is)"
  echo "hostname=$(hostname)"
  echo "server_ip=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  if [ -x /usr/local/x-ui/x-ui ]; then
    /usr/local/x-ui/x-ui --help >/dev/null 2>&1 || true
    echo "x-ui_bin=/usr/local/x-ui/x-ui"
  fi
  if [ -x /usr/local/x-ui/bin/xray-linux-amd64 ]; then
    echo -n "xray_version="
    /usr/local/x-ui/bin/xray-linux-amd64 version 2>/dev/null | head -1 || true
  fi
} > "$TMP/meta/info.txt"

tar -C "$TMP" -czf "$OUT" x-ui cert meta
chmod 600 "$OUT"
echo "Wrote $OUT"
