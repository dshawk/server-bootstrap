#!/usr/bin/env bash
# Restore 3x-ui database from a backup tarball created by backup-xui.sh,
# then rewrite certificate paths and subscription URLs for THIS server's IP.
set -euo pipefail

ARCHIVE="${1:-}"
if [ -z "$ARCHIVE" ] || [ ! -f "$ARCHIVE" ]; then
  echo "Usage: $0 /root/backups/x-ui-YYYYMMDD-HHMMSS.tar.gz" >&2
  exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root" >&2
  exit 1
fi

SERVER_IP="${SERVER_IP:-}"
if [ -z "$SERVER_IP" ]; then
  SERVER_IP="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
fi
if [ -z "$SERVER_IP" ]; then
  SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
fi
if [ -z "$SERVER_IP" ]; then
  echo "Cannot detect SERVER_IP; set it explicitly" >&2
  exit 1
fi

CERT_DIR="/root/cert/${SERVER_IP}"
CERT="${CERT_DIR}/fullchain.pem"
KEY="${CERT_DIR}/privkey.pem"
if [ ! -s "$CERT" ] || [ ! -s "$KEY" ]; then
  echo "IP certificate not found at $CERT. Issue it first (install.sh --xui or scripts/renew-ip-cert.sh)." >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
tar -C "$TMP" -xzf "$ARCHIVE"
if [ ! -f "$TMP/x-ui/x-ui.db" ]; then
  echo "Archive does not contain x-ui/x-ui.db" >&2
  exit 1
fi

systemctl stop x-ui || true
mkdir -p /etc/x-ui
if [ -f /etc/x-ui/x-ui.db ]; then
  cp -a /etc/x-ui/x-ui.db "/etc/x-ui/x-ui.db.bak.$(date +%s)"
fi
install -m 600 "$TMP/x-ui/x-ui.db" /etc/x-ui/x-ui.db

python3 - "$SERVER_IP" "$CERT" "$KEY" <<'PY'
import sqlite3, sys
ip, cert, key = sys.argv[1], sys.argv[2], sys.argv[3]
c = sqlite3.connect("/etc/x-ui/x-ui.db")

def upsert(k, v):
    row = c.execute("SELECT id FROM settings WHERE key=?", (k,)).fetchone()
    if row:
        c.execute("UPDATE settings SET value=? WHERE key=?", (v, k))
    else:
        c.execute("INSERT INTO settings(key,value) VALUES(?,?)", (k, v))

for k, v in [
    ("webCertFile", cert),
    ("webKeyFile", key),
    ("subCertFile", cert),
    ("subKeyFile", key),
    ("subEnable", "true"),
    ("subListen", "127.0.0.1"),
    ("subPort", "2097"),
    ("subURI", f"https://{ip}:2096"),
    ("subJsonEnable", "true"),
    ("subJsonURI", f"https://{ip}:2096/json"),
]:
    upsert(k, v)
c.commit()
print("Updated cert paths and subscription URLs for", ip)
PY

systemctl start x-ui
sleep 2
systemctl is-active x-ui
echo "Restored. Update the subscription in each client (new IP). Reality keys come from the backup db."
