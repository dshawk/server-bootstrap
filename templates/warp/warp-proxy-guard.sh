#!/usr/bin/env bash
# Safety guard: if WARP is ever switched to a full tunnel, put it back to
# local proxy on 127.0.0.1:40000. A full tunnel (warp-cli mode warp) would
# break the VPN, x-ui, nginx and SSH on this host.
set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

PORT="${WARP_PROXY_PORT:-40000}"
LOG="${WARP_GUARD_LOG:-/var/log/warp-proxy-guard.log}"
mkdir -p "$(dirname "$LOG")"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a "$LOG"; }

if ! command -v warp-cli >/dev/null 2>&1; then
  exit 0
fi
if ! systemctl is-active --quiet warp-svc; then
  exit 0
fi

settings="$(warp-cli --accept-tos settings 2>/dev/null || true)"
# Expected: "Mode: WarpProxy on port 40000"
if echo "$settings" | grep -Eqi 'Mode:[[:space:]]*WarpProxy'; then
  if ! ss -lnt 2>/dev/null | grep -q "127.0.0.1:${PORT}"; then
    log "WARP proxy port ${PORT} is not listening; reconnecting"
    warp-cli --accept-tos proxy port "$PORT" >/dev/null 2>&1 || true
    warp-cli --accept-tos connect >/dev/null 2>&1 || true
  fi
  exit 0
fi

log "WARNING: WARP is not in proxy mode. Forcing mode proxy on 127.0.0.1:${PORT}. Do not use: warp-cli mode warp"
warp-cli --accept-tos mode proxy >/dev/null 2>&1 || true
warp-cli --accept-tos proxy port "$PORT" >/dev/null 2>&1 || true
warp-cli --accept-tos connect >/dev/null 2>&1 || true
exit 0
