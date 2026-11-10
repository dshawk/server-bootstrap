#!/bin/bash
# Daily certificate expiry check. Writes a short status log.
set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LOG=/var/log/monitoring-panel/cert-check.log
FLAG=/var/log/monitoring-panel/cert-warning
mkdir -p /var/log/monitoring-panel
tmp=$(mktemp)
warn=0
check() {
  local name="$1" path="$2" host="$3" port="$4" sni="$5"
  local out hours raw
  if [ -n "$path" ] && [ -f "$path" ]; then
    raw=$(openssl x509 -in "$path" -noout -enddate 2>/dev/null | cut -d= -f2)
  else
    raw=$(echo | timeout 5 openssl s_client -connect "${host}:${port}" -servername "$sni" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
  fi
  if [ -z "$raw" ]; then
    echo "$name: не удалось прочитать сертификат" >> "$tmp"
    warn=1
    return
  fi
  local exp epoch now
  exp=$(date -u -d "$raw" +%s 2>/dev/null || true)
  now=$(date -u +%s)
  if [ -z "$exp" ]; then
    echo "$name: не разобран срок ($raw)" >> "$tmp"
    warn=1
    return
  fi
  hours=$(( (exp - now) / 3600 ))
  echo "$name: до $raw UTC, осталось ${hours} ч" >> "$tmp"
  if [ "$hours" -lt 48 ]; then
    warn=1
  fi
}
{
  echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) UTC / $(TZ=Europe/Moscow date +%Y-%m-%dT%H:%M:%S) MSK ====="
  check "IP-файл" /root/cert/__SERVER_IP__/fullchain.pem "" "" ""
  check "IP :2096" "" 127.0.0.1 2096 __SERVER_IP__
  check "__DOMAIN_AI__" /etc/letsencrypt/live/__DOMAIN_AI__/fullchain.pem "" "" ""
  check "__DOMAIN_MONITORING__" /etc/letsencrypt/live/__DOMAIN_MONITORING__/fullchain.pem "" "" ""
  cat "$tmp"
  if [ "$warn" -eq 1 ]; then
    echo "WARNING: один или несколько сертификатов истекают менее чем через 48 часов или недоступны"
    cp "$tmp" "$FLAG"
  else
    echo "OK"
    rm -f "$FLAG"
  fi
  echo
} >> "$LOG"
rm -f "$tmp"
# keep last ~200 KB
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 200000 ]; then
  tail -c 80000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
exit 0
