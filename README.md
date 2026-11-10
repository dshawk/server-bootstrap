# server-bootstrap

Скрипт и шаблоны, чтобы поднять **новый** Ubuntu 22.04/24.04 сервер по образцу текущего (VPN на 3x-ui/xray, WARP только как локальный прокси, nginx с SNI, Dante для Multilogin, панель мониторинга, Paperclip, Gemini CLI, Cursor Agent, Kimi Code).

Скрипт идемпотентный: повторный запуск не должен ломать уже настроенное. На **уже работающем** сервере `install.sh` не гоняйте без нужды — он для чистой машины.

## Что ставит `--all`

| Модуль | Что делает |
| --- | --- |
| `--base` | swap 2 ГБ, fail2ban (jail sshd), logrotate, journald не больше 200 МБ, unattended-upgrades (только security) |
| `--nginx` | nginx + `libnginx-mod-stream`, webroot ACME на порту 80, stream SNI на 443 |
| `--warp` | Cloudflare WARP **только** в режиме прокси `127.0.0.1:40000`. Полный туннель запрещён |
| `--xui` | 3x-ui **2.8.10**, Xray-core **26.6.27**, шаблон маршрутизации (Google → WARP, UDP/443 в blocked) для префиксов клиентов, сертификат Let's Encrypt на IP через acme.sh **webroot**, подписка через nginx :2096 и `xui-sub-rewrite` |
| `--dante` | SOCKS5 на порту 18088, пользователь с паролем, файл `/root/multilogin-proxy.txt` (режим 600) |
| `--paperclip` | Node 24, пользователь `paperclip`, `paperclipai@2026.1023.0` как systemd-служба, HTTPS-сайт |
| `--gemini` | `@google/gemini-cli@0.67.0` и обёртка `/usr/local/bin/gemini` через WARP-прокси |
| `--cursor` | Cursor Agent CLI той же сборки, что на текущем сервере, для пользователя `paperclip`, симлинк в `/usr/local/bin` |
| `--kimi` | Kimi Code CLI для root и `paperclip`, симлинк `/usr/local/bin/kimi` |
| `--monitoring` | панель из `vendor/monitoring-panel` (или клон `dshawk/monitoring-panel`), случайный пароль, systemd, fail2ban |

`--paperclip`, `--gemini`, `--cursor` и `--kimi` входят в `--all`.

## Чего в репозитории нет

- Паролей, хешей, UUID клиентов 3x-ui, Reality private keys, ключа Gemini, пароля Multilogin, токенов Cursor/Kimi/Paperclip, закрытых сертификатов.
- Базы `/etc/x-ui/x-ui.db` и клиентов VPN — их переносят отдельно (`scripts/backup-xui.sh` / `restore-xui.sh`).
- Входа в адаптеры Paperclip. После импорта агентов нужно снова залогиниться.

## Требования

- Чистый Ubuntu 22.04 или 24.04, запуск от root, выход в интернет (GitHub, Let's Encrypt, репозитории Cloudflare и NodeSource).
- Открыты входящие порты: **22, 80, 443**, плюс VPN/подписка (на текущем сервере 2096 и 8443–8446), **18088** если нужен Multilogin.
- Порт 80 должен оставаться за nginx: и IP-сертификат, и доменные сертификаты выпускаются через **webroot** `/var/www/html`. Не используйте `acme.sh --standalone` — он конфликтует с nginx/Paperclip (так уже ломалось автопродление).

## DNS, которые нужно создать заранее

| Имя | Тип | Значение |
| --- | --- | --- |
| `ai.example.com` (ваш `DOMAIN_AI`) | A | публичный IPv4 нового сервера |
| `monitoring.example.com` (`DOMAIN_MONITORING`) | A | тот же IPv4 |

Пока записи не указывают на сервер, выпуск доменных сертификатов не удастся (`--skip-cert` отложит этот шаг).

## Установка

```bash
# на новой машине, от root
export ACME_EMAIL=you@example.com
export DOMAIN_AI=ai.example.com
export DOMAIN_MONITORING=monitoring.example.com
# опционально: SERVER_IP, WARP_CLIENT_PREFIXES, SUB_PATHS, ADMIN_IPS

git clone git@github-bootstrap:dshawk/server-bootstrap.git /root/src/server-bootstrap
# или скопируйте дерево вручную, если ключа развёртывания ещё нет

cd /root/src/server-bootstrap
cp env.example /root/server-bootstrap.env
# отредактируйте /root/server-bootstrap.env, chmod 600

# посмотреть план:
./install.sh --all --dry-run

./install.sh --all
```

Можно ставить модули по отдельности, в том же порядке: `--base --nginx --warp --xui --dante --paperclip --gemini --cursor --kimi --monitoring`.

После установки скрипт пишет (только на сервере, chmod 600):

- `/root/x-ui-credentials.txt` — вход в панель 3x-ui
- `/root/multilogin-proxy.txt` — `IP:18088:mlproxy:пароль`
- `/root/monitoring-panel-initial-password.txt` — временный пароль панели, смените сразу

Проверка: `./scripts/check.sh`.

## Модули подробнее

### Сертификат на IP

Let's Encrypt profile `shortlived` (~6 дней), acme.sh, webroot `/var/www/html`, установка в `/root/cert/<IP>/`, `--reloadcmd` перезапускает x-ui и перечитывает nginx. Cron acme.sh четыре раза в сутки. Ручное продление: `./scripts/renew-ip-cert.sh` (при необходимости `FORCE=1`).

### Маршрутизация xray

В шаблоне исходящее соединение `warp` на `127.0.0.1:40000`. Для email клиентов вида `<префикс>-<суффикс>` (по умолчанию префиксы `home`, `job`, `dshawk`):

- домены Google (кроме общего интернета; YouTube в список не входит) идут в WARP;
- UDP 443 для этих клиентов блокируется, чтобы браузер ушёл с QUIC на TCP.

Клиентов скрипт **не создаёт**. Их заводят в панели 3x-ui или переносят из бэкапа базы.

### WARP

Только `warp-cli --accept-tos mode proxy` и порт 40000. **Никогда не выполняйте `warp-cli mode warp`**: полный туннель перехватит маршрут по умолчанию и оборвёт VPN, панель, nginx и SSH. Таймер `warp-proxy-guard` раз в 5 минут возвращает режим прокси, если его сняли.

### Paperclip, Gemini, Cursor, Kimi — вход

Токенов в репозитории нет, на новом сервере нужно войти заново.

- **Paperclip.** Когда служба поднимется: `sudo -u paperclip -H npx paperclipai@2026.1023.0 auth bootstrap-ceo --api-base http://127.0.0.1:3100`, затем импорт агентов (см. ниже).
- **Gemini CLI.** `export GEMINI_API_KEY=...` или интерактивный вход. Команда `gemini` уже идёт через WARP-прокси.
- **Cursor Agent.** `sudo -u paperclip -H cursor-agent login` или переменная `CURSOR_API_KEY`.
- **Kimi Code.** `kimi` и команда `/login` (OAuth Kimi Code или ключ Moonshot). Для пользователя paperclip: `sudo -u paperclip -H /home/paperclip/.kimi-code/bin/kimi`.

После обновления кэша npm Paperclip навык `suggestion-box` / `complain` может включиться снова. Повторно выключить автодобавление: `./scripts/patch-paperclip-feedback-skills.sh`.

## Перенос клиентов VPN со старого сервера

1. На старом: `./scripts/backup-xui.sh /root/backups/x-ui-old.tar.gz` — в архиве база и сертификаты. Файл секретный (в базе UUID и ключи).
2. На новом сначала `./install.sh --all` (чтобы появились 3x-ui, nginx и свежий IP-сертификат).
3. Скопируйте архив и выполните `./scripts/restore-xui.sh /root/backups/x-ui-old.tar.gz`. Скрипт остановит x-ui, подменит базу, пропишет пути к **новому** IP-сертификату и URL подписки, затем запустит службу.
4. Обновите подписку в клиентах (новый IP). Профили Reality/maska/vk переносятся вместе с базой.

## Экспорт и импорт агентов Paperclip

Каталог `paperclip-agents/` — снимок компаний и агентов **без секретов** (имена, роли, кому подчиняется, тип адаптера и модель, инструкции `AGENTS.md`, включённые навыки). Секретные значения заменены на `${VAR}`.

Обновлять снимок периодически (на сервере с уже выполненным `npx paperclipai auth login` / сохранённым `~/.paperclip/auth.json`):

```bash
cd /root/src/server-bootstrap
sudo -u paperclip -H ./scripts/export-paperclip-agents.sh
git add paperclip-agents
git commit -m "Update Paperclip agents export"
git push
```

На новом сервере, когда Paperclip уже запущен и вы вошли как администратор:

```bash
sudo -u paperclip -H ./scripts/import-paperclip-agents.sh dshawk --target new --yes
# или в существующую компанию:
# sudo -u paperclip -H ./scripts/import-paperclip-agents.sh dshawk --target existing -C <company-id> --yes
```

После импорта задайте ключи адаптеров (GEMINI_API_KEY, вход cursor-agent / kimi). Импорт идёт через официальный CLI `paperclipai company import`, не через сырую базу.

Компания `mobile` в снимке есть, но без агентов — так было на исходном сервере.

## Скрипты

| Скрипт | Назначение |
| --- | --- |
| `install.sh` | установка модулей, есть `--dry-run` |
| `scripts/backup-xui.sh` | архив `/etc/x-ui/x-ui.db` и `/root/cert` |
| `scripts/restore-xui.sh` | восстановление базы и правка путей сертификата |
| `scripts/renew-ip-cert.sh` | продлить IP-сертификат (webroot) |
| `scripts/check.sh` | службы, порты, сроки сертификатов, режим WARP |
| `scripts/export-paperclip-agents.sh` | снимок агентов в `paperclip-agents/` |
| `scripts/import-paperclip-agents.sh` | импорт снимка через CLI Paperclip |
| `scripts/patch-paperclip-feedback-skills.sh` | снова выставить `PAPERCLIP_FEEDBACK_SKILL_KEYS=[]` |

## Безопасность

- **Никогда: `warp-cli mode warp`.** Только `mode proxy`.
- IP-сертификат живёт около 6 дней; если автопродление упадёт, его можно перевыпустить из панели мониторинга (у неё свой доменный сертификат, она откроется даже если IP-сертификат истечёт — зайдите без VPN или через Reality/vk/maska).
- Панель 3x-ui и пароли лежат только на сервере. Смените пароль мониторинга сразу после первого входа.
- Ключ развёртывания репозитория: `/root/.ssh/server_bootstrap_deploy`, алиас SSH `github-bootstrap`. Публичный ключ добавляется в GitHub как deploy key с правом записи.

## Лицензия и происхождение шаблонов

Конфиги сняты с рабочего сервера и очищены от адресов, доменов и секретов (плейсхолдеры `__SERVER_IP__`, `__DOMAIN_AI__` и т.д.). `vendor/monitoring-panel` — снимок приватного репозитория `dshawk/monitoring-panel` с теми же плейсхолдерами.
