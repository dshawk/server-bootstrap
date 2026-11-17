#!/bin/bash
# =============================================================================
# setup-google-egress.sh — установка xray-egress для Google-трафика
#
# Запускается на НОВОМ чистом сервере (Ubuntu 22.04/24.04) под root.
#
# Секреты НЕ хранятся в репозитории — скрипт требует переменные окружения
# (значения — на основном сервере в /root/google-egress/ или в базе 3x-ui):
#
#   export GOOGLE_EGRESS_UUID="..."              # UUID клиента google-egress
#   export GOOGLE_EGRESS_REALITY_PRIVATE_KEY="..."# Reality private key egress-хоста
#   export GOOGLE_EGRESS_SHORT_ID="..."          # напр. 8 hex-символов
#   export MAIN_SERVER_IP="..."                  # для подсказки в конце
#
#   bash setup-google-egress.sh
#
# ВАЖНО: перед установкой проверьте IP скриптом check-google-ip.sh —
# если регион RU или 403 на Gemini, сервер пересоздают ДО настройки.
# =============================================================================
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "Запустите под root" >&2
  exit 1
fi

: "${GOOGLE_EGRESS_UUID:?задайте GOOGLE_EGRESS_UUID}"
: "${GOOGLE_EGRESS_REALITY_PRIVATE_KEY:?задайте GOOGLE_EGRESS_REALITY_PRIVATE_KEY}"
: "${GOOGLE_EGRESS_SHORT_ID:?задайте GOOGLE_EGRESS_SHORT_ID}"
MAIN_SERVER_IP="${MAIN_SERVER_IP:-__MAIN_SERVER_IP__}"

MY_IP=$(curl -4 -s --max-time 10 ifconfig.me || curl -4 -s --max-time 10 api.ipify.org)
if [ -z "$MY_IP" ]; then
  echo "Не удалось определить IPv4 сервера" >&2
  exit 1
fi
echo ">>> IPv4 сервера: $MY_IP"

# --- 1. Установка xray -------------------------------------------------------
if ! command -v xray >/dev/null 2>&1; then
  echo ">>> Устанавливаю xray..."
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
else
  echo ">>> xray уже установлен: $(xray version | head -1)"
fi

# --- 2. Конфигурация ---------------------------------------------------------
# UUID/ключи должны совпадать с outbound "google-egress" на основном сервере
# (см. xrayTemplateConfig в базе 3x-ui). Меняете здесь — поменяйте и там.
mkdir -p /usr/local/etc/xray
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 44333,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$GOOGLE_EGRESS_UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.microsoft.com:443",
          "xver": 0,
          "serverNames": [
            "www.microsoft.com"
          ],
          "privateKey": "$GOOGLE_EGRESS_REALITY_PRIVATE_KEY",
          "shortIds": [
            "$GOOGLE_EGRESS_SHORT_ID"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ],
        "routeOnly": true
      },
      "tag": "google-egress-in"
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {},
      "sendThrough": "$MY_IP",
      "tag": "direct",
      "streamSettings": {
        "sockopt": {
          "domainStrategy": "UseIPv4"
        }
      }
    }
  ]
}
EOF

# --- 3. Служба (перезаписываем юнит установщика — запуск от user xray) -------
id xray >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin xray
mkdir -p /var/log/xray
cat > /etc/systemd/system/xray.service <<'EOF'
[Unit]
Description=Xray Service
Documentation=https://xtls.github.io/
After=network.target nss-lookup.target

[Service]
User=xray
Group=xray
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=yes
UMask=0077
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000
RuntimeDirectory=xray
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF

chown -R xray:xray /usr/local/etc/xray /var/log/xray
systemctl daemon-reload
systemctl enable --now xray
sleep 2

echo
echo ">>> Статус: $(systemctl is-active xray)"
ss -tlnp | grep 44333 && echo ">>> Порт 44333 слушается — всё готово."
echo
echo "Дальше на ОСНОВНОМ сервере ($MAIN_SERVER_IP) переключите адрес:"
echo "  sqlite3 /etc/x-ui/x-ui.db \"UPDATE settings SET value = replace(value, '<СТАРЫЙ_IP>', '$MY_IP') WHERE key = 'xrayTemplateConfig';\""
echo "  systemctl restart x-ui"
echo
echo "Подробности: templates/xray/google-egress.md"
