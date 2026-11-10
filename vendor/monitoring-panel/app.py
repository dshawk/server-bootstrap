#!/usr/bin/env python3
"""Lightweight monitoring panel for the VPN server. Python 3 stdlib only."""

from __future__ import annotations

import hashlib
import hmac
import html
import json
import os
import re
import secrets
import socket
import ssl
import subprocess
import sys
import threading
import time
import urllib.parse
from datetime import datetime, timezone, timedelta
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

TZ = ZoneInfo("Europe/Moscow")
ENV_PATH = Path(os.environ.get("MON_ENV", "/etc/monitoring-panel/env"))
AUTH_LOG = Path(os.environ.get("MON_AUTH_LOG", "/var/log/monitoring-panel/auth.log"))
BIND = os.environ.get("MON_BIND", "127.0.0.1")
PORT = int(os.environ.get("MON_PORT", "8787"))
HELPER = os.environ.get("MON_HELPER", "/opt/monitoring-panel/helper.sh")
SUDO = "/usr/bin/sudo"
SESSION_TTL = 12 * 3600
LOGIN_CSRF_TTL = 2 * 3600
PBKDF2_ITER = 200_000
LOGIN_MAX = 5
LOGIN_WINDOW = 600
LOCK_SECONDS = 900
STATUS_CACHE_TTL = 12
FORCE_MIN_SEC = 5
CERT_CACHE_TTL = 600
WARP_TRACE_TTL = 600
ACTION_TIMEOUT = {
    "renew-ip": 180,
    "renew-domains": 180,
    "restart-xui": 30,
    "reload-nginx": 20,
}
ALLOWED_ACTIONS = {
    "renew-ip": "Выпустить сертификат IP",
    "renew-domains": "Обновить сертификаты доменов",
    "restart-xui": "Перезапустить x-ui",
    "reload-nginx": "Перезагрузить nginx",
}
SERVICES = [
    "x-ui",
    "nginx",
    "paperclip",
    "warp-svc",
    "warp-proxy-guard.timer",
    "fail2ban",
    "danted",
    "xui-sub-rewrite",
]
PORTS = [
    ("80", "HTTP nginx", 80),
    ("443", "HTTPS / Reality SNI", 443),
    ("2096", "Подписка", 2096),
    ("45232", "Панель x-ui", 45232),
    ("8443", "ios-xhttp", 8443),
    ("8444", "ios-tcp-tls", 8444),
    ("8445", "VPN 8445", 8445),
    ("8446", "VPN 8446", 8446),
    ("18088", "Multilogin SOCKS5", 18088),
]
CERT_LIVE = [
    ("ip-2096", "IP-сертификат :2096", "127.0.0.1", 2096, "__SERVER_IP__"),
    ("ip-8443", "IP-сертификат :8443", "127.0.0.1", 8443, "__SERVER_IP__"),
    ("ip-8444", "IP-сертификат :8444", "127.0.0.1", 8444, "__SERVER_IP__"),
    ("ip-__XUI_WEB_PORT__", "IP-сертификат :__XUI_WEB_PORT__", "127.0.0.1", __XUI_WEB_PORT__, "__SERVER_IP__"),
    ("ai", "__DOMAIN_AI__", "127.0.0.1", 8447, "__DOMAIN_AI__"),
    ("monitoring", "__DOMAIN_MONITORING__", "127.0.0.1", 8448, "__DOMAIN_MONITORING__"),
]

_lock = threading.RLock()
_sessions: dict[str, dict[str, Any]] = {}
_fails: dict[str, list[float]] = {}
_lockout: dict[str, float] = {}
_cpu_sample: tuple[float, dict[str, int]] | None = None
_net_sample: tuple[float, dict[str, tuple[int, int]]] | None = None
_status_cache: tuple[float, dict[str, Any]] | None = None
_cert_cache: tuple[float, list, dict] | None = None
_warp_cache: tuple[float, dict[str, Any]] | None = None
_last_force: float = 0.0
_env: dict[str, str] = {}
_secret = b""
_user = "admin"
_pw_hash = ""


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def now_msk() -> datetime:
    return datetime.now(TZ)


def fmt_msk(dt: datetime | None = None) -> str:
    if dt is None:
        dt = now_msk()
    elif dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(TZ).strftime("%Y-%m-%d %H:%M:%S MSK")


def log_auth(msg: str) -> None:
    line = f"{utcnow().strftime('%Y-%m-%d %H:%M:%S')} {msg}\n"
    try:
        AUTH_LOG.parent.mkdir(parents=True, exist_ok=True)
        with AUTH_LOG.open("a") as f:
            f.write(line)
    except OSError:
        sys.stderr.write(line)


def parse_env(path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    if not path.is_file():
        return data
    for raw in path.read_text(errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        k = k.strip()
        v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        data[k] = v
    return data


def write_env(path: Path, data: dict[str, str]) -> None:
    keys_order = [
        "MON_USER",
        "MON_PASSWORD_HASH",
        "MON_SECRET",
        "MON_BIND",
        "MON_PORT",
    ]
    seen = set()
    lines = [
        "# monitoring-panel config. Do not store a plaintext password here.",
        "# To reset the password, set MON_PASSWORD=... and restart the service.",
    ]
    for k in keys_order:
        if k in data:
            lines.append(f"{k}={data[k]}")
            seen.add(k)
    for k, v in data.items():
        if k in seen or k == "MON_PASSWORD":
            continue
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", k):
            continue
        lines.append(f"{k}={v}")
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text("\n".join(lines) + "\n")
    os.chmod(tmp, 0o660)
    tmp.replace(path)
    try:
        os.chmod(path, 0o660)
    except OSError:
        pass


def hash_password(password: str, salt: bytes | None = None) -> str:
    if salt is None:
        salt = secrets.token_bytes(16)
    dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, PBKDF2_ITER)
    return f"pbkdf2_sha256${PBKDF2_ITER}${salt.hex()}${dk.hex()}"


def verify_password(password: str, stored: str) -> bool:
    try:
        algo, iter_s, salt_hex, dk_hex = stored.split("$", 3)
        if algo != "pbkdf2_sha256":
            return False
        iters = int(iter_s)
        salt = bytes.fromhex(salt_hex)
        expected = bytes.fromhex(dk_hex)
        dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iters)
        return hmac.compare_digest(dk, expected)
    except Exception:
        return False


def load_env() -> None:
    global _env, _secret, _user, _pw_hash
    data = parse_env(ENV_PATH)
    changed = False
    if not data.get("MON_SECRET"):
        data["MON_SECRET"] = secrets.token_hex(32)
        changed = True
    if data.get("MON_PASSWORD") and not data.get("MON_PASSWORD_HASH"):
        data["MON_PASSWORD_HASH"] = hash_password(data["MON_PASSWORD"])
        changed = True
    elif data.get("MON_PASSWORD") and data.get("MON_PASSWORD_HASH"):
        # Fresh reset requested via MON_PASSWORD
        data["MON_PASSWORD_HASH"] = hash_password(data["MON_PASSWORD"])
        changed = True
    if "MON_PASSWORD" in data:
        del data["MON_PASSWORD"]
        changed = True
    if not data.get("MON_USER"):
        data["MON_USER"] = "admin"
        changed = True
    if not data.get("MON_PASSWORD_HASH"):
        raise SystemExit("MON_PASSWORD_HASH missing in env file")
    if changed:
        write_env(ENV_PATH, data)
    _env = data
    _secret = data["MON_SECRET"].encode()
    _user = data["MON_USER"]
    _pw_hash = data["MON_PASSWORD_HASH"]


def update_password(new_password: str) -> None:
    global _pw_hash, _env
    with _lock:
        data = parse_env(ENV_PATH)
        data["MON_USER"] = _user
        data["MON_SECRET"] = data.get("MON_SECRET") or _secret.decode()
        data["MON_PASSWORD_HASH"] = hash_password(new_password)
        data.pop("MON_PASSWORD", None)
        write_env(ENV_PATH, data)
        _env = data
        _pw_hash = data["MON_PASSWORD_HASH"]


def client_ip(handler: BaseHTTPRequestHandler) -> str:
    ip = handler.client_address[0]
    if ip in ("127.0.0.1", "::1"):
        fwd = handler.headers.get("X-Real-IP") or handler.headers.get("X-Forwarded-For", "").split(",")[0].strip()
        if fwd and re.fullmatch(r"[0-9a-fA-F:.]+", fwd):
            return fwd
    return ip


def too_many_failures(ip: str, user: str) -> bool:
    now = time.time()
    with _lock:
        if _lockout.get(user, 0) > now or _lockout.get(ip, 0) > now:
            return True
        times = [t for t in _fails.get(ip, []) if now - t < LOGIN_WINDOW]
        _fails[ip] = times
        return len(times) >= LOGIN_MAX


def record_failure(ip: str, user: str) -> None:
    now = time.time()
    with _lock:
        _fails.setdefault(ip, []).append(now)
        times = [t for t in _fails[ip] if now - t < LOGIN_WINDOW]
        _fails[ip] = times
        if len(times) >= LOGIN_MAX:
            _lockout[ip] = now + LOCK_SECONDS
            _lockout[user] = now + LOCK_SECONDS


def clear_failures(ip: str, user: str) -> None:
    with _lock:
        _fails.pop(ip, None)
        _lockout.pop(ip, None)
        _lockout.pop(user, None)


def new_session(user: str) -> str:
    sid = secrets.token_urlsafe(32)
    with _lock:
        _sessions[sid] = {
            "user": user,
            "csrf": secrets.token_urlsafe(24),
            "created": time.time(),
            "expires": time.time() + SESSION_TTL,
        }
    return sid


def get_session(sid: str | None) -> dict[str, Any] | None:
    if not sid:
        return None
    with _lock:
        sess = _sessions.get(sid)
        if not sess:
            return None
        if sess["expires"] < time.time():
            _sessions.pop(sid, None)
            return None
        sess["expires"] = time.time() + SESSION_TTL
        return sess


def drop_session(sid: str | None) -> None:
    if not sid:
        return
    with _lock:
        _sessions.pop(sid, None)


def drop_other_sessions(keep: str, user: str) -> None:
    with _lock:
        dead = [k for k, v in _sessions.items() if v.get("user") == user and k != keep]
        for k in dead:
            _sessions.pop(k, None)



def parse_cookie_header(raw: str | None) -> dict[str, str]:
    out: dict[str, str] = {}
    if not raw:
        return out
    try:
        c = SimpleCookie()
        c.load(raw)
        for name, morsel in c.items():
            out[name] = morsel.value
    except Exception:
        out = {}
    if out:
        return out
    for part in raw.split(";"):
        if "=" not in part:
            continue
        k, v = part.split("=", 1)
        k, v = k.strip(), v.strip()
        if k:
            out[k] = v
    return out


def make_login_csrf(now: float | None = None) -> str:
    exp = int((now or time.time()) + LOGIN_CSRF_TTL)
    nonce = secrets.token_urlsafe(18)
    body = f"v1.{exp}.{nonce}"
    mac = hmac.new(_secret, body.encode(), hashlib.sha256).hexdigest()
    return f"{body}.{mac}"


def login_csrf_valid(token: str) -> bool:
    if not token or token.count(".") != 3:
        return False
    ver, exp_s, nonce, mac = token.split(".", 3)
    if ver != "v1" or not exp_s.isdigit():
        return False
    if int(exp_s) < int(time.time()):
        return False
    if not re.fullmatch(r"[A-Za-z0-9_-]{8,64}", nonce):
        return False
    if not re.fullmatch(r"[0-9a-f]{64}", mac):
        return False
    body = f"v1.{exp_s}.{nonce}"
    expected = hmac.new(_secret, body.encode(), hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, mac)


def tokens_equal(a: str, b: str) -> bool:
    if not a or not b:
        return False
    ba, bb = a.encode(), b.encode()
    if len(ba) != len(bb):
        return False
    return hmac.compare_digest(ba, bb)


def read_cpu() -> dict[str, int]:
    vals = {}
    with open("/proc/stat") as f:
        for line in f:
            if line.startswith("cpu "):
                parts = line.split()
                # user nice system idle iowait irq softirq steal guest guest_nice
                names = ["user", "nice", "system", "idle", "iowait", "irq", "softirq", "steal", "guest", "guest_nice"]
                for i, name in enumerate(names):
                    if i + 1 < len(parts):
                        vals[name] = int(parts[i + 1])
                break
    return vals


def cpu_percent() -> dict[str, float]:
    global _cpu_sample
    cur = read_cpu()
    now = time.time()
    with _lock:
        prev = _cpu_sample
        _cpu_sample = (now, cur)
    if not prev:
        time.sleep(0.2)
        cur2 = read_cpu()
        now2 = time.time()
        prev_t, prev_c = now, cur
        cur = cur2
        with _lock:
            _cpu_sample = (now2, cur)
    else:
        prev_t, prev_c = prev
        if now - prev_t < 1.0:
            time.sleep(max(0.2, 1.0 - (now - prev_t)))
            cur = read_cpu()
            now = time.time()
            with _lock:
                _cpu_sample = (now, cur)
    total = sum(cur.values()) - sum(prev_c.values())
    if total <= 0:
        return {"usage": 0.0, "steal": 0.0, "idle": 100.0, "iowait": 0.0}
    def d(name: str) -> int:
        return max(0, cur.get(name, 0) - prev_c.get(name, 0))
    return {
        "usage": round(100.0 * (total - d("idle") - d("iowait")) / total, 1),
        "steal": round(100.0 * d("steal") / total, 1),
        "idle": round(100.0 * d("idle") / total, 1),
        "iowait": round(100.0 * d("iowait") / total, 1),
    }


def meminfo() -> dict[str, int]:
    data = {}
    with open("/proc/meminfo") as f:
        for line in f:
            k, v, *rest = line.split()
            data[k.rstrip(":")] = int(v)
    return data


def net_stats() -> dict[str, Any]:
    global _net_sample
    iface_data: dict[str, tuple[int, int]] = {}
    with open("/proc/net/dev") as f:
        for line in f:
            if ":" not in line:
                continue
            name, rest = line.split(":", 1)
            name = name.strip()
            if name == "lo":
                continue
            cols = rest.split()
            rx, tx = int(cols[0]), int(cols[8])
            iface_data[name] = (rx, tx)
    now = time.time()
    rates = {}
    with _lock:
        prev = _net_sample
        _net_sample = (now, iface_data)
    if prev:
        dt = max(0.001, now - prev[0])
        for name, (rx, tx) in iface_data.items():
            prx, ptx = prev[1].get(name, (rx, tx))
            rates[name] = {
                "rx": rx,
                "tx": tx,
                "rx_bps": max(0, int((rx - prx) / dt)),
                "tx_bps": max(0, int((tx - ptx) / dt)),
            }
    else:
        for name, (rx, tx) in iface_data.items():
            rates[name] = {"rx": rx, "tx": tx, "rx_bps": 0, "tx_bps": 0}
    return rates


def loadavg() -> list[float]:
    with open("/proc/loadavg") as f:
        p = f.read().split()
    return [float(p[0]), float(p[1]), float(p[2])]


def uptime_sec() -> float:
    with open("/proc/uptime") as f:
        return float(f.read().split()[0])


def fmt_bytes(n: int) -> str:
    x = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if x < 1024 or unit == "TB":
            if unit == "B":
                return f"{int(x)} {unit}"
            return f"{x:.1f} {unit}"
        x /= 1024
    return f"{n} B"


def fmt_bps(n: int) -> str:
    return f"{fmt_bytes(n)}/s"


def fmt_duration(sec: float) -> str:
    sec = int(sec)
    d, sec = divmod(sec, 86400)
    h, sec = divmod(sec, 3600)
    m, _ = divmod(sec, 60)
    parts = []
    if d:
        parts.append(f"{d} д")
    if h or d:
        parts.append(f"{h} ч")
    parts.append(f"{m} мин")
    return " ".join(parts)


def service_status() -> dict[str, str]:
    try:
        out = subprocess.check_output(
            ["systemctl", "is-active", *SERVICES],
            text=True, stderr=subprocess.STDOUT, timeout=5,
        )
        lines = [ln.strip() for ln in out.splitlines() if ln.strip()]
    except subprocess.CalledProcessError as e:
        lines = [ln.strip() for ln in (e.output or "").splitlines() if ln.strip()]
    except Exception as e:
        return {s: f"error: {e}" for s in SERVICES}
    while len(lines) < len(SERVICES):
        lines.append("unknown")
    return dict(zip(SERVICES, lines[: len(SERVICES)]))


def xray_process() -> dict[str, Any]:
    try:
        out = subprocess.check_output(["pgrep", "-a", "xray"], text=True, timeout=3)
        pids = []
        for line in out.splitlines():
            parts = line.split(None, 1)
            if parts:
                pids.append({"pid": parts[0], "cmd": parts[1] if len(parts) > 1 else "xray"})
        return {"running": bool(pids), "procs": pids}
    except subprocess.CalledProcessError:
        return {"running": False, "procs": []}
    except Exception as e:
        return {"running": False, "error": str(e), "procs": []}


def port_open(port: int, host: str = "127.0.0.1", timeout: float = 0.4) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def live_cert(host: str, port: int, servername: str, timeout: float = 3.0) -> dict[str, Any]:
    ctx = ssl._create_unverified_context()
    try:
        with socket.create_connection((host, port), timeout=timeout) as sock:
            with ctx.wrap_socket(sock, server_hostname=servername) as ssock:
                der = ssock.getpeercert(binary_form=True)
        if not der:
            return {"ok": False, "error": "empty cert"}
        pem = ssl.DER_cert_to_PEM_cert(der)
        proc = subprocess.run(
            ["openssl", "x509", "-noout", "-enddate", "-subject"],
            input=pem, text=True, capture_output=True, timeout=5,
        )
        info: dict[str, Any] = {"ok": proc.returncode == 0, "port": port, "servername": servername}
        for line in (proc.stdout or "").splitlines():
            if line.startswith("notAfter="):
                raw = line.split("=", 1)[1].strip()
                info["not_after_raw"] = raw
                try:
                    dt = datetime.strptime(raw, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=timezone.utc)
                    info["not_after"] = dt.isoformat()
                    info["hours_left"] = round((dt - utcnow()).total_seconds() / 3600, 1)
                    info["expires_label"] = fmt_msk(dt)
                except Exception:
                    info["label"] = raw
            elif line.startswith("subject="):
                info["subject"] = line.split("=", 1)[1].strip()
        if proc.returncode != 0:
            info["error"] = (proc.stderr or "openssl failed").strip()[:200]
        return info
    except Exception as e:
        return {"ok": False, "port": port, "servername": servername, "error": str(e)[:200]}


def warp_status() -> dict[str, Any]:
    info: dict[str, Any] = {"proxy_port": 40000, "reachable": port_open(40000)}
    # Only the Mode line — do not keep or return the rest of `warp-cli settings`.
    try:
        out = subprocess.check_output(
            ["warp-cli", "--accept-tos", "settings"],
            text=True, timeout=5, stderr=subprocess.DEVNULL,
        )
        mode = None
        for line in out.splitlines():
            if "Mode:" in line:
                mode = line.split("Mode:", 1)[1].strip()
                break
        if mode:
            info["mode"] = mode
            info["mode_is_proxy"] = bool(re.search(r"WarpProxy", mode, re.I))
        else:
            info["mode_is_proxy"] = False
    except Exception as e:
        info["mode_error"] = str(e)[:200]
        info["mode_is_proxy"] = False
    try:
        out = subprocess.check_output(
            [
                "systemctl", "show", "warp-proxy-guard.timer",
                "-p", "ActiveState", "-p", "UnitFileState", "--no-pager",
            ],
            text=True, timeout=3, stderr=subprocess.DEVNULL,
        )
        props = {}
        for line in out.splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                props[k.strip()] = v.strip()
        if props.get("ActiveState"):
            info["guard_timer"] = props["ActiveState"]
        if props.get("UnitFileState"):
            info["guard_timer_enabled"] = props["UnitFileState"]
    except Exception as e:
        info["guard_timer_error"] = str(e)[:160]
    if not info["reachable"]:
        return info
    try:
        out = subprocess.check_output(
            [
                "curl", "-sS", "--max-time", "5",
                "-x", "socks5h://127.0.0.1:40000",
                "https://www.cloudflare.com/cdn-cgi/trace",
            ],
            text=True, timeout=8, stderr=subprocess.DEVNULL,
        )
        for line in out.splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                if k in ("ip", "loc", "colo", "warp", "http"):
                    info[k] = v
        if info.get("loc"):
            info["country"] = info["loc"]
        info["trace_ok"] = True
    except Exception as e:
        info["trace_ok"] = False
        info["trace_error"] = str(e)[:200]
    return info


def helper_cmd(action: str, timeout: int = 15) -> tuple[int, str]:
    try:
        proc = subprocess.run(
            [SUDO, "-n", HELPER, action],
            capture_output=True, text=True, timeout=timeout,
        )
        out = (proc.stdout or "") + (("\n" + proc.stderr) if proc.stderr else "")
        return proc.returncode, out.strip()
    except subprocess.TimeoutExpired:
        return 124, "команда превысила время ожидания"
    except Exception as e:
        return 1, str(e)


def collect_status(force: bool = False, force_certs: bool = False) -> dict[str, Any]:
    global _status_cache, _cert_cache, _warp_cache, _last_force
    now = time.time()
    with _lock:
        if force or force_certs:
            if now - _last_force < FORCE_MIN_SEC:
                force = False
                force_certs = False
            else:
                _last_force = now
                if force_certs:
                    _cert_cache = None
                    _warp_cache = None
        if not force and _status_cache and now - _status_cache[0] < STATUS_CACHE_TTL:
            cached = dict(_status_cache[1])
            cached["cached"] = True
            return cached
    mem = meminfo()
    total = mem.get("MemTotal", 1) * 1024
    avail = mem.get("MemAvailable", 0) * 1024
    used = total - avail
    stotal = mem.get("SwapTotal", 0) * 1024
    sfree = mem.get("SwapFree", 0) * 1024
    sused = stotal - sfree
    st = os.statvfs("/")
    dtotal = st.f_frsize * st.f_blocks
    dfree = st.f_frsize * st.f_bavail
    dused = dtotal - dfree
    cpu = cpu_percent()
    ports = []
    for key, label, port in PORTS:
        ports.append({"id": key, "label": label, "port": port, "open": port_open(port)})

    now_ts = time.time()
    with _lock:
        certs_cached = _cert_cache if _cert_cache and now_ts - _cert_cache[0] < CERT_CACHE_TTL else None
        warp_cached = _warp_cache if _warp_cache and now_ts - _warp_cache[0] < WARP_TRACE_TTL else None
    if certs_cached:
        certs, helper = certs_cached[1], certs_cached[2]
    else:
        certs = []
        for cid, label, host, port, sni in CERT_LIVE:
            try:
                info = live_cert(host, port, sni)
            except Exception as e:
                info = {"ok": False, "error": str(e)[:200], "port": port, "servername": sni}
            info.update({"id": cid, "label": label})
            certs.append(info)
        rc, raw = helper_cmd("cert-status", timeout=15)
        helper: dict[str, Any] = {}
        if rc == 0:
            try:
                helper = json.loads(raw)
            except json.JSONDecodeError:
                helper = {"error": "bad json from helper", "raw": raw[:500]}
        else:
            helper = {"error": raw[:800] or "helper cert-status failed", "rc": rc}
        with _lock:
            _cert_cache = (time.time(), certs, helper)
    if warp_cached:
        warp = warp_cached[1]
        # still do a cheap reachability check
        warp = dict(warp)
        warp["reachable"] = port_open(40000)
    else:
        try:
            warp = warp_status()
        except Exception as e:
            warp = {"proxy_port": 40000, "reachable": port_open(40000), "trace_error": str(e)[:200]}
        with _lock:
            _warp_cache = (time.time(), warp)

    status = {
        "time": fmt_msk(),
        "cpu": cpu,
        "load": loadavg(),
        "memory": {
            "total": total, "used": used, "available": avail,
            "percent": round(100.0 * used / total, 1) if total else 0,
            "total_h": fmt_bytes(total), "used_h": fmt_bytes(used), "available_h": fmt_bytes(avail),
        },
        "swap": {
            "total": stotal, "used": sused,
            "percent": round(100.0 * sused / stotal, 1) if stotal else 0,
            "total_h": fmt_bytes(stotal), "used_h": fmt_bytes(sused),
        },
        "disk": {
            "total": dtotal, "used": dused, "free": dfree,
            "percent": round(100.0 * dused / dtotal, 1) if dtotal else 0,
            "total_h": fmt_bytes(dtotal), "used_h": fmt_bytes(dused), "free_h": fmt_bytes(dfree),
        },
        "uptime": {"seconds": uptime_sec(), "label": fmt_duration(uptime_sec())},
        "net": net_stats(),
        "services": service_status(),
        "xray": xray_process(),
        "ports": ports,
        "certs_live": certs,
        "helper": helper,
        "warp": warp,
        "cached": False,
        "certs_cached": bool(certs_cached) and not force_certs,
        "warp_cached": bool(warp_cached) and not force_certs,
    }
    with _lock:
        _status_cache = (time.time(), status)
    return status


def cert_class(hours_left: float | None) -> str:
    if hours_left is None:
        return "unknown"
    if hours_left <= 0:
        return "bad"
    if hours_left < 48:
        return "bad"
    if hours_left < 72:
        return "warn"
    return "ok"


PAGE_CSS = """
:root { --bg:#0f1419; --card:#1a222c; --ink:#e7eef6; --muted:#8aa0b5; --line:#2a3644;
  --ok:#3dd68c; --warn:#f5c14a; --bad:#ff6b6b; --btn:#2a6df4; --btn2:#334155; }
*{box-sizing:border-box}
body{margin:0;font:14px/1.45 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;background:var(--bg);color:var(--ink)}
header{display:flex;justify-content:space-between;align-items:center;padding:16px 20px;border-bottom:1px solid var(--line);position:sticky;top:0;background:var(--bg);z-index:2}
h1{font-size:18px;margin:0}
h2{font-size:13px;text-transform:uppercase;letter-spacing:.04em;color:var(--muted);margin:0 0 10px}
main{padding:16px 20px 40px;display:grid;gap:16px;max-width:1100px;margin:0 auto}
.grid{display:grid;gap:12px;grid-template-columns:repeat(auto-fit,minmax(220px,1fr))}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px}
.metric{font-size:22px;font-weight:650}
.sub{color:var(--muted);font-size:12px;margin-top:4px}
#tsbar{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-top:6px}
#tsbar button{padding:4px 10px;font-size:12px}
#banner{margin:0 auto;max-width:1100px;padding:0 20px}
#banner.show{display:block;margin-top:12px;margin-bottom:0}
#banner a{color:#fff;text-decoration:underline}
.ok{color:var(--ok)} .warn{color:var(--warn)} .bad{color:var(--bad)} .unknown{color:var(--muted)}
.row{display:flex;justify-content:space-between;gap:8px;padding:6px 0;border-bottom:1px solid var(--line)}
.row:last-child{border-bottom:0}
.dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:6px;background:var(--muted);vertical-align:middle}
.dot.ok{background:var(--ok)} .dot.bad{background:var(--bad)} .dot.warn{background:var(--warn)}
.btns{display:flex;flex-wrap:wrap;gap:8px}
button,a.btn{background:var(--btn);color:#fff;border:0;border-radius:8px;padding:8px 12px;cursor:pointer;text-decoration:none;font:inherit}
button.sec,a.sec{background:var(--btn2)}
button:disabled{opacity:.5;cursor:wait}
.nav a{color:var(--muted);margin-left:12px}
form.login{max-width:360px;margin:10vh auto;background:var(--card);padding:24px;border-radius:12px;border:1px solid var(--line)}
label{display:block;margin:10px 0 4px;color:var(--muted)}
input{width:100%;padding:9px 10px;border-radius:8px;border:1px solid var(--line);background:#0f1419;color:var(--ink);font:inherit}
.err{background:#3a1a1a;color:#ffb4b4;padding:8px 10px;border-radius:8px;margin:0 0 12px}
.okbox{background:#143325;color:#baf5d2;padding:8px 10px;border-radius:8px;margin:0 0 12px}
pre{white-space:pre-wrap;background:#0b0f13;padding:12px;border-radius:8px;overflow:auto;max-height:320px;font-size:12px}
.muted{color:var(--muted)}
"""

LOGIN_HTML = """<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Вход — мониторинг</title><style>""" + PAGE_CSS + """</style></head><body>
<form class="login" method="post" action="/login" autocomplete="current-password">
<h1>Мониторинг сервера</h1>
<p class="muted">__DOMAIN_MONITORING__</p>
@@ERROR@@
<input type="hidden" name="csrf" value="@@CSRF@@">
<label>Логин</label><input name="username" required autofocus>
<label>Пароль</label><input name="password" type="password" required>
<p style="margin-top:16px"><button type="submit">Войти</button></p>
</form></body></html>
"""

PASSWORD_HTML = """<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Смена пароля</title><style>""" + PAGE_CSS + """</style></head><body>
<header><h1>Смена пароля</h1><nav class="nav"><a href="/">К панели</a></nav></header>
<main><form class="card" method="post" action="/password" style="max-width:420px">
@@FLASH@@
<input type="hidden" name="csrf" value="@@CSRF@@">
<label>Текущий пароль</label><input name="current" type="password" required>
<label>Новый пароль (не менее 8 символов)</label><input name="new" type="password" required minlength="8">
<label>Повтор нового пароля</label><input name="new2" type="password" required minlength="8">
<p style="margin-top:16px"><button type="submit">Сохранить</button></p>
</form></main></body></html>
"""

DASH_HTML = """<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Мониторинг сервера</title><style>""" + PAGE_CSS + """</style></head><body>
<header>
  <div>
    <h1>Мониторинг сервера</h1>
    <div class="sub" id="tsbar">
      <span id="ts-line">загрузка…</span>
      <button type="button" class="sec" id="btn-refresh">Обновить</button>
      <button type="button" class="sec" id="btn-refresh-certs">Обновить сертификаты</button>
    </div>
  </div>
  <nav class="nav">
    <a href="/password">Сменить пароль</a>
    <form method="post" action="/logout" style="display:inline">
      <input type="hidden" name="csrf" value="@@CSRF@@">
      <button class="sec" type="submit">Выйти</button>
    </form>
  </nav>
</header>
<div id="banner" hidden></div>
<main>
<section class="grid" id="metrics"></section>
<section class="card"><h2>Сервисы</h2><div id="services"></div></section>
<section class="card"><h2>Порты</h2><div id="ports"></div></section>
<section class="card"><h2>Сертификаты</h2><div id="certs"></div></section>
<section class="card"><h2>WARP</h2><div id="warp"></div></section>
<section class="card"><h2>Действия</h2>
  <p class="muted">Перед каждой командой будет запрос подтверждения. Принудительное обновление IP-сертификата обращается к Let's Encrypt; сертификаты доменов обновляются только если срок подходит к концу.</p>
  <div class="btns">
    <button data-action="renew-ip" data-confirm="Выпустить и установить новый IP-сертификат Let's Encrypt, затем перезапустить x-ui и перезагрузить nginx?">Выпустить сертификат IP</button>
    <button data-action="renew-domains" data-confirm="Обновить сертификаты __DOMAIN_AI__ и __DOMAIN_MONITORING__ (без принудительного выпуска, если срок ещё не подошёл) и перезагрузить nginx?">Обновить сертификаты доменов</button>
    <button class="sec" data-action="restart-xui" data-confirm="Перезапустить службу x-ui? Активные VPN-сессии на короткое время оборвутся.">Перезапустить x-ui</button>
    <button class="sec" data-action="reload-nginx" data-confirm="Проверить конфиг и перезагрузить nginx?">Перезагрузить nginx</button>
  </div>
  <pre id="out" hidden></pre>
</section>
<section class="card"><h2>Последние строки acme.sh / renew</h2><pre id="acmelog" class="muted">нет логов</pre></section>
</main>
<script>
const CSRF = @@CSRF_JSON@@;
function esc(s){
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}
function cls(p, warn, bad){ if(p==null) return 'unknown'; if(p>=bad) return 'bad'; if(p>=warn) return 'warn'; return 'ok'; }
function certCls(h){ if(h==null) return 'unknown'; if(h<=0 || h<48) return 'bad'; if(h<72) return 'warn'; return 'ok'; }
function hoursLabel(h){ if(h==null) return 'н/д'; if(h<=0) return 'истёк'; const d=Math.floor(h/24), rh=Math.round(h-d*24); return d? (d+' д '+rh+' ч') : (Math.round(h)+' ч'); }
function fill(id, html){
  const el = document.getElementById(id);
  if(!el) return;
  el.innerHTML = html || '<div class="muted">нет данных</div>';
}
function safe(id, fn){
  try { fill(id, fn()); }
  catch(e){ fill(id, '<div class="err">Ошибка отображения: '+esc(e && e.message ? e.message : e)+'</div>'); }
}
function render(s){
  s = s || {};

  safe('metrics', function(){
    const cpu = s.cpu || {};
    const mem = s.memory || {};
    const sw = s.swap || {};
    const dk = s.disk || {};
    const up = s.uptime || {};
    const stealC = cls(cpu.steal, 10, 25);
    const cpuC = cls(cpu.usage, 80, 95);
    const memC = cls(mem.percent, 80, 90);
    const swC = sw.total ? cls(sw.percent, 40, 80) : 'ok';
    const dkC = cls(dk.percent, 80, 90);
    let net = '';
    const names = Object.keys(s.net || {});
    for (const n of names){ const v = s.net[n] || {}; net += n+': ↓ '+(v.rx_bps||0)+' B/s ↑ '+(v.tx_bps||0)+' B/s  '; }
    const load = (s.load || []).map(function(x){ return Number(x).toFixed(2); }).join(', ');
    return '<div class="card"><div class="sub">CPU / steal</div><div class="metric '+cpuC+'">'+(cpu.usage==null?'н/д':cpu.usage+'%')+'</div>'
      + '<div class="sub">steal <span class="'+stealC+'">'+(cpu.steal==null?'н/д':cpu.steal+'%')+'</span> · load '+esc(load)+'</div></div>'
      + '<div class="card"><div class="sub">Память</div><div class="metric '+memC+'">'+(mem.percent==null?'н/д':mem.percent+'%')+'</div>'
      + '<div class="sub">'+esc(mem.used_h||'')+' из '+esc(mem.total_h||'')+' · свободно '+esc(mem.available_h||'')+'</div></div>'
      + '<div class="card"><div class="sub">Swap</div><div class="metric '+swC+'">'+(sw.percent==null?'н/д':sw.percent+'%')+'</div>'
      + '<div class="sub">'+esc(sw.used_h||'')+' из '+esc(sw.total_h||'')+'</div></div>'
      + '<div class="card"><div class="sub">Диск /</div><div class="metric '+dkC+'">'+(dk.percent==null?'н/д':dk.percent+'%')+'</div>'
      + '<div class="sub">'+esc(dk.used_h||'')+' из '+esc(dk.total_h||'')+' · свободно '+esc(dk.free_h||'')+'</div></div>'
      + '<div class="card"><div class="sub">Аптайм</div><div class="metric">'+esc(up.label||'н/д')+'</div>'
      + '<div class="sub">'+esc(net||'сеть: н/д')+'</div></div>';
  });
  safe('services', function(){
    const svc = Object.entries(s.services || {}).map(function(pair){
      const n = pair[0], st = pair[1];
      const ok = st === 'active';
      return '<div class="row"><span><span class="dot '+(ok?'ok':'bad')+'"></span>'+esc(n)+'</span><span class="'+(ok?'ok':'bad')+'">'+esc(st)+'</span></div>';
    }).join('');
    const xr = s.xray && s.xray.running;
    const xline = '<div class="row"><span><span class="dot '+(xr?'ok':'bad')+'"></span>xray (процесс)</span><span class="'+(xr?'ok':'bad')+'">'+(xr?'работает':'нет')+'</span></div>';
    return (svc || '<div class="muted">нет данных о службах</div>') + xline;
  });
  safe('ports', function(){
    const rows = (s.ports || []).map(function(p){
      return '<div class="row"><span><span class="dot '+(p.open?'ok':'bad')+'"></span>'+esc(p.label)+'</span><span class="'+(p.open?'ok':'bad')+'">'+esc(p.port)+' '+(p.open?'слушает':'закрыт')+'</span></div>';
    }).join('');
    return rows || '<div class="muted">нет данных о портах</div>';
  });
  safe('certs', function(){
    const live = (s.certs_live || []).map(function(c){
      const cl = certCls(c.hours_left);
      const when = c.expires_label || c.not_after_raw || c.error || 'нет данных';
      const left = c.ok ? (esc(when)+' · осталось '+hoursLabel(c.hours_left)) : ('ошибка: '+esc(c.error||'н/д'));
      return '<div class="row"><span>'+esc(c.label)+'</span><span class="'+cl+'">'+left+'</span></div>';
    }).join('');
    const files = ((s.helper || {}).files) || {};
    const fileRows = Object.entries(files).map(function(pair){
      const k = pair[0], v = pair[1] || {};
      const cl = certCls(v.hours_left);
      const when = v.not_after || v.not_after_raw || v.error || '';
      const text = v.ok ? (esc(when)+' · '+hoursLabel(v.hours_left)) : esc(v.error||'нет');
      return '<div class="row"><span>Файл '+esc(k)+'</span><span class="'+cl+'">'+text+'</span></div>';
    }).join('');
    const acme = (s.helper || {}).acme || {};
    const acmeLine = acme.next_renew ? ('<div class="row"><span>Следующее автопродление IP</span><span>'+esc(acme.next_renew)+' UTC (через '+esc(acme.renewal_days||'?')+' дн.)</span></div>') : '';
    const err = (s.helper && s.helper.error) ? ('<div class="err">'+esc(s.helper.error)+'</div>') : '';
    return live + fileRows + acmeLine + err || '<div class="muted">нет данных о сертификатах</div>';
  });
  safe('warp', function(){
    const w = s.warp || {};
    const svc = s.services || {};
    let html = '<div class="row"><span>Прокси 127.0.0.1:40000</span><span class="'+(w.reachable?'ok':'bad')+'">'+(w.reachable?'доступен':'недоступен')+'</span></div>';
    const mode = w.mode || w.mode_error || 'н/д';
    const modeOk = !!w.mode_is_proxy;
    html += '<div class="row"><span>Режим</span><span class="'+(modeOk?'ok':'bad')+'">'+esc(mode)+(modeOk?'':' (нужен proxy)')+'</span></div>';
    const country = w.country || w.loc || '';
    if(w.ip || country){
      html += '<div class="row"><span>Страна выхода</span><span>'+esc(country||'н/д')+(w.colo?(' · '+esc(w.colo)):'')+(w.warp?(' · warp='+esc(w.warp)):'')+(w.ip?(' · '+esc(w.ip)):'')+'</span></div>';
    } else if(w.trace_error){ html += '<div class="muted">'+esc(w.trace_error)+'</div>'; }
    const gt = w.guard_timer || svc['warp-proxy-guard.timer'] || 'н/д';
    const ge = w.guard_timer_enabled || '';
    const gtOk = gt === 'active' && (!ge || ge === 'enabled');
    html += '<div class="row"><span>warp-proxy-guard.timer</span><span class="'+(gtOk?'ok':'bad')+'">'+esc(gt)+(ge?(' · '+esc(ge)):'')+'</span></div>';
    return html;
  });
  try {
    const logs = ((s.helper || {}).logs) || {};
    const keys = Object.keys(logs);
    const box = document.getElementById('acmelog');
    if(box){
      box.textContent = keys.length ? keys.map(function(k){ return '===== '+k+' =====\\n'+logs[k]; }).join('\\n') : 'нет логов (acme.sh ещё не писал в журнал после настройки)';
    }
  } catch(e) {
    const box = document.getElementById('acmelog');
    if(box) box.textContent = 'Ошибка отображения лога: '+(e && e.message ? e.message : e);
  }
}
var POLL_MS = 30000;
var FORCE_MIN_MS = 5000;
var inflight = false;
var lastUpdated = '';
var nextAt = 0;
var lastForceAt = 0;

function showBanner(kind, html){
  const b = document.getElementById('banner');
  if(!b) return;
  if(!html){ b.hidden = true; b.className = ''; b.innerHTML = ''; return; }
  b.hidden = false;
  b.className = (kind === 'ok' ? 'okbox' : 'err') + ' show';
  b.innerHTML = html;
}
function sessionExpired(){
  showBanner('err', 'Сессия истекла, <a href="/login">войдите снова</a>');
}
function tick(){
  const el = document.getElementById('ts-line');
  if(!el) return;
  if(!lastUpdated){
    el.textContent = inflight ? 'обновление…' : 'загрузка…';
    return;
  }
  const left = nextAt ? Math.max(0, Math.ceil((nextAt - Date.now()) / 1000)) : 0;
  el.textContent = 'Обновлено ' + lastUpdated + ' · следующее через ' + left + ' с';
}
function setButtons(busy){
  ['btn-refresh','btn-refresh-certs'].forEach(function(id){
    const b = document.getElementById(id);
    if(b) b.disabled = !!busy;
  });
}
async function refresh(opts){
  opts = opts || {};
  if(inflight) return;
  var force = !!opts.force;
  var certs = !!opts.certs;
  if(force && (Date.now() - lastForceAt) < FORCE_MIN_MS){
    force = false;
    certs = false;
  }
  inflight = true;
  if(force) lastForceAt = Date.now();
  setButtons(true);
  tick();
  try {
    var q = [];
    if(force) q.push('fresh=1');
    if(certs) q.push('certs=1');
    const r = await fetch('/api/status' + (q.length ? ('?' + q.join('&')) : ''), {
      credentials: 'same-origin',
      cache: 'no-store',
      redirect: 'manual'
    });
    if(r.type === 'opaqueredirect' || r.status === 301 || r.status === 302 || r.status === 401 || r.status === 0){
      sessionExpired();
      return;
    }
    const ct = (r.headers.get('content-type') || '');
    if(ct.indexOf('json') < 0){
      sessionExpired();
      return;
    }
    if(!r.ok) throw new Error('HTTP ' + r.status);
    const data = await r.json();
    showBanner('', '');
    render(data);
    lastUpdated = data.time || '';
    nextAt = Date.now() + POLL_MS;
    tick();
  } catch(e) {
    const msg = (e && e.message) ? e.message : String(e);
    showBanner('err', 'Не удалось обновить: ' + esc(msg) + '. Повторю автоматически.');
  } finally {
    inflight = false;
    setButtons(false);
    tick();
  }
}
document.getElementById('btn-refresh').addEventListener('click', function(){ refresh({force:true}); });
document.getElementById('btn-refresh-certs').addEventListener('click', function(){ refresh({force:true, certs:true}); });
document.addEventListener('visibilitychange', function(){
  if(document.visibilityState === 'visible') refresh();
});
setInterval(tick, 1000);
setInterval(function(){
  if(document.visibilityState === 'hidden') return;
  if(nextAt && Date.now() >= nextAt) refresh();
}, 1000);
document.querySelectorAll('button[data-action]').forEach(function(btn){
  btn.addEventListener('click', async function(){
    if(!confirm(btn.getAttribute('data-confirm'))) return;
    const all = Array.prototype.slice.call(document.querySelectorAll('button[data-action]'));
    all.forEach(function(b){ b.disabled = true; });
    const pre = document.getElementById('out'); pre.hidden = false; pre.textContent = 'Выполняется: '+btn.dataset.action+' ...';
    try{
      const r = await fetch('/action', {method:'POST', credentials:'same-origin', redirect:'manual', headers:{'Content-Type':'application/x-www-form-urlencoded','X-CSRF-Token':CSRF}, body:'action='+encodeURIComponent(btn.dataset.action)+'&csrf='+encodeURIComponent(CSRF)});
      if(r.type === 'opaqueredirect' || r.status === 401){ sessionExpired(); return; }
      pre.textContent = await r.text();
    }catch(e){ pre.textContent = String(e); }
    all.forEach(function(b){ b.disabled = false; });
    refresh({force:true});
  });
});
refresh();
</script></body></html>
"""


def page_login(error: str, csrf: str) -> str:
    err = f'<div class="err">{html.escape(error)}</div>' if error else ""
    return LOGIN_HTML.replace("@@ERROR@@", err).replace("@@CSRF@@", html.escape(csrf))


def page_password(csrf: str, flash: str = "", ok: bool = False) -> str:
    box = ""
    if flash:
        box = f'<div class="{"okbox" if ok else "err"}">{html.escape(flash)}</div>'
    return PASSWORD_HTML.replace("@@CSRF@@", html.escape(csrf)).replace("@@FLASH@@", box)


def page_dash(csrf: str) -> str:
    return DASH_HTML.replace("@@CSRF@@", html.escape(csrf)).replace("@@CSRF_JSON@@", json.dumps(csrf))


class Handler(BaseHTTPRequestHandler):
    server_version = "monpanel/1.0"

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write("%s - %s\n" % (fmt_msk(), fmt % args))

    def _sid(self) -> str | None:
        return parse_cookie_header(self.headers.get("Cookie")).get("mon_session")

    def _sess(self) -> dict[str, Any] | None:
        return get_session(self._sid())

    def _send(self, code: int, body: bytes, content_type: str, headers: list[tuple[str, str]] | None = None) -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        if headers:
            for k, v in headers:
                self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _html(self, code: int, text: str, headers: list[tuple[str, str]] | None = None) -> None:
        self._send(code, text.encode(), "text/html; charset=utf-8", headers)

    def _text(self, code: int, text: str) -> None:
        self._send(code, text.encode(), "text/plain; charset=utf-8")

    def _cookie(self, sid: str | None, clear: bool = False) -> str:
        # Secure is set because nginx always terminates TLS in front of us.
        parts = [
            f"mon_session={sid or ''}",
            "Path=/",
            "HttpOnly",
            "Secure",
            "SameSite=Strict",
        ]
        if clear:
            parts.append("Max-Age=0")
        else:
            parts.append(f"Max-Age={SESSION_TTL}")
        return "; ".join(parts)

    def _csrf_cookie(self, token: str | None, clear: bool = False) -> str:
        # Double-submit login token. Lax so a normal form POST from this site
        # always includes it; signed so it survives process restarts.
        parts = [
            f"mon_csrf={token or ''}",
            "Path=/",
            "HttpOnly",
            "Secure",
            "SameSite=Lax",
        ]
        if clear:
            parts.append("Max-Age=0")
        else:
            parts.append(f"Max-Age={LOGIN_CSRF_TTL}")
        return "; ".join(parts)

    def _login_csrf(self) -> tuple[str, list[tuple[str, str]]]:
        cookies = parse_cookie_header(self.headers.get("Cookie"))
        existing = cookies.get("mon_csrf") or ""
        if login_csrf_valid(existing):
            token = existing
        else:
            token = make_login_csrf()
        headers = [("Set-Cookie", self._csrf_cookie(token))]
        # Drop the old pre-login cookie name if a browser still has it.
        if cookies.get("mon_login"):
            headers.append(
                ("Set-Cookie", "mon_login=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0")
            )
        return token, headers

    def _login_posted_csrf(self, posted: str) -> bool:
        cookie = parse_cookie_header(self.headers.get("Cookie")).get("mon_csrf") or ""
        if not tokens_equal(posted, cookie):
            return False
        return login_csrf_valid(posted)

    def _require(self) -> dict[str, Any] | None:
        sess = self._sess()
        if sess and not sess.get("login"):
            return sess
        return None

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", "0") or 0)
        if length < 0 or length > 4096:
            return b""
        return self.rfile.read(length) if length else b""

    def _form(self) -> dict[str, str]:
        body = self._read_body().decode("utf-8", "replace")
        q = urllib.parse.parse_qs(body, keep_blank_values=True)
        return {k: v[-1] if v else "" for k, v in q.items()}

    def _csrf_ok(self, sess: dict[str, Any], form: dict[str, str]) -> bool:
        token = form.get("csrf") or self.headers.get("X-CSRF-Token") or ""
        return bool(token) and hmac.compare_digest(sess.get("csrf", ""), token)

    def do_HEAD(self) -> None:
        self.do_GET()

    def do_GET(self) -> None:
        path = urllib.parse.urlparse(self.path).path
        if path == "/login":
            if self._require():
                self.send_response(302)
                self.send_header("Location", "/")
                self.end_headers()
                return
            token, headers = self._login_csrf()
            self._html(200, page_login("", token), headers)
            return
        sess = self._require()
        if not sess:
            if path == "/api/status":
                self._text(401, "unauthorized")
                return
            self.send_response(302)
            self.send_header("Location", "/login")
            self.end_headers()
            return
        if path == "/":
            self._html(200, page_dash(sess["csrf"]))
            return
        if path == "/password":
            self._html(200, page_password(sess["csrf"]))
            return
        if path == "/api/status":
            qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            def flag(name: str) -> bool:
                return (qs.get(name, [""])[-1] or "").lower() in ("1", "true", "yes")
            body = json.dumps(
                collect_status(force=flag("fresh"), force_certs=flag("certs")),
                ensure_ascii=False,
            ).encode()
            self._send(200, body, "application/json; charset=utf-8")
            return
        self._text(404, "not found")

    def do_POST(self) -> None:
        path = urllib.parse.urlparse(self.path).path
        if path == "/login":
            self._post_login()
            return
        sess = self._require()
        if not sess:
            self._text(401, "unauthorized")
            return
        form = self._form()
        if not self._csrf_ok(sess, form):
            self._text(403, "bad csrf")
            return
        if path == "/logout":
            drop_session(self._sid())
            self.send_response(302)
            self.send_header("Set-Cookie", self._cookie(None, clear=True))
            self.send_header("Location", "/login")
            self.end_headers()
            return
        if path == "/password":
            self._post_password(sess, form)
            return
        if path == "/action":
            self._post_action(form)
            return
        self._text(404, "not found")

    def _post_login(self) -> None:
        ip = client_ip(self)
        form = self._form()
        if not self._login_posted_csrf(form.get("csrf", "")):
            token, headers = self._login_csrf()
            self._html(400, page_login("Сессия формы устарела, попробуйте ещё раз.", token), headers)
            return
        user = (form.get("username") or "").strip()
        password = form.get("password") or ""
        if too_many_failures(ip, user or _user):
            log_auth(f"Failed login for {user!r} from {ip} (locked)")
            token, headers = self._login_csrf()
            self._html(429, page_login("Слишком много попыток. Подождите 15 минут.", token), headers)
            return
        ok = user == _user and verify_password(password, _pw_hash)
        if not ok:
            record_failure(ip, user or _user)
            log_auth(f"Failed login for {user!r} from {ip}")
            token, headers = self._login_csrf()
            self._html(401, page_login("Неверный логин или пароль.", token), headers)
            return
        clear_failures(ip, user)
        sid = new_session(user)
        log_auth(f"Successful login for {user!r} from {ip}")
        self.send_response(302)
        self.send_header("Set-Cookie", self._cookie(sid))
        self.send_header("Set-Cookie", self._csrf_cookie(None, clear=True))
        self.send_header("Set-Cookie", "mon_login=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0")
        self.send_header("Location", "/")
        self.end_headers()

    def _post_password(self, sess: dict[str, Any], form: dict[str, str]) -> None:
        current = form.get("current") or ""
        new = form.get("new") or ""
        new2 = form.get("new2") or ""
        if not verify_password(current, _pw_hash):
            self._html(400, page_password(sess["csrf"], "Текущий пароль неверен."))
            return
        if len(new) < 8:
            self._html(400, page_password(sess["csrf"], "Новый пароль должен быть не короче 8 символов."))
            return
        if new != new2:
            self._html(400, page_password(sess["csrf"], "Новый пароль и повтор не совпадают."))
            return
        if current == new:
            self._html(400, page_password(sess["csrf"], "Новый пароль совпадает с текущим."))
            return
        update_password(new)
        drop_other_sessions(self._sid() or "", sess["user"])
        log_auth(f"Password changed for {sess['user']!r} from {client_ip(self)}")
        self._html(200, page_password(sess["csrf"], "Пароль сохранён. Старые сессии завершены.", ok=True))

    def _post_action(self, form: dict[str, str]) -> None:
        action = (form.get("action") or "").strip()
        if action not in ALLOWED_ACTIONS:
            self._text(400, "unknown action")
            return
        timeout = ACTION_TIMEOUT.get(action, 30)
        log_auth(f"Action {action} from {client_ip(self)}")
        rc, out = helper_cmd(action, timeout=timeout)
        text = f"{ALLOWED_ACTIONS[action]}\nкоманда: {action}\nкод выхода: {rc}\n\n{out or '(нет вывода)'}\n"
        # Invalidate status cache so the next refresh is fresh
        global _status_cache
        with _lock:
            _status_cache = None
            _cert_cache = None
            _warp_cache = None
        self._text(200 if rc == 0 else 500, text)


def main() -> None:
    load_env()
    AUTH_LOG.parent.mkdir(parents=True, exist_ok=True)
    httpd = ThreadingHTTPServer((BIND, PORT), Handler)
    httpd.daemon_threads = True
    print(f"monitoring-panel listening on {BIND}:{PORT} at {fmt_msk()}", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
