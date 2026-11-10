#!/bin/bash
set -euo pipefail
BASE="https://raw.githubusercontent.com/hydraponique/roscomvpn-routing/main"
SUB_BASE="$(cat /etc/roscom-sub-base)"
EXTRA="/etc/roscom-extra-direct.txt"
OUT_DIR="/var/www/roscom"
mkdir -p "$OUT_DIR"
touch "$EXTRA"

INCY_RAW=$(curl -fsSL --max-time 30 "${BASE}/INCY/WHITELIST.JSON")
HAPP_RAW=$(curl -fsSL --max-time 30 "${BASE}/HAPP/WHITELIST.DEEPLINK" | tr -d '\r\n')
case "$HAPP_RAW" in happ://routing/*) ;; *) echo "bad HAPP deeplink" >&2; exit 1 ;; esac

INCY_RAW="$INCY_RAW" HAPP_RAW="$HAPP_RAW" EXTRA="$EXTRA" OUT_DIR="$OUT_DIR" SUB_BASE="$SUB_BASE" python3 - <<'PY'
import base64, hashlib, json, os, time, urllib.request
from urllib.parse import urlparse

extra = []
for line in open(os.environ["EXTRA"]):
    line = line.split("#", 1)[0].strip()
    if not line:
        continue
    if ":" not in line:
        line = "domain:" + line
    extra.append(line)

out_dir = os.environ["OUT_DIR"]
sub_base = os.environ["SUB_BASE"].rstrip("/")

def fetch(url, dest):
    req = urllib.request.Request(url, headers={"User-Agent": "roscom-whitelist-refresh"})
    data = urllib.request.urlopen(req, timeout=60).read()
    if len(data) < 1000:
        raise SystemExit(f"слишком маленький файл {url}")
    tmp = dest + ".tmp"
    open(tmp, "wb").write(data)
    os.replace(tmp, dest)

def patch(profile):
    sites = profile.setdefault("DirectSites", [])
    for item in extra:
        if item not in sites:
            sites.append(item)
    geoip = profile.get("Geoipurl") or ""
    geosite = profile.get("Geositeurl") or ""
    if geoip.startswith("http") and "127.0.0.1" not in geoip and "/routing/geoip.dat" not in geoip:
        fetch(geoip, os.path.join(out_dir, "geoip.dat"))
    if geosite.startswith("http") and "127.0.0.1" not in geosite and "/routing/geosite.dat" not in geosite:
        fetch(geosite, os.path.join(out_dir, "geosite.dat"))
    profile["Geoipurl"] = sub_base + "/routing/geoip.dat?v=3"
    profile["Geositeurl"] = sub_base + "/routing/geosite.dat?v=3"
    profile["RouteOrder"] = "block-direct-proxy"
    profile["UseChunkFiles"] = "false"
    sites = profile.setdefault("DirectSites", [])
    if "geosite:whitelist" in sites and "geosite:WHITELIST" not in sites:
        sites.append("geosite:WHITELIST")
    ips = profile.setdefault("DirectIp", [])
    if "geoip:whitelist" in ips and "geoip:WHITELIST" not in ips:
        ips.append("geoip:WHITELIST")
    for net in (
        "185.73.192.0/22",
        "195.34.20.0/23",
        "46.226.122.0/24",
        "91.212.64.0/24",
        "91.223.93.0/24",
    ):
        if net not in ips:
            ips.append(net)
    host = urlparse(sub_base).hostname
    if host:
        own = host + "/32"
        ips = profile.setdefault("DirectIp", [])
        if own not in ips:
            ips.append(own)
    profile["LastUpdated"] = str(int(time.time()))
    return profile

def write_sha256(path):
    digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
    open(path + ".sha256", "w").write(digest + "\n")
    os.chmod(path + ".sha256", 0o644)

def deeplink(scheme, profile):
    raw = json.dumps(profile, ensure_ascii=False, separators=(",", ":")).encode()
    return scheme + "://routing/onadd/" + base64.b64encode(raw).decode()

incy = patch(json.loads(os.environ["INCY_RAW"]))
open(os.path.join(out_dir, "whitelist.json"), "w").write(json.dumps(incy, ensure_ascii=False, indent=1))
os.chmod(os.path.join(out_dir, "whitelist.json"), 0o644)

prefix, _, payload = os.environ["HAPP_RAW"].rpartition("/")
happ = patch(json.loads(base64.b64decode(payload + "=" * (-len(payload) % 4))))
for name in ("geoip.dat", "geosite.dat"):
    path = os.path.join(out_dir, name)
    if os.path.isfile(path):
        write_sha256(path)

incy_link = deeplink("incy", incy)
happ_link = deeplink("happ", happ)
auto_line = "incy://autorouting/onadd/" + sub_base + "/routing/whitelist.json"
open("/etc/roscom-autorouting-line", "w").write(auto_line + "\n")

def nginx_quote(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'

open("/etc/nginx/conf.d/roscom-routing.conf", "w").write(
    "map $http_user_agent $roscom_routing {\n"
    "    default " + nginx_quote(happ_link) + ";\n"
    '    ~*incy ' + nginx_quote(incy_link) + ";\n"
    "}\n"
    "map $host $roscom_incy {\n"
    "    default " + nginx_quote(incy_link) + ";\n"
    "}\n"
)
open("/etc/nginx/snippets/roscom-whitelist.conf", "w").write(
    "add_header routing $roscom_routing always;\n"
    "add_header autorouting " + nginx_quote(auto_line) + " always;\n"
)
print("direct", incy.get("DirectSites"))
print("geo", incy.get("Geositeurl"))
PY
if systemctl is-active --quiet nginx; then nginx -t && systemctl reload nginx; fi
