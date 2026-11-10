#!/usr/bin/env bash
# Renew the Let's Encrypt shortlived certificate for the server's public IP
# using acme.sh webroot (nginx must already serve /var/www/html on port 80).
# Never uses standalone / never binds port 80 itself.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root" >&2
  exit 1
fi

ACME_HOME="${ACME_HOME:-/root/.acme.sh}"
ACME="${ACME_HOME}/acme.sh"
SERVER_IP="${SERVER_IP:-}"
FORCE="${FORCE:-0}"
WEBROOT="${WEBROOT:-/var/www/html}"

if [ -z "$SERVER_IP" ]; then
  SERVER_IP="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
fi
if [ -z "$SERVER_IP" ]; then
  SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
fi
if [ -z "$SERVER_IP" ]; then
  echo "Cannot detect SERVER_IP" >&2
  exit 1
fi
if [ ! -x "$ACME" ]; then
  echo "acme.sh not found at $ACME" >&2
  exit 1
fi

CERT_DIR="/root/cert/${SERVER_IP}"
mkdir -p "$CERT_DIR" "$WEBROOT/.well-known/acme-challenge"
# Do not stop nginx. Webroot requires it to be up on port 80.

RENEW_ARGS=(--home "$ACME_HOME" --renew -d "$SERVER_IP" --ecc)
if [ "$FORCE" = "1" ]; then
  RENEW_ARGS+=(--force)
fi
# If the cert does not exist yet, issue instead of renew.
if [ ! -s "${CERT_DIR}/fullchain.pem" ]; then
  "$ACME" --home "$ACME_HOME" --issue -d "$SERVER_IP" \
    --webroot "$WEBROOT" \
    --server letsencrypt \
    --certificate-profile shortlived \
    --days 3 \
    --ecc || true
else
  "$ACME" "${RENEW_ARGS[@]}" || true
fi

"$ACME" --home "$ACME_HOME" --install-cert -d "$SERVER_IP" --ecc \
  --key-file "${CERT_DIR}/privkey.pem" \
  --fullchain-file "${CERT_DIR}/fullchain.pem" \
  --reloadcmd "systemctl restart x-ui; systemctl reload nginx"

chmod 600 "${CERT_DIR}/privkey.pem"
chmod 644 "${CERT_DIR}/fullchain.pem"
openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -issuer -dates -subject
