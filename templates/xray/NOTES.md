# Xray routing template

Used as 3x-ui `xrayTemplateConfig`. Placeholders must be filled on the server; never commit real UUIDs or Reality keys.

## Google egress

All VPN clients, and processes on the main server that use the local proxy, send traffic matching `geosite:google` plus extras (`recaptcha.net`, `doubleclick.net`, `gvt2.com`, `gvt3.com`, `android.com`) and `geoip:google` to the `google-egress` outbound. There is no `user` filter.

`google-egress` is VLESS+TCP+Reality to a dedicated IPv4-only egress host (freedom `sockopt.domainStrategy=UseIPv4`, bound to that host's IPv4). The host's IPv6 must not be used: Google treats the `2a13:7c00::` prefix as RU or HK.

The main server exposes loopback-only inbounds for its own Google/Gemini traffic: SOCKS `127.0.0.1:10808` (`google-local-socks`) and HTTP `127.0.0.1:10809` (`google-local-http`). Non-Google traffic on those inbounds stays `direct`. The `/usr/local/bin/gemini` wrapper and the Дизайнер agent env/curl use these ports, not WARP `:40000`.

The `warp` outbound (`socks 127.0.0.1:40000`) stays defined as a fallback. No routing rule sends Google to it. Do not run `warp-cli mode warp`.

Firewall on the egress host: SSH 22 is key-only and allowed only from the main VPN IPv4 (from the main server: `ssh google-egress2`). The proxy port is allowed only from the main VPN IPv4.

UDP 443 is blocked for all users so browsers fall back from QUIC to TCP. Default outbound remains `direct`.
