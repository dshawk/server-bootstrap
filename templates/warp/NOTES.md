# Cloudflare WARP (только локальный прокси)

На этом сервере WARP нужен **только** как локальный SOCKS/HTTP-прокси `127.0.0.1:40000`.
Через него xray гоняет трафик выбранных клиентов к доменам Google, а Gemini CLI ходит в API.

## Обязательные правила

- Режим: `warp-cli --accept-tos mode proxy`
- Порт: `warp-cli --accept-tos proxy port 40000`
- **Никогда не выполняйте `warp-cli mode warp` и не включайте полный туннель.**
  Полный туннель перехватит маршрут по умолчанию и оборвёт VPN, панель x-ui, nginx и SSH.
- Служба `warp-proxy-guard.timer` каждые 5 минут проверяет режим и возвращает proxy, если его сняли.

## Проверка

```bash
warp-cli --accept-tos settings | grep -i mode
# ожидается: Mode: WarpProxy on port 40000
curl -x http://127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace | grep warp
# ожидается: warp=on
```
