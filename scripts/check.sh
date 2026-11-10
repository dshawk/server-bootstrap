#!/usr/bin/env bash
# Service, port and certificate status (read-only).
set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

ok() { printf "  [ok]  %s\n" "$1"; }
bad() { printf "  [!!]  %s\n" "$1"; }
info() { printf "  [--]  %s\n" "$1"; }

echo "== services =="
for s in x-ui nginx paperclip warp-svc fail2ban danted xui-sub-rewrite monitoring-panel; do
  if systemctl list-unit-files "${s}.service" >/dev/null 2>&1 || systemctl status "${s}.service" >/dev/null 2>&1; then
    if systemctl is-active --quiet "$s"; then ok "$s"; else bad "$s is $(systemctl is-active "$s" 2>/dev/null || echo missing)"; fi
  else
    info "$s not installed"
  fi
done
if pgrep -x xray-linux-amd6 >/dev/null 2>&1 || pgrep -f xray-linux-amd64 >/dev/null 2>&1; then
  ok "xray process"
else
  info "xray process not running"
fi

echo "== ports =="
check_port() {
  local spec="$1" desc="$2"
  if ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "$spec"; then ok "$desc"; else bad "$desc not listening"; fi
}
check_port ':80$' "http :80"
check_port ':443$' "https/sni :443"
check_port ':2096$' "subscription :2096"
check_port '127.0.0.1:2097$' "x-ui sub :2097"
check_port '127.0.0.1:2098$' "sub-rewrite :2098"
check_port '127.0.0.1:40000$' "WARP proxy :40000"
check_port ':18088$' "dante :18088"
check_port '127.0.0.1:3100$' "paperclip :3100"
check_port '127.0.0.1:8787$' "monitoring :8787"

echo "== WARP =="
if command -v warp-cli >/dev/null 2>&1; then
  mode="$(warp-cli --accept-tos settings 2>/dev/null | grep -i 'Mode:' || true)"
  if echo "$mode" | grep -Eqi 'WarpProxy'; then ok "$mode"; else bad "WARP not in proxy mode: $mode"; fi
else
  info "warp-cli not installed"
fi

echo "== certificates =="
check_cert() {
  local label="$1" path="$2"
  if [ ! -s "$path" ]; then
    info "$label missing ($path)"
    return
  fi
  local hours
  hours="$(python3 - "$path" <<'PY'
import datetime,sys,subprocess
out=subprocess.check_output(["openssl","x509","-in",sys.argv[1],"-noout","-enddate"], text=True)
raw=out.split("=",1)[1].strip()
dt=datetime.datetime.strptime(raw, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=datetime.timezone.utc)
hours=(dt-datetime.datetime.now(datetime.timezone.utc)).total_seconds()/3600
print(f"{raw} ({hours:.1f}h left)")
if hours < 48:
    sys.exit(2)
PY
)"
  rc=$?
  if [ $rc -eq 2 ]; then bad "$label $hours"; else ok "$label $hours"; fi
}
IP="$(curl -4 -fsS --max-time 3 https://api.ipify.org 2>/dev/null || true)"
if [ -n "$IP" ]; then
  check_cert "IP $IP" "/root/cert/${IP}/fullchain.pem"
fi
for d in /etc/letsencrypt/live/*/fullchain.pem; do
  [ -f "$d" ] || continue
  name="$(basename "$(dirname "$d")")"
  check_cert "$name" "$d"
done
