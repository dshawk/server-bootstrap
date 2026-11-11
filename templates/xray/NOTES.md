# Xray routing template

Used as 3x-ui `xrayTemplateConfig`. Placeholders must be filled on the server; never commit real UUIDs or Reality keys.

## Google egress

Traffic for `home-*`, `job-*` and `dshawk-*` (see `__WARP_USERS__`) matching `geosite:google` plus extras (`recaptcha.net`, `doubleclick.net`, `gvt2.com`, `gvt3.com`, `android.com`) and `geoip:google` is sent to the `google-egress` outbound.

`google-egress` is VLESS+TCP+Reality to a dedicated IPv4-only egress host (freedom `sockopt.domainStrategy=UseIPv4`, bound to that host's IPv4). The host's IPv6 must not be used: Google treats it as RU.

The `warp` outbound (`socks 127.0.0.1:40000`) stays defined as a fallback. Do not run `warp-cli mode warp`.

Firewall on the egress host: SSH 22 from anywhere; the proxy port only from the main VPN IPv4.

UDP 443 for those users stays blocked. Default outbound remains `direct`.
