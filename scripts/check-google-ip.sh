#!/bin/bash
# =============================================================================
# check-google-ip.sh — проверка IP нового egress-сервера ДО настройки
#
# Запускать на новом сервере под root:
#   bash check-google-ip.sh
#
# Проверяет:
#   - какой регион Google присваивает IPv4 (нужен EU/US, НЕ RU)
#   - не заблокирован ли IP для Gemini / AI Studio (ошибка 403 = IP сожжён)
#
# Если хоть одна проверка провалена — пересоздайте сервер у хостера
# и проверьте новый IP заново. Настраивать «сожжённый» сервер нет смысла.
# =============================================================================

echo "=== IPv4 сервера ==="
curl -4 -s --max-time 10 ifconfig.me 2>/dev/null || curl -4 -s --max-time 10 api.ipify.org
echo

echo "=== Регион по версии Google (YouTube gl) ==="
GL=$(curl -4 -s --max-time 15 "https://www.youtube.com/" | tr "," "\n" | grep -m1 '"gl"')
echo "$GL"
if echo "$GL" | grep -q '"RU"'; then
  echo "!!! РЕГИОН RU — сервер НЕ ПОДХОДИТ, пересоздавайте"
fi

echo "=== Gemini ==="
CODE_G=$(curl -4 -s --max-time 20 -o /dev/null -w "%{http_code}" "https://gemini.google.com/app")
echo "HTTP $CODE_G"
[ "$CODE_G" = "403" ] && echo "!!! IP ЗАБЛОКИРОВАН для Gemini — сервер НЕ ПОДХОДИТ"

echo "=== AI Studio ==="
CODE_A=$(curl -4 -s --max-time 20 -o /dev/null -w "%{http_code}" "https://aistudio.google.com/")
echo "HTTP $CODE_A"
[ "$CODE_A" = "403" ] && echo "!!! IP ЗАБЛОКИРОВАН для AI Studio — сервер НЕ ПОДХОДИТ"

echo
if [ "$CODE_G" != "403" ] && [ "$CODE_A" != "403" ] && ! echo "$GL" | grep -q '"RU"'; then
  echo ">>> IP ЧИСТЫЙ — можно настраивать (setup-google-egress.sh)"
else
  echo ">>> IP НЕ ПОДХОДИТ — пересоздайте сервер и проверьте снова"
fi
