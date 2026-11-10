# Панель мониторинга

Лёгкая веб-панель для VPN-сервера: состояние системы и служб, порты, сроки TLS-сертификатов, статус WARP, кнопки продления сертификатов и перезапуска служб. Работает как systemd-сервис на `127.0.0.1`, снаружи открывается через nginx по HTTPS (поддомен `__DOMAIN_MONITORING__`). Без Docker, Grafana и Prometheus; в простое занимает около 26 МБ RAM.

## Возможности

- Дашборд с автообновлением (~30 с), обратным отсчётом и кнопками «Обновить» / «Обновить сертификаты».
- CPU (включая steal), нагрузка, память, swap, диск, аптайм, сеть.
- Статус служб: x-ui, nginx, paperclip, warp-svc, warp-proxy-guard.timer, fail2ban, danted, xui-sub-rewrite и процесс xray.
- Проверка портов VPN и вспомогательных сервисов.
- Сроки сертификатов: IP-сертификат на портах 2096/8443/8444/45232, `__DOMAIN_AI__`, `__DOMAIN_MONITORING__` (предупреждение, если осталось меньше 48 ч).
- WARP: режим (должен быть proxy), страна выхода, порт `127.0.0.1:40000` и таймер `warp-proxy-guard`.
- Хвост логов acme.sh / certbot / проверки сертификатов.
- Кнопки (с подтверждением): выпуск IP-сертификата Let’s Encrypt, обновление доменных сертификатов, перезапуск x-ui, перезагрузка nginx.
- Вход по логину и паролю (хеш в env-файле), смена пароля в интерфейсе, CSRF, ограничение попыток входа, jail fail2ban.
- Ежедневная проверка сроков сертификатов в 08:00 по Москве (systemd timer).

## Установка

Нужны Python 3 (только стандартная библиотека), nginx, acme.sh (IP-сертификат), certbot (домены), sudo, systemd.

1. Пользователь и каталоги:

       useradd --system --no-create-home --shell /usr/sbin/nologin --user-group monpanel
       mkdir -p /opt/monitoring-panel /etc/monitoring-panel /var/log/monitoring-panel
       install -o root -g monpanel -m 644 app.py /opt/monitoring-panel/app.py
       install -o root -g root -m 755 helper.sh /opt/monitoring-panel/helper.sh
       install -o root -g root -m 755 cert-check.sh /opt/monitoring-panel/cert-check.sh
       chown monpanel:monpanel /var/log/monitoring-panel
       chmod 750 /var/log/monitoring-panel /etc/monitoring-panel
       chmod 770 /etc/monitoring-panel

2. Файл окружения `/etc/monitoring-panel/env` (права `660`, владелец `root:monpanel`). Скопируйте `env.example`, задайте логин, временный пароль и случайный `MON_SECRET`. При первом запуске пароль заменяется на хеш и из файла удаляется.

3. sudoers, systemd, fail2ban, logrotate, journald:

       install -o root -g root -m 440 sudoers/monitoring-panel /etc/sudoers.d/monitoring-panel
       visudo -cf /etc/sudoers.d/monitoring-panel
       install -m 644 systemd/* /etc/systemd/system/
       install -m 644 fail2ban/filter.conf /etc/fail2ban/filter.d/monitoring-panel.conf
       install -m 644 fail2ban/jail.local /etc/fail2ban/jail.d/monitoring-panel.local
       install -m 644 logrotate/monitoring-panel /etc/logrotate.d/monitoring-panel
       install -m 644 logrotate/xray-access /etc/logrotate.d/xray-access
       mkdir -p /etc/systemd/journald.conf.d
       install -m 644 journald/size.conf /etc/systemd/journald.conf.d/size.conf
       systemctl daemon-reload
       systemctl enable --now monitoring-panel.service monitoring-certcheck.timer
       systemctl restart fail2ban systemd-journald

4. nginx: HTTP-виртуальный хост с webroot ACME (`/var/www/html`), затем сертификат (как у `__DOMAIN_AI__`: `certbot certonly --webroot`), затем HTTPS на `127.0.0.1:8448` по образцу `nginx/monitoring.conf`. Запись SNI в существующий stream-блок — см. `nginx/stream-sni.example.conf`. Сначала `nginx -t`, потом `reload`. Не ломайте webroot для IP-сертификата и сайт `__DOMAIN_AI__`.

5. Откройте `https://__DOMAIN_MONITORING__/`, войдите и сразу смените пароль.

## Пароль

- Смена: в панели пункт «Сменить пароль» (нужен текущий, новый не короче 8 символов).
- Сброс: в `/etc/monitoring-panel/env` укажите `MON_PASSWORD=новый` и перезапустите службу (`systemctl restart monitoring-panel`). При старте будет записан новый хеш, открытый пароль из файла исчезнет.

## Кнопки сертификатов

- «Выпустить сертификат IP» — `acme.sh --renew` с `--force` для сертификата на IP, установка в `/root/cert/__SERVER_IP__/`, затем перезапуск x-ui и reload nginx.
- «Обновить сертификаты доменов» — certbot для `__DOMAIN_AI__` и `__DOMAIN_MONITORING__` без принудительного выпуска (чтобы не упереться в лимиты Let’s Encrypt).
- «Перезапустить x-ui» / «Перезагрузить nginx» — как написано; перед каждой командой запрашивается подтверждение.

Привилегированные команды выполняет только `/opt/monitoring-panel/helper.sh` с фиксированными глаголами через sudoers, без произвольного ввода.

## Пути

| Что | Путь |
| --- | --- |
| Приложение | `/opt/monitoring-panel/app.py` |
| Helper | `/opt/monitoring-panel/helper.sh` |
| Проверка сертификатов | `/opt/monitoring-panel/cert-check.sh` |
| Env (секреты, не в git) | `/etc/monitoring-panel/env` |
| Служба | `systemd/monitoring-panel.service` → `/etc/systemd/system/` |
| Таймер проверки сертификатов | `monitoring-certcheck.timer` (08:00 MSK) |
| Логи | `/var/log/monitoring-panel/` |
| nginx | `/etc/nginx/sites-available/monitoring` |
| sudoers | `/etc/sudoers.d/monitoring-panel` |
| fail2ban | `filter.d/monitoring-panel.conf`, `jail.d/monitoring-panel.local` |

Панель слушает только `127.0.0.1:8787`. Снаружи — HTTPS через nginx.
