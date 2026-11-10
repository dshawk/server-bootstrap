#!/bin/bash
# Privileged helper for monitoring-panel. Fixed action names only; no user input.
set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 022

ACTION="${1:-}"
LOGDIR=/var/log/monitoring-panel
mkdir -p "$LOGDIR"

log_action() {
  local name="$1"
  echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) $name ====="
}

case "$ACTION" in
  renew-ip)
    LOG="$LOGDIR/acme-ip.log"
    {
      log_action renew-ip
      /root/.acme.sh/acme.sh --home /root/.acme.sh --renew -d __SERVER_IP__ --ecc --force
      rc1=$?
      /root/.acme.sh/acme.sh --home /root/.acme.sh --install-cert -d __SERVER_IP__ --ecc \
        --key-file /root/cert/__SERVER_IP__/privkey.pem \
        --fullchain-file /root/cert/__SERVER_IP__/fullchain.pem \
        --reloadcmd "systemctl restart x-ui; systemctl reload nginx"
      rc2=$?
      echo "exit renew=$rc1 install=$rc2"
      if [ "$rc1" -ne 0 ] || [ "$rc2" -ne 0 ]; then
        exit 1
      fi
      exit 0
    } 2>&1 | tee -a "$LOG"
    exit "${PIPESTATUS[0]}"
    ;;
  renew-domains)
    LOG="$LOGDIR/acme-domains.log"
    {
      log_action renew-domains
      # No --force: Let's Encrypt rate limits. Renews only when due (or issues if missing).
      certbot certonly --webroot -w /var/www/html --key-type ecdsa \
        --non-interactive --keep-until-expiring --cert-name __DOMAIN_AI__ \
        -d __DOMAIN_AI__
      rc1=$?
      if [ -d /etc/letsencrypt/live/__DOMAIN_MONITORING__ ]; then
        certbot certonly --webroot -w /var/www/html --key-type ecdsa \
          --non-interactive --keep-until-expiring --cert-name __DOMAIN_MONITORING__ \
          -d __DOMAIN_MONITORING__
        rc2=$?
      else
        certbot certonly --webroot -w /var/www/html --key-type ecdsa \
          --non-interactive --agree-tos --cert-name __DOMAIN_MONITORING__ \
          -d __DOMAIN_MONITORING__
        rc2=$?
      fi
      nginx -t && systemctl reload nginx
      rc3=$?
      echo "exit ai=$rc1 monitoring=$rc2 nginx=$rc3"
      if [ "$rc1" -ne 0 ] || [ "$rc2" -ne 0 ] || [ "$rc3" -ne 0 ]; then
        exit 1
      fi
      exit 0
    } 2>&1 | tee -a "$LOG"
    exit "${PIPESTATUS[0]}"
    ;;
  restart-xui)
    log_action restart-xui
    systemctl restart x-ui
    sleep 1
    systemctl is-active x-ui
    exit $?
    ;;
  reload-nginx)
    log_action reload-nginx
    nginx -t && systemctl reload nginx && systemctl is-active nginx
    exit $?
    ;;
  cert-status)
    /usr/bin/python3 - << 'PY'
import json, os, re, ssl, socket, subprocess, datetime, glob

TZ_NAME = "Europe/Moscow"

def file_expiry(path):
    if not path or not os.path.isfile(path):
        return {"path": path, "ok": False, "error": "missing"}
    try:
        out = subprocess.check_output(
            ["openssl", "x509", "-in", path, "-noout", "-enddate", "-startdate", "-subject", "-issuer"],
            text=True, stderr=subprocess.STDOUT, timeout=5,
        )
    except Exception as e:
        return {"path": path, "ok": False, "error": str(e)}
    data = {"path": path, "ok": True, "raw": out.strip()}
    for line in out.splitlines():
        if line.startswith("notAfter="):
            data["not_after_raw"] = line.split("=", 1)[1].strip()
            try:
                dt = datetime.datetime.strptime(data["not_after_raw"], "%b %d %H:%M:%S %Y %Z").replace(tzinfo=datetime.timezone.utc)
                data["not_after"] = dt.isoformat()
                data["hours_left"] = round((dt - datetime.datetime.now(datetime.timezone.utc)).total_seconds() / 3600, 1)
            except Exception:
                pass
        elif line.startswith("notBefore="):
            data["not_before_raw"] = line.split("=", 1)[1].strip()
        elif line.startswith("subject="):
            data["subject"] = line.split("=", 1)[1].strip()
        elif line.startswith("issuer="):
            data["issuer"] = line.split("=", 1)[1].strip()
    return data

def tail(path, n=40):
    if not path or not os.path.isfile(path):
        return None
    try:
        with open(path, "r", errors="replace") as f:
            lines = f.readlines()
        return "".join(lines[-n:])
    except Exception as e:
        return f"(error reading {path}: {e})"

def acme_next():
    conf = "/root/.acme.sh/__SERVER_IP___ecc/__SERVER_IP__.conf"
    info = {}
    try:
        with open(conf, "r", errors="replace") as f:
            for line in f:
                line = line.strip()
                if line.startswith("Le_NextRenewTimeStr="):
                    info["next_renew"] = line.split("=", 1)[1].strip().strip("'")
                elif line.startswith("Le_RenewalDays="):
                    info["renewal_days"] = line.split("=", 1)[1].strip().strip("'")
                elif line.startswith("Le_Webroot="):
                    info["webroot"] = line.split("=", 1)[1].strip().strip("'")
    except Exception as e:
        info["error"] = str(e)
    return info

logs = {}
for p, n in [
    ("/root/.acme.sh/acme.sh.log", 25),
    ("/var/log/monitoring-panel/acme-ip.log", 20),
    ("/var/log/monitoring-panel/acme-domains.log", 20),
    ("/var/log/monitoring-panel/cert-check.log", 12),
    ("/var/log/letsencrypt/letsencrypt.log", 12),
]:
    t = tail(p, n)
    if t is not None and t.strip():
        logs[p] = t

print(json.dumps({
    "files": {
        "ip": file_expiry("/root/cert/__SERVER_IP__/fullchain.pem"),
        "ai": file_expiry("/etc/letsencrypt/live/__DOMAIN_AI__/fullchain.pem"),
        "monitoring": file_expiry("/etc/letsencrypt/live/__DOMAIN_MONITORING__/fullchain.pem"),
    },
    "acme": acme_next(),
    "logs": logs,
}, ensure_ascii=False))
PY
    exit $?
    ;;
  *)
    echo "unknown action" >&2
    exit 2
    ;;
esac
