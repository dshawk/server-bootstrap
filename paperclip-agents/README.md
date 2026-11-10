# Экспорт агентов Paperclip

Это портативный снимок компаний и агентов (без секретов). Его можно хранить в git и периодически обновлять.

## Содержимое

- `index.json` — список компаний и агентов.
- `<компания>/company.json` — метаданные компании.
- `<компания>/agents/<slug>/agent.json` — имя, роль, кому подчиняется, адаптер, модель, включённые навыки. Секреты заменены на `${VAR}`.
- `<компания>/agents/<slug>/AGENTS.md` — инструкция агента.
- `<компания>/package/` — официальный пакет Paperclip (`company export`), его же использует импорт.

## Обновление снимка

На сервере с запущенным Paperclip и сохранённым входом CLI (`npx paperclipai auth whoami --api-base http://127.0.0.1:3100`):

```bash
cd /root/src/server-bootstrap
sudo -u paperclip -H ./scripts/export-paperclip-agents.sh
git add paperclip-agents
git commit -m "Update Paperclip agents export"
git push
```

Секреты (API-ключи, токены) в репозиторий не попадают. После импорта на новом сервере их нужно задать заново (переменные окружения или вход в адаптер).
