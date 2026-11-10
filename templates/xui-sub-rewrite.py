#!/usr/bin/env python3
import base64
import json
import os
import re
import ssl
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = "https://127.0.0.1:" + os.environ.get("PANEL_SUB_PORT", "2097")
LISTEN = ("127.0.0.1", int(os.environ.get("REWRITE_PORT", "2098")))
XHTTP_EXTRA = {
    "xmux": {
        "maxConcurrency": "16-32",
        "maxConnections": 0,
        "cMaxReuseTimes": 0,
        "hMaxRequestTimes": "5000-8000",
        "hMaxReusableSecs": os.environ.get("XHTTP_REUSE_SECS", "7200"),
        "hKeepAlivePeriod": 25,
    }
}
EXTRA_PARAM = "extra=" + urllib.parse.quote(json.dumps(XHTTP_EXTRA, separators=(",", ":")), safe="")
FORWARD_HEADERS = ("User-Agent", "Accept", "Accept-Language", "Host", "X-Forwarded-Host", "X-Forwarded-Proto", "X-Real-IP", "X-Forwarded-For")
HOP_HEADERS = {"content-length", "transfer-encoding", "connection", "content-encoding"}
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE


def add_extra(link):
    import re as _re
    link = _re.sub(r"@([^/?#]+):10443\\b", r"@\\1:443", link)
    if not link.startswith("vless://") or "type=xhttp" not in link:
        return link
    head, sep, frag = link.partition("#")
    if "?" in head:
        base, _, query = head.partition("?")
        parts = [p for p in query.split("&") if p and not p.startswith("extra=")]
        parts.append(EXTRA_PARAM)
        head = base + "?" + "&".join(parts)
    else:
        head = head + "?" + EXTRA_PARAM
    return head + sep + frag


def sub_name(path):
    parts = [part for part in path.split("/") if part]
    if len(parts) >= 2 and parts[0] == "sub":
        return parts[1]
    return ""


def whitelist_names():
    names = set()
    for path in ("/etc/nginx/sites-available/xui-sub.conf", "/etc/nginx/conf.d/xui-sub.conf"):
        try:
            text = open(path).read()
        except FileNotFoundError:
            continue
        match = re.search(r"\^/sub/\(([^)]*)\)", text)
        if match:
            names.update(name for name in match.group(1).split("|") if name)
    return names


def autorouting_line():
    try:
        return open("/etc/roscom-autorouting-line").read().strip()
    except FileNotFoundError:
        return ""


def rewrite(body, path):
    try:
        text = base64.b64decode(body.strip(), validate=True).decode()
    except Exception:
        return body
    if "://" not in text:
        return body
    lines = [add_extra(line) for line in text.split("\n")]
    route = autorouting_line()
    if sub_name(path) in whitelist_names() and route and route not in lines:
        if lines and lines[-1] == "":
            lines.insert(-1, route)
        else:
            lines.append(route)
    return base64.b64encode("\n".join(lines).encode())


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        headers = {h: self.headers[h] for h in FORWARD_HEADERS if self.headers.get(h)}
        req = urllib.request.Request(UPSTREAM + self.path, headers=headers)
        try:
            resp = urllib.request.urlopen(req, context=CTX, timeout=15)
        except urllib.error.HTTPError as e:
            resp = e
        except Exception:
            self.send_error(502)
            return
        body = resp.read()
        if self.path.startswith("/sub/") and resp.status == 200:
            body = rewrite(body, self.path)
        self.send_response(resp.status)
        for k, v in resp.headers.items():
            if k.lower() not in HOP_HEADERS:
                self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(LISTEN, Handler).serve_forever()
