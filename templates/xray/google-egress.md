# Google-egress: ротация выделенного сервера

Когда Google «перекрашивает» IP egress-хоста (Gemini / AI Studio начинают
отвечать «запрещено по локации»), egress пересоздают на новом сервере.

Схема и правила маршрутизации описаны в `templates/xray/NOTES.md`.
Реальные IP, UUID и Reality-ключи хранятся только на серверах
(на основном — `/root/google-egress/`), в репозитории их нет.

## Порядок действий

### 1. Создать новый сервер у хостера

Ubuntu 22.04/24.04. Локация неважна — важно, какой регион присвоит Google,
а не география (пример: сервер в Хельсинки Google может считать ОАЭ,
а в Риге — США).

### 2. Проверить IP ДО настройки

```bash
ssh root@<НОВЫЙ_IP>
bash check-google-ip.sh     # scripts/check-google-ip.sh
```

Нужно: регион НЕ RU и нет 403 на Gemini/AI Studio. Не прошло —
пересоздать сервер и проверить снова (обычно 1–3 попытки).

### 3. Установить xray

```bash
export GOOGLE_EGRESS_UUID="..."
export GOOGLE_EGRESS_REALITY_PRIVATE_KEY="..."
export GOOGLE_EGRESS_SHORT_ID="..."
export MAIN_SERVER_IP="..."
bash setup-google-egress.sh # scripts/setup-google-egress.sh
```

Скрипт определит IPv4, поставит xray, запишет конфиг и включит автозапуск.
Ключи берутся из env — те же, что в outbound `google-egress` на основном
сервере, чтобы там менялся только адрес.

### 4. Переключить основной сервер

Адрес egress лежит в базе панели 3x-ui (ключ `xrayTemplateConfig`) —
править надо её, а не `bin/config.json` (он пересобирается из шаблона):

```bash
ssh root@<MAIN_SERVER_IP>

sqlite3 /etc/x-ui/x-ui.db \
  "UPDATE settings SET value = replace(value, '<СТАРЫЙ_IP>', '<НОВЫЙ_IP>') WHERE key = 'xrayTemplateConfig';"

systemctl restart x-ui
```

### 5. Проверить цепочку (с основного сервера)

```bash
# регион Google через прокси — должен быть EU/US
curl -s -x http://127.0.0.1:10809 "https://www.youtube.com/" | tr "," "\n" | grep -m1 '"gl"'

# Gemini — 200
curl -s -x http://127.0.0.1:10809 -o /dev/null -w "%{http_code}\n" "https://gemini.google.com/app"

# AI Studio — 302 норма (редирект на логин), 403 — плохо
curl -s -x http://127.0.0.1:10809 -o /dev/null -w "%{http_code}\n" "https://aistudio.google.com/"
```

### 6. Удалить старый egress-сервер в панели хостера

## Откат

Вернуть старый адрес — та же `sqlite3 ... replace(...)` с обратной заменой,
затем `systemctl restart x-ui`. Бэкапы базы: `/etc/x-ui/x-ui.db.bak-*`.

## Подводные камни (проверено на практике)

- `ifconfig.me` отдаёт 403 с некоторых датацентровых IP — это не поломка;
  регион проверяйте через YouTube `"gl"`.
- IPv6 у датацентровых префиксов `2a13:7c00::/32` Google считает RU/HK —
  поэтому в конфиге egress `UseIPv4`, не трогать.
- Cloudflare WARP с этих серверов Google тоже считает RU — не вариант.
- Датацентровый IP может быть регионально «чистым» (US/EU), но заблокирован
  именно для Gemini/AI Studio (403 robot) — поэтому проверка шага 2
  обязательна до настройки.
