#!/usr/bin/env bash
# server-bootstrap — idempotent installer for a dshawk-style Ubuntu 22.04/24.04 server.
# Run as root. Does not push any secrets to git. See README.md and env.example.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ROOT

VERSION="1.0.0"
XUI_VERSION="${XUI_VERSION:-2.8.10}"
XRAY_VERSION="${XRAY_VERSION:-26.6.27}"
PAPERCLIP_VERSION="${PAPERCLIP_VERSION:-2026.1023.0}"
GEMINI_CLI_VERSION="${GEMINI_CLI_VERSION:-0.67.0}"
CURSOR_AGENT_VERSION="${CURSOR_AGENT_VERSION:-2026.11.05-86047df}"
NODE_MAJOR="${NODE_MAJOR:-24}"
WARP_PROXY_PORT="${WARP_PROXY_PORT:-40000}"
DANTE_PORT="${DANTE_PORT:-18088}"
SWAP_SIZE="${SWAP_SIZE:-2G}"
WEBROOT="${WEBROOT:-/var/www/html}"
WARP_CLIENT_PREFIXES="${WARP_CLIENT_PREFIXES:-home,job,dshawk}"
WARP_CLIENT_SUFFIXES="${WARP_CLIENT_SUFFIXES:-xhttp,tcp,vk,reality,maska}"
SUB_PATHS="${SUB_PATHS:-}"
ADMIN_IPS="${ADMIN_IPS:-}"
DOMAIN_AI="${DOMAIN_AI:-}"
DOMAIN_MONITORING="${DOMAIN_MONITORING:-}"
ACME_EMAIL="${ACME_EMAIL:-}"
SERVER_IP="${SERVER_IP:-}"
KIMI_REGION="${KIMI_REGION:-}"
SKIP_CERT="${SKIP_CERT:-0}"
DRY_RUN=0

# Load optional env file without overriding already-set variables
load_env() {
  local f
  for f in "$ROOT/env" /etc/server-bootstrap.env /root/server-bootstrap.env; do
    if [ -f "$f" ]; then
      # shellcheck disable=SC1090
      set -a
      # do not source secrets into the repo; the file stays on the host
      # shellcheck source=/dev/null
      . "$f"
      set +a
    fi
  done
}

usage() {
  cat <<'EOF'
Usage: ./install.sh [modules] [options]

Modules (can be combined). --all enables the standard set:
  --base --xui --nginx --warp --dante --monitoring
  --paperclip --gemini --cursor --kimi

  --base          swap 2G, fail2ban sshd, logrotate, journald 200M, unattended-upgrades
  --xui           3x-ui (pinned), xray template (Google->WARP), IP cert (acme.sh webroot)
  --nginx         nginx, stream SNI on 443, site templates, domain certs (certbot webroot)
  --warp          cloudflare-warp in proxy mode 127.0.0.1:40000 ONLY (never full tunnel)
  --dante         SOCKS5 on 18088 with generated user/password
  --monitoring    monitoring-panel (bundled or clone), units, random admin password
  --paperclip     paperclipai (pinned) systemd user paperclip, Node 24, nginx vhost
  --gemini        @google/gemini-cli + WARP wrapper /usr/local/bin/gemini
  --cursor        cursor-agent CLI for user paperclip, symlink in /usr/local/bin
  --kimi          kimi-code CLI for root and paperclip, /usr/local/bin/kimi
  --all           all modules above

Options:
  --dry-run       print actions, change nothing
  --skip-cert     do not issue/renew certificates
  -h, --help      this help

Environment (see env.example):
  DOMAIN_AI, DOMAIN_MONITORING, ACME_EMAIL, SERVER_IP
  WARP_CLIENT_PREFIXES  (default home,job,dshawk)
  SUB_PATHS             subscription path names for whitelist headers
  ADMIN_IPS             extra fail2ban ignore addresses

Safety: never run `warp-cli mode warp` on this host.
EOF
}

log()  { printf '[*] %s\n' "$*"; }
ok()   { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[ERR] %s\n' "$*" >&2; exit 1; }

run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf 'DRY: %s\n' "$*"
    return 0
  fi
  "$@"
}

run_sh() {
  if [ "$DRY_RUN" = "1" ]; then
    printf 'DRY: %s\n' "$*"
    return 0
  fi
  bash -c "$*"
}

need_root() {
  [ "$(id -u)" -eq 0 ] || die "Run as root"
}

need_ubuntu() {
  [ -f /etc/os-release ] || die "Cannot detect OS"
  # shellcheck disable=SC1091
  . /etc/os-release
  [ "${ID:-}" = "ubuntu" ] || die "This installer targets Ubuntu 22.04/24.04 (found ${ID:-unknown})"
  case "${VERSION_ID:-}" in
    22.04|24.04) ;;
    *) warn "Untested Ubuntu ${VERSION_ID}; continuing" ;;
  esac
}

detect_ip() {
  if [ -n "${SERVER_IP}" ]; then
    printf '%s' "$SERVER_IP"
    return
  fi
  local ip
  ip="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [ -z "$ip" ] && ip="$(curl -4 -fsS --max-time 5 https://4.ident.me 2>/dev/null || true)"
  [ -z "$ip" ] && ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  [ -n "$ip" ] || die "Cannot detect SERVER_IP"
  SERVER_IP="$ip"
  printf '%s' "$ip"
}

detect_iface() {
  ip -4 route show default 2>/dev/null | awk '{print $5; exit}'
}

ensure_pkg() {
  if [ "$DRY_RUN" = "1" ]; then
    printf 'DRY: apt-get install -y %s\n' "$*"
    return 0
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
}

apt_update() {
  if [ "$DRY_RUN" = "1" ]; then
    echo 'DRY: apt-get update'
    return 0
  fi
  apt-get update -qq
}

write_file() {
  local dest="$1" mode="${2:-644}"
  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY: write $dest mode $mode"
    cat >/dev/null
    return 0
  fi
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  install -m "$mode" "$tmp" "$dest"
  rm -f "$tmp"
}

render() {
  # render TEMPLATE to DEST, replacing __PLACE__ from environment and extra KEY=VAL args
  local src="$1" dest="$2" mode="${3:-644}"
  shift 3 || true
  python3 - "$src" "$dest" "$mode" "$DRY_RUN" "$@" <<'PY'
import os, sys
src, dest, mode, dry, *pairs = sys.argv[1:]
text = open(src, encoding="utf-8").read()
subs = dict(os.environ)
for p in pairs:
    if "=" in p:
        k, v = p.split("=", 1)
        subs[k] = v
# longest keys first
for k, v in sorted(subs.items(), key=lambda kv: -len(kv[0])):
    text = text.replace("__" + k + "__", v)
if dry == "1":
    print("DRY: render", src, "->", dest)
    sys.exit(0)
os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
open(dest, "w", encoding="utf-8").write(text)
os.chmod(dest, int(mode, 8))
print("wrote", dest)
PY
}

# ------------------------------ base ------------------------------------
module_base() {
  log "base: swap, fail2ban, logrotate, journald, unattended-upgrades"
  apt_update
  ensure_pkg ca-certificates curl wget gnupg lsb-release jq unzip socat cron \
    fail2ban logrotate python3 sqlite3 openssl

  if ! swapon --show | grep -q .; then
    if [ ! -f /swapfile ]; then
      log "creating $SWAP_SIZE swapfile"
      if [ "$DRY_RUN" != "1" ]; then
        fallocate -l "$SWAP_SIZE" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
        chmod 600 /swapfile
        mkswap /swapfile
      else
        echo "DRY: fallocate/mkswap /swapfile"
      fi
    fi
    run swapon /swapfile
  else
    ok "swap already active"
  fi
  if ! grep -qE '^/swapfile[[:space:]]' /etc/fstab; then
    if [ "$DRY_RUN" = "1" ]; then
      echo "DRY: append /swapfile to /etc/fstab"
    else
      echo "/swapfile none swap sw 0 0" >> /etc/fstab
    fi
  else
    ok "fstab already has /swapfile (not adding a duplicate)"
  fi

  render "$ROOT/templates/fail2ban/jail.d/sshd.local" /etc/fail2ban/jail.d/sshd.local 644 \
    ADMIN_IPS="$ADMIN_IPS"
  # drop trailing ignoreip space if ADMIN_IPS empty
  if [ "$DRY_RUN" != "1" ]; then
    sed -i 's/ignoreip = 127.0.0.1\/8 ::1 $/ignoreip = 127.0.0.1\/8 ::1/' /etc/fail2ban/jail.d/sshd.local
  fi
  run systemctl enable --now fail2ban

  mkdir -p /etc/systemd/journald.conf.d
  run install -m 644 "$ROOT/templates/journald/size.conf" /etc/systemd/journald.conf.d/size.conf
  if [ "$DRY_RUN" != "1" ]; then
    systemctl restart systemd-journald || true
  fi
  run install -m 644 "$ROOT/templates/logrotate/xray-access" /etc/logrotate.d/xray-access

  ensure_pkg unattended-upgrades
  if [ "$DRY_RUN" != "1" ]; then
    cat >/etc/apt/apt.conf.d/20auto-upgrades <<'C'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
C
    # Security updates only (leave 50unattended-upgrades defaults)
  fi
  ok "base done"
}

# ------------------------------ nginx -----------------------------------
ensure_nginx_stream_include() {
  local conf=/etc/nginx/nginx.conf
  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY: ensure stream include in nginx.conf"
    return 0
  fi
  if ! grep -q 'stream-sni.conf' "$conf"; then
    cp -a "$conf" "$conf.bak.bootstrap"
    printf '\ninclude /etc/nginx/stream-sni.conf;\n' >> "$conf"
  fi
}

module_nginx() {
  log "nginx: packages, ACME webroot, stream SNI"
  apt_update
  ensure_pkg nginx libnginx-mod-stream certbot
  run mkdir -p "$WEBROOT/.well-known/acme-challenge" /var/www/roscom /etc/nginx/snippets /etc/nginx/sites-available /etc/nginx/sites-enabled
  run chown -R www-data:www-data "$WEBROOT"
  # default site off — we serve ACME ourselves
  run rm -f /etc/nginx/sites-enabled/default
  render "$ROOT/templates/nginx/sites/acme-http.conf" /etc/nginx/sites-available/acme-http 644
  run ln -sfn /etc/nginx/sites-available/acme-http /etc/nginx/sites-enabled/acme-http

  detect_ip >/dev/null
  local iface
  iface="$(detect_iface || true)"
  render "$ROOT/templates/nginx/stream-sni.conf" /etc/nginx/stream-sni.conf 644 \
    DOMAIN_AI="${DOMAIN_AI:-_ai.invalid}" \
    DOMAIN_MONITORING="${DOMAIN_MONITORING:-_mon.invalid}"
  ensure_nginx_stream_include
  run systemctl enable nginx
  if [ "$DRY_RUN" != "1" ]; then
    nginx -t
    systemctl reload nginx || systemctl restart nginx
  fi
  ok "nginx listening (stream 443 + http 80 webroot)"
}

issue_domain_cert() {
  local domain="$1"
  [ "$SKIP_CERT" = "1" ] && { warn "SKIP_CERT=1, not issuing $domain"; return 0; }
  [ -n "$domain" ] || return 0
  [ -n "$ACME_EMAIL" ] || die "ACME_EMAIL is required to issue a certificate for $domain"
  if [ -s "/etc/letsencrypt/live/${domain}/fullchain.pem" ]; then
    ok "cert for $domain already exists"
    if [ "$DRY_RUN" != "1" ]; then
      certbot certonly --webroot -w "$WEBROOT" --key-type ecdsa \
        --non-interactive --keep-until-expiring --agree-tos -m "$ACME_EMAIL" \
        --cert-name "$domain" -d "$domain" || warn "certbot keep-until-expiring returned $?"
    fi
    return 0
  fi
  log "issuing domain cert $domain (certbot webroot)"
  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY: certbot certonly --webroot -d $domain"
    return 0
  fi
  certbot certonly --webroot -w "$WEBROOT" --key-type ecdsa \
    --non-interactive --agree-tos -m "$ACME_EMAIL" \
    --cert-name "$domain" -d "$domain"
}

# ------------------------------ warp ------------------------------------
module_warp() {
  log "WARP: proxy mode only on 127.0.0.1:${WARP_PROXY_PORT}"
  apt_update
  if [ ! -f /etc/apt/sources.list.d/cloudflare-client.list ]; then
    if [ "$DRY_RUN" != "1" ]; then
      curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
      # shellcheck disable=SC1091
      . /etc/os-release
      echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${VERSION_CODENAME} main" \
        > /etc/apt/sources.list.d/cloudflare-client.list
      apt_update
    else
      echo "DRY: add cloudflare warp apt repo"
    fi
  fi
  ensure_pkg cloudflare-warp
  run systemctl enable --now warp-svc
  if [ "$DRY_RUN" != "1" ]; then
    # registration is idempotent enough; ignore "already registered"
    warp-cli --accept-tos registration new >/dev/null 2>&1 || true
    warp-cli --accept-tos mode proxy
    warp-cli --accept-tos proxy port "$WARP_PROXY_PORT"
    warp-cli --accept-tos connect || true
    # NEVER: warp-cli mode warp
    if warp-cli --accept-tos settings 2>/dev/null | grep -Eqi 'Mode:[[:space:]]*Warp([^P]|$)'; then
      die "WARP is not in proxy mode after setup; refusing to continue (would risk a full tunnel)"
    fi
  fi
  run install -m 755 "$ROOT/templates/warp/warp-proxy-guard.sh" /usr/local/sbin/warp-proxy-guard.sh
  run install -m 644 "$ROOT/templates/systemd/warp-proxy-guard.service" /etc/systemd/system/warp-proxy-guard.service
  run install -m 644 "$ROOT/templates/systemd/warp-proxy-guard.timer" /etc/systemd/system/warp-proxy-guard.timer
  if [ "$DRY_RUN" != "1" ]; then
    systemctl daemon-reload
    systemctl enable --now warp-proxy-guard.timer
    /usr/local/sbin/warp-proxy-guard.sh || true
  fi
  ok "WARP proxy ready (do NOT run: warp-cli mode warp)"
}

# ------------------------------ x-ui ------------------------------------
install_xui_binaries() {
  if [ -x /usr/local/x-ui/x-ui ]; then
    local ver
    ver="$(/usr/local/x-ui/x-ui -v 2>/dev/null || true)"
    ok "3x-ui already installed (${ver:-unknown}); not reinstalling"
    return 0
  fi
  local arch="amd64"
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) die "unsupported arch $(uname -m)" ;;
  esac
  local url="https://github.com/MHSanaei/3x-ui/releases/download/v${XUI_VERSION}/x-ui-linux-${arch}.tar.gz"
  log "downloading 3x-ui v${XUI_VERSION}"
  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY: curl $url"
    return 0
  fi
  local tmp="/tmp/x-ui-install-$$"
  mkdir -p "$tmp"
  curl -fLRo "$tmp/x-ui.tar.gz" "$url"
  tar -C "$tmp" -xzf "$tmp/x-ui.tar.gz"
  mkdir -p /usr/local/x-ui
  # tarball contains an x-ui/ directory
  if [ -d "$tmp/x-ui" ]; then
    cp -a "$tmp/x-ui/." /usr/local/x-ui/
  else
    die "unexpected 3x-ui tarball layout"
  fi
  chmod +x /usr/local/x-ui/x-ui /usr/local/x-ui/x-ui.sh /usr/local/x-ui/bin/xray-linux-* || true
  if [ -f /usr/local/x-ui/x-ui.sh ]; then
    install -m 755 /usr/local/x-ui/x-ui.sh /usr/bin/x-ui
  fi
  if [ -f /usr/local/x-ui/x-ui.service.debian ]; then
    install -m 644 /usr/local/x-ui/x-ui.service.debian /etc/systemd/system/x-ui.service
  elif [ -f /usr/local/x-ui/x-ui.service ]; then
    install -m 644 /usr/local/x-ui/x-ui.service /etc/systemd/system/x-ui.service
  fi
  systemctl daemon-reload
  systemctl enable --now x-ui
  sleep 2
  # random credentials if still default — print once to a 600 file
  local user pass port path
  user="$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 12)"
  pass="$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16)"
  port="$(shuf -i 20000-60000 -n 1)"
  path="$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16)"
  /usr/local/x-ui/x-ui setting -username "$user" -password "$pass" -port "$port" -webBasePath "$path" >/dev/null 2>&1 || true
  umask 077
  cat >/root/x-ui-credentials.txt <<C
url=https://$(detect_ip):${port}/${path}
username=${user}
password=${pass}
port=${port}
webBasePath=${path}
C
  chmod 600 /root/x-ui-credentials.txt
  systemctl restart x-ui
  ok "3x-ui installed; credentials: /root/x-ui-credentials.txt (chmod 600)"
  rm -rf "$tmp"
}

update_xray_core() {
  local bin=/usr/local/x-ui/bin/xray-linux-amd64
  [ -d /usr/local/x-ui/bin ] || return 0
  log "pinning Xray-core v${XRAY_VERSION}"
  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY: download Xray-linux-64.zip v${XRAY_VERSION}"
    return 0
  fi
  local tmp="/tmp/xray-upd-$$"
  mkdir -p "$tmp"
  curl -fLRo "$tmp/xray.zip" "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-64.zip"
  unzip -o "$tmp/xray.zip" -d "$tmp" >/dev/null
  systemctl stop x-ui || true
  if [ -x "$bin" ]; then
    cp -a "$bin" "${bin}.bak.$(date +%s)" || true
  fi
  install -m 755 "$tmp/xray" "$bin"
  [ -f "$tmp/geoip.dat" ] && cp -f "$tmp/geoip.dat" /usr/local/x-ui/bin/geoip.dat
  [ -f "$tmp/geosite.dat" ] && cp -f "$tmp/geosite.dat" /usr/local/x-ui/bin/geosite.dat
  systemctl start x-ui || true
  rm -rf "$tmp"
  ok "Xray $($bin version 2>/dev/null | head -1 || true)"
}

issue_ip_cert() {
  [ "$SKIP_CERT" = "1" ] && { warn "SKIP_CERT=1"; return 0; }
  local ip
  ip="$(detect_ip)"
  [ -n "$ACME_EMAIL" ] || die "ACME_EMAIL is required to issue the IP certificate"
  log "IP cert for $ip via acme.sh webroot $WEBROOT (shortlived)"
  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY: acme.sh --issue -d $ip --webroot $WEBROOT --certificate-profile shortlived"
    return 0
  fi
  apt_update
  ensure_pkg cron curl socat
  if [ ! -x /root/.acme.sh/acme.sh ]; then
    curl -fsSL https://get.acme.sh | sh -s "email=${ACME_EMAIL}"
  fi
  /root/.acme.sh/acme.sh --register-account -m "$ACME_EMAIL" --server letsencrypt >/dev/null 2>&1 || true
  /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force >/dev/null 2>&1 || true
  mkdir -p "/root/cert/${ip}" "$WEBROOT/.well-known/acme-challenge"
  # webroot, never standalone (nginx owns port 80)
  /root/.acme.sh/acme.sh --issue -d "$ip" \
    --webroot "$WEBROOT" \
    --server letsencrypt \
    --certificate-profile shortlived \
    --days 3 \
    --ecc || /root/.acme.sh/acme.sh --issue -d "$ip" \
      --webroot "$WEBROOT" \
      --server letsencrypt \
      --certificate-profile shortlived \
      --days 3
  /root/.acme.sh/acme.sh --install-cert -d "$ip" --ecc \
    --key-file "/root/cert/${ip}/privkey.pem" \
    --fullchain-file "/root/cert/${ip}/fullchain.pem" \
    --reloadcmd "systemctl restart x-ui; systemctl reload nginx" || \
  /root/.acme.sh/acme.sh --install-cert -d "$ip" \
    --key-file "/root/cert/${ip}/privkey.pem" \
    --fullchain-file "/root/cert/${ip}/fullchain.pem" \
    --reloadcmd "systemctl restart x-ui; systemctl reload nginx"
  chmod 600 "/root/cert/${ip}/privkey.pem"
  chmod 644 "/root/cert/${ip}/fullchain.pem"
  test -s "/root/cert/${ip}/fullchain.pem"
  /root/.acme.sh/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1 || true
  if ! crontab -l 2>/dev/null | grep -q 'acme.sh --cron'; then
    (crontab -l 2>/dev/null; echo "14 3,9,15,21 * * * \"/root/.acme.sh\"/acme.sh --cron --home \"/root/.acme.sh\" > /dev/null") | crontab -
  fi
  ok "IP certificate installed at /root/cert/${ip}/"
}

apply_xray_template() {
  local ip db=/etc/x-ui/x-ui.db
  ip="$(detect_ip)"
  [ -f "$db" ] || { warn "x-ui.db not ready yet"; return 0; }
  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY: apply xray template + cert settings"
    return 0
  fi
  python3 - "$ROOT/templates/xray/template.json" "$db" "$ip" "$WARP_CLIENT_PREFIXES" "$WARP_CLIENT_SUFFIXES" <<'PY'
import json, sqlite3, sys
src, db, ip, prefixes, suffixes = sys.argv[1:6]
tmpl = json.loads(open(src, encoding="utf-8").read())
users = []
for p in [x.strip() for x in prefixes.split(",") if x.strip()]:
    for s in [x.strip() for x in suffixes.split(",") if x.strip()]:
        users.append(f"{p}-{s}")
# fill user arrays
for rule in tmpl.get("routing", {}).get("rules", []):
    if rule.get("user") == ["__WARP_USERS__"] or rule.get("user") == "__WARP_USERS__":
        rule["user"] = users
c = sqlite3.connect(db)

def upsert(k, v):
    row = c.execute("SELECT id FROM settings WHERE key=?", (k,)).fetchone()
    if row:
        c.execute("UPDATE settings SET value=? WHERE key=?", (v, k))
    else:
        c.execute("INSERT INTO settings(key,value) VALUES(?,?)", (k, v))

cert = f"/root/cert/{ip}/fullchain.pem"
key = f"/root/cert/{ip}/privkey.pem"
upsert("xrayTemplateConfig", json.dumps(tmpl, ensure_ascii=False, separators=(",", ":")))
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
print("xray template applied, warp users:", len(users))
PY
  run systemctl restart x-ui || true
}

install_sub_rewrite_and_roscom() {
  local ip
  ip="$(detect_ip)"
  run install -m 755 "$ROOT/templates/xui-sub-rewrite.py" /usr/local/bin/xui-sub-rewrite.py
  run install -m 644 "$ROOT/templates/systemd/xui-sub-rewrite.service" /etc/systemd/system/xui-sub-rewrite.service
  run install -m 755 "$ROOT/templates/roscom-whitelist-refresh.sh" /usr/local/bin/roscom-whitelist-refresh.sh
  if [ "$DRY_RUN" != "1" ]; then
    echo "https://${ip}:2096" > /etc/roscom-sub-base
    install -m 644 "$ROOT/templates/roscom-extra-direct.txt" /etc/roscom-extra-direct.txt
    /usr/local/bin/roscom-whitelist-refresh.sh || warn "roscom whitelist refresh failed (network?)"
    if ! crontab -l 2>/dev/null | grep -q roscom-whitelist-refresh; then
      (crontab -l 2>/dev/null; echo "30 4 * * * /usr/local/bin/roscom-whitelist-refresh.sh >/var/log/roscom-whitelist-refresh.log 2>&1") | crontab -
    fi
  fi
  local regex
  regex="$(printf '%s' "$SUB_PATHS" | tr ',' '|' | tr -d ' ')"
  if [ -z "$regex" ]; then
    # no whitelist paths: write a vhost without the special location
    if [ "$DRY_RUN" != "1" ]; then
      python3 - "$ROOT/templates/nginx/sites/xui-sub.conf" "/etc/nginx/sites-available/xui-sub.conf" "$ip" <<'PY'
import sys,re
src, dest, ip = sys.argv[1:4]
t=open(src,encoding="utf-8").read().replace("__SERVER_IP__", ip)
# drop the optional whitelist location block
t=re.sub(r"\n\s*# Optional:.*?location ~ \^/sub/\(__SUB_PATHS_REGEX__\)/\?\$ \{.*?\n\s*\}\n","\n",t,flags=re.S)
open(dest,"w",encoding="utf-8").write(t)
PY
    else
      echo "DRY: xui-sub.conf without SUB_PATHS"
    fi
  else
    render "$ROOT/templates/nginx/sites/xui-sub.conf" /etc/nginx/sites-available/xui-sub.conf 644 \
      SERVER_IP="$ip" SUB_PATHS_REGEX="$regex"
  fi
  run ln -sfn /etc/nginx/sites-available/xui-sub.conf /etc/nginx/sites-enabled/xui-sub.conf
  if [ "$DRY_RUN" != "1" ]; then
    systemctl daemon-reload
    systemctl enable --now xui-sub-rewrite
    nginx -t && systemctl reload nginx
  fi
}

module_xui() {
  log "3x-ui v${XUI_VERSION} + Xray v${XRAY_VERSION} + IP cert + routing template"
  # nginx webroot should already be up; if not, try to install nginx first
  if ! systemctl is-active --quiet nginx 2>/dev/null; then
    warn "nginx is not running; installing the nginx module first so the IP cert can use webroot"
    module_nginx
  fi
  apt_update
  ensure_pkg curl tar unzip socat cron sqlite3 python3
  install_xui_binaries
  update_xray_core
  issue_ip_cert
  apply_xray_template
  install_sub_rewrite_and_roscom
  ok "x-ui module done"
}

# ------------------------------ dante -----------------------------------
module_dante() {
  log "dante SOCKS5 on :${DANTE_PORT}"
  apt_update
  ensure_pkg dante-server
  local iface user pass
  iface="$(detect_iface)"
  [ -n "$iface" ] || die "cannot detect default interface for dante external:"
  user="mlproxy"
  if ! getent passwd "$user" >/dev/null; then
    run useradd --system --no-create-home --shell /usr/sbin/nologin "$user"
  fi
  if [ "$DRY_RUN" != "1" ]; then
    if [ -f /root/multilogin-proxy.txt ]; then
      ok "keeping existing /root/multilogin-proxy.txt"
    else
      pass="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)"
      echo "${user}:${pass}" | chpasswd
      umask 077
      printf '%s:%s:%s:%s\n' "$(detect_ip)" "$DANTE_PORT" "$user" "$pass" > /root/multilogin-proxy.txt
      chmod 600 /root/multilogin-proxy.txt
      printf 'software: dante-server (sockd)\nservice: danted.service\nport: %s\nuser: %s\nlisten: 0.0.0.0:%s\nexternal: %s\ncreds: /root/multilogin-proxy.txt\n' \
        "$DANTE_PORT" "$user" "$DANTE_PORT" "$iface" > /root/multilogin-proxy.meta
      chmod 600 /root/multilogin-proxy.meta
      ok "dante credentials written to /root/multilogin-proxy.txt (chmod 600)"
    fi
  fi
  render "$ROOT/templates/dante/danted.conf" /etc/danted.conf 644 \
    DANTE_PORT="$DANTE_PORT" EXTERNAL_IFACE="$iface"
  run systemctl enable --now danted
  run systemctl restart danted
  ok "dante listening on ${DANTE_PORT}"
}

# ------------------------------ node / paperclip ------------------------
install_node() {
  if command -v node >/dev/null 2>&1; then
    ok "node $(node -v) already installed"
    return 0
  fi
  log "installing Node ${NODE_MAJOR}.x from NodeSource"
  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY: nodesource setup_${NODE_MAJOR}.x"
    return 0
  fi
  mkdir -p /usr/share/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --yes --dearmor -o /usr/share/keyrings/nodesource.gpg
  cat >/etc/apt/sources.list.d/nodesource.sources <<C
Types: deb
URIs: https://deb.nodesource.com/node_${NODE_MAJOR}.x
Suites: nodistro
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/nodesource.gpg
C
  apt_update
  ensure_pkg nodejs
}

module_paperclip() {
  log "Paperclip ${PAPERCLIP_VERSION} as user paperclip"
  [ -n "$DOMAIN_AI" ] || die "DOMAIN_AI is required for --paperclip"
  install_node
  if ! getent passwd paperclip >/dev/null; then
    run useradd --system --create-home --shell /bin/bash paperclip
  fi
  if [ "$DRY_RUN" != "1" ]; then
    if [ ! -f /home/paperclip/paperclip.env ]; then
      render "$ROOT/templates/paperclip.env.example" /home/paperclip/paperclip.env 600 \
        DOMAIN_AI="$DOMAIN_AI"
      chown paperclip:paperclip /home/paperclip/paperclip.env
    fi
    mkdir -p /home/paperclip/.local/bin
    chown -R paperclip:paperclip /home/paperclip
  fi
  render "$ROOT/templates/systemd/paperclip.service" /etc/systemd/system/paperclip.service 644 \
    PAPERCLIP_VERSION="$PAPERCLIP_VERSION"
  if ! systemctl is-active --quiet nginx 2>/dev/null; then
    module_nginx
  fi
  issue_domain_cert "$DOMAIN_AI"
  render "$ROOT/templates/nginx/sites/paperclip.conf" /etc/nginx/sites-available/paperclip 644 \
    DOMAIN_AI="$DOMAIN_AI"
  run ln -sfn /etc/nginx/sites-available/paperclip /etc/nginx/sites-enabled/paperclip
  if [ "$DRY_RUN" != "1" ]; then
    systemctl daemon-reload
    systemctl enable --now paperclip
    nginx -t && systemctl reload nginx
  fi
  ok "Paperclip service enabled. After it is up: sudo -u paperclip -H npx paperclipai@${PAPERCLIP_VERSION} auth bootstrap-ceo --api-base http://127.0.0.1:3100"
  ok "Then import agents: sudo -u paperclip -H $ROOT/scripts/import-paperclip-agents.sh dshawk --target new --yes"
}

module_gemini() {
  log "Gemini CLI ${GEMINI_CLI_VERSION} + WARP wrapper"
  install_node
  if [ "$DRY_RUN" != "1" ]; then
    npm install -g "@google/gemini-cli@${GEMINI_CLI_VERSION}"
    # official binary lands at /usr/bin/gemini; wrap it at /usr/local/bin/gemini (PATH prefers /usr/local)
    install -m 755 "$ROOT/templates/gemini-wrapper.sh" /usr/local/bin/gemini
  else
    echo "DRY: npm i -g @google/gemini-cli@${GEMINI_CLI_VERSION}"
  fi
  ok "gemini wrapper at /usr/local/bin/gemini (uses WARP :${WARP_PROXY_PORT}). Log in with GEMINI_API_KEY or 'gemini' OAuth."
}

module_cursor() {
  log "cursor-agent ${CURSOR_AGENT_VERSION} for user paperclip"
  if ! getent passwd paperclip >/dev/null; then
    run useradd --system --create-home --shell /bin/bash paperclip
  fi
  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY: install cursor-agent into paperclip home"
    return 0
  fi
  local verdir="/home/paperclip/.local/share/cursor-agent/versions/${CURSOR_AGENT_VERSION}"
  if [ ! -x "${verdir}/cursor-agent" ]; then
    local url="https://downloads.cursor.com/lab/${CURSOR_AGENT_VERSION}/linux/x64/agent-cli-package.tar.gz"
    local tmp="/tmp/cursor-agent-$$"
    mkdir -p "$tmp" "$verdir"
    curl -fLRo "$tmp/pkg.tar.gz" "$url"
    tar --strip-components=1 -xzf "$tmp/pkg.tar.gz" -C "$verdir"
    rm -rf "$tmp"
    chown -R paperclip:paperclip /home/paperclip/.local
  fi
  mkdir -p /home/paperclip/.local/bin
  ln -sfn "$verdir/cursor-agent" /home/paperclip/.local/bin/cursor-agent
  ln -sfn "$verdir/cursor-agent" /home/paperclip/.local/bin/agent
  ln -sfn /home/paperclip/.local/bin/cursor-agent /usr/local/bin/cursor-agent
  ln -sfn /home/paperclip/.local/bin/cursor-agent /usr/local/bin/agent
  chown -h paperclip:paperclip /home/paperclip/.local/bin/cursor-agent /home/paperclip/.local/bin/agent || true
  # PATH for paperclip
  if [ -f /home/paperclip/.profile ] && ! grep -q '.local/bin' /home/paperclip/.profile; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> /home/paperclip/.profile
  fi
  ok "cursor-agent installed ($(sudo -u paperclip -H /home/paperclip/.local/bin/cursor-agent --version 2>/dev/null || echo ok)). Log in: sudo -u paperclip -H cursor-agent login  (or set CURSOR_API_KEY)."
}

module_kimi() {
  log "kimi-code CLI for root and paperclip"
  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY: curl https://code.kimi.com/kimi-code/install.sh"
    return 0
  fi
  if [ ! -x /root/.kimi-code/bin/kimi ]; then
    curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash
  fi
  if [ -x /root/.kimi-code/bin/kimi ]; then
    ln -sfn /root/.kimi-code/bin/kimi /usr/local/bin/kimi
  elif [ -x "$HOME/.kimi-code/bin/kimi" ]; then
    ln -sfn "$HOME/.kimi-code/bin/kimi" /usr/local/bin/kimi
  fi
  if ! getent passwd paperclip >/dev/null; then
    useradd --system --create-home --shell /bin/bash paperclip
  fi
  mkdir -p /home/paperclip/.kimi-code/bin
  if [ -x /root/.kimi-code/bin/kimi ]; then
    install -o paperclip -g paperclip -m 755 /root/.kimi-code/bin/kimi /home/paperclip/.kimi-code/bin/kimi
  fi
  if [ -n "$KIMI_REGION" ]; then
    printf '%s\n' "$KIMI_REGION" > /root/.kimi-code/region
    printf '%s\n' "$KIMI_REGION" > /home/paperclip/.kimi-code/region
    chown paperclip:paperclip /home/paperclip/.kimi-code/region
  fi
  chown -R paperclip:paperclip /home/paperclip/.kimi-code
  ok "kimi $(/usr/local/bin/kimi --version 2>/dev/null || true). Log in: kimi /login  (or as paperclip: sudo -u paperclip -H /home/paperclip/.kimi-code/bin/kimi)."
}

# ------------------------------ monitoring ------------------------------
xui_web_port() {
  if [ -f /etc/x-ui/x-ui.db ]; then
    python3 - <<'PY'
import sqlite3
try:
    c=sqlite3.connect("/etc/x-ui/x-ui.db")
    row=c.execute("SELECT value FROM settings WHERE key='webPort'").fetchone()
    print(row[0] if row and row[0] else "45232")
except Exception:
    print("45232")
PY
  else
    echo "45232"
  fi
}

module_monitoring() {
  log "monitoring panel"
  [ -n "$DOMAIN_MONITORING" ] || die "DOMAIN_MONITORING is required for --monitoring"
  detect_ip >/dev/null
  local src="$ROOT/vendor/monitoring-panel"
  if [ ! -f "$src/app.py" ]; then
    warn "bundled vendor/monitoring-panel missing; trying git clone"
    if [ "$DRY_RUN" != "1" ]; then
      mkdir -p /tmp/mp-clone
      git clone --depth 1 git@github-monpanel:dshawk/monitoring-panel.git /tmp/mp-clone || \
        git clone --depth 1 https://github.com/dshawk/monitoring-panel.git /tmp/mp-clone || \
        die "cannot obtain monitoring-panel sources"
      src=/tmp/mp-clone
    fi
  fi
  if ! getent passwd monpanel >/dev/null; then
    run useradd --system --no-create-home --shell /usr/sbin/nologin --user-group monpanel
  fi
  local webport
  webport="$(xui_web_port)"
  if [ "$DRY_RUN" != "1" ]; then
    mkdir -p /opt/monitoring-panel /etc/monitoring-panel /var/log/monitoring-panel
    # copy and substitute placeholders
    python3 - "$src" /opt/monitoring-panel "$(detect_ip)" "$DOMAIN_AI" "$DOMAIN_MONITORING" "$webport" <<'PY'
import os,sys,shutil,pathlib
src, dest, ip, dai, dmon, webport = sys.argv[1:7]
# copy selected files
os.makedirs(dest, exist_ok=True)
for name in ("app.py","helper.sh","cert-check.sh"):
    p=os.path.join(src,name)
    if os.path.isfile(p):
        data=open(p,encoding="utf-8").read()
        for a,b in (("__SERVER_IP__",ip),("__DOMAIN_AI__",dai or ""),("__DOMAIN_MONITORING__",dmon),("__XUI_WEB_PORT__",webport)):
            data=data.replace(a,b)
        open(os.path.join(dest,name),"w",encoding="utf-8").write(data)
os.chmod(os.path.join(dest,"helper.sh"), 0o755)
os.chmod(os.path.join(dest,"cert-check.sh"), 0o755)
print("installed monitoring files")
PY
    chown root:monpanel /opt/monitoring-panel/app.py
    chmod 644 /opt/monitoring-panel/app.py
    chown monpanel:monpanel /var/log/monitoring-panel
    chmod 750 /var/log/monitoring-panel /etc/monitoring-panel
    chmod 770 /etc/monitoring-panel
    if [ ! -f /etc/monitoring-panel/env ]; then
      local mon_pass mon_secret
      mon_pass="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)"
      mon_secret="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
      umask 077
      cat >/etc/monitoring-panel/env <<C
MON_USER=admin
MON_PASSWORD=${mon_pass}
MON_SECRET=${mon_secret}
MON_BIND=127.0.0.1
MON_PORT=8787
C
      chown root:monpanel /etc/monitoring-panel/env
      chmod 660 /etc/monitoring-panel/env
      printf '%s\n' "$mon_pass" > /root/monitoring-panel-initial-password.txt
      chmod 600 /root/monitoring-panel-initial-password.txt
      ok "initial monitoring password saved to /root/monitoring-panel-initial-password.txt (change it after first login)"
    else
      ok "keeping existing /etc/monitoring-panel/env"
    fi
    install -o root -g root -m 440 "$src/sudoers/monitoring-panel" /etc/sudoers.d/monitoring-panel
    visudo -cf /etc/sudoers.d/monitoring-panel
    install -m 644 "$src/systemd/monitoring-panel.service" /etc/systemd/system/monitoring-panel.service
    install -m 644 "$src/systemd/monitoring-certcheck.service" /etc/systemd/system/monitoring-certcheck.service
    install -m 644 "$src/systemd/monitoring-certcheck.timer" /etc/systemd/system/monitoring-certcheck.timer
    install -m 644 "$src/fail2ban/filter.conf" /etc/fail2ban/filter.d/monitoring-panel.conf
    install -m 644 "$src/fail2ban/jail.local" /etc/fail2ban/jail.d/monitoring-panel.local
    install -m 644 "$src/logrotate/monitoring-panel" /etc/logrotate.d/monitoring-panel
    install -m 644 "$src/logrotate/xray-access" /etc/logrotate.d/xray-access
    mkdir -p /etc/systemd/journald.conf.d
    install -m 644 "$src/journald/size.conf" /etc/systemd/journald.conf.d/size.conf
  fi
  if ! systemctl is-active --quiet nginx 2>/dev/null; then
    module_nginx
  fi
  issue_domain_cert "$DOMAIN_MONITORING"
  render "$ROOT/templates/nginx/sites/monitoring.conf" /etc/nginx/sites-available/monitoring 644 \
    DOMAIN_MONITORING="$DOMAIN_MONITORING"
  run ln -sfn /etc/nginx/sites-available/monitoring /etc/nginx/sites-enabled/monitoring
  # refresh stream SNI map
  render "$ROOT/templates/nginx/stream-sni.conf" /etc/nginx/stream-sni.conf 644 \
    DOMAIN_AI="${DOMAIN_AI:-_ai.invalid}" \
    DOMAIN_MONITORING="$DOMAIN_MONITORING"
  if [ "$DRY_RUN" != "1" ]; then
    systemctl daemon-reload
    systemctl enable --now monitoring-panel.service monitoring-certcheck.timer
    systemctl restart fail2ban || true
    nginx -t && systemctl reload nginx
    # print initial password once if we just created it
    if [ -f /root/monitoring-panel-initial-password.txt ]; then
      echo "Monitoring URL: https://${DOMAIN_MONITORING}/  user=admin  password=$(cat /root/monitoring-panel-initial-password.txt)"
      echo "Change the password immediately. The file /root/monitoring-panel-initial-password.txt can be deleted after that."
    fi
  fi
  ok "monitoring panel at https://${DOMAIN_MONITORING}/"
}

# ------------------------------ main ------------------------------------
MODULES=()
ALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --base|--xui|--nginx|--warp|--dante|--monitoring|--paperclip|--gemini|--cursor|--kimi)
      MODULES+=("${1#--}"); shift ;;
    --all) ALL=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --skip-cert) SKIP_CERT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

load_env
if [ "$ALL" = "1" ]; then
  MODULES=(base nginx warp xui dante paperclip gemini cursor kimi monitoring)
fi
if [ "${#MODULES[@]}" -eq 0 ]; then
  usage
  exit 1
fi

need_root
need_ubuntu
detect_ip >/dev/null
log "server-bootstrap $VERSION  ip=$SERVER_IP  dry-run=$DRY_RUN  modules=${MODULES[*]}"

# dependency order: run selected modules in a fixed sequence
has() { local m; for m in "${MODULES[@]}"; do [ "$m" = "$1" ] && return 0; done; return 1; }

# Always refresh packages once if we will install anything
if has base || has nginx || has xui || has warp || has dante || has paperclip || has gemini || has cursor || has kimi || has monitoring; then
  apt_update
fi

has base && module_base
has nginx && module_nginx
has warp && module_warp
has xui && module_xui
has dante && module_dante
has paperclip && module_paperclip
has gemini && module_gemini
has cursor && module_cursor
has kimi && module_kimi
has monitoring && module_monitoring

ok "finished. Useful next steps:"
echo "  $ROOT/scripts/check.sh"
if [ -f /root/x-ui-credentials.txt ]; then
  echo "  3x-ui credentials: /root/x-ui-credentials.txt"
fi
if [ -f /root/multilogin-proxy.txt ]; then
  echo "  Multilogin proxy: /root/multilogin-proxy.txt"
fi
if [ -f /root/monitoring-panel-initial-password.txt ]; then
  echo "  Monitoring initial password: /root/monitoring-panel-initial-password.txt"
fi
echo "  Remember: never run  warp-cli mode warp"
