#!/usr/bin/env python3
"""
TURU-BLOK control server — dipakai istri buat kontrol lock dari HP (PWA, LAN).

Stdlib only. Bind ke LAN. Auth pakai PIN → device token (pairing).
Actions:
  - lock now   → launchctl kickstart com.turublok.forcelock (TCC context BENAR)
  - unlock     → tulis unlock_request file (proses lock exit di tick berikutnya)
  - snooze     → tulis pause_until = window berikutnya (cuma istri yang bisa)
  - snooze_off → hapus pause
  - status     → state lock saat ini
"""

import hashlib
import hmac
import ipaddress
import json
import os
import secrets
import subprocess
import time
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Lock

PORT = 8787
HOME = Path.home()
SUPPORT = HOME / "Library/Application Support/turublok"
SUPPORT.mkdir(parents=True, exist_ok=True, mode=0o700)

PUBLIC_DIR = (Path(__file__).parent / "public").resolve()

def _local_v6_prefixes():
    """Ambil prefix /64 IPv6 global Mac → buat ngenalin device se-LAN via IPv6."""
    nets = []
    try:
        out = subprocess.run(["ifconfig"], capture_output=True, text=True).stdout
        for line in out.splitlines():
            s = line.strip()
            if s.startswith("inet6 ") and "fe80" not in s:
                addr = s.split()[1].split("%")[0]
                try:
                    nets.append(ipaddress.ip_network(addr + "/64", strict=False))
                except Exception:
                    pass
    except Exception:
        pass
    return nets

LOCAL_V6_PREFIXES = _local_v6_prefixes()
CONFIG_PATH = SUPPORT / "web_config.json"
PAUSE_PATH = SUPPORT / "pause_until.txt"
UNLOCK_PATH = SUPPORT / "unlock_request"

WIB = timezone(timedelta(hours=7))
LOCK_START_HOUR = 23
LOCK_END_HOUR = 7
UID = os.getuid()

# ---------- config / auth ----------

def load_config():
    if CONFIG_PATH.exists():
        try:
            return json.loads(CONFIG_PATH.read_text())
        except Exception:
            pass
    cfg = {"pin": "0000", "tokens": []}
    save_config(cfg)
    return cfg

def save_config(cfg):
    # Mode 0600 — cuma owner yang bisa baca PIN/token.
    fd = os.open(CONFIG_PATH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, json.dumps(cfg, indent=2).encode())
    finally:
        os.close(fd)

def token_valid(token):
    if not token:
        return False
    tokens = load_config().get("tokens", [])
    # Constant-time compare buat tiap token.
    return any(hmac.compare_digest(token, t) for t in tokens)

# --- PIN hashing (PBKDF2) — PIN ga disimpan plaintext ---
def _hash_pin(pin, salt):
    return hashlib.pbkdf2_hmac("sha256", str(pin).encode(), bytes.fromhex(salt), 100_000).hex()

def verify_pin(pin, cfg):
    if cfg.get("pin_hash") and cfg.get("salt"):
        return hmac.compare_digest(_hash_pin(pin, cfg["salt"]), cfg["pin_hash"])
    # backward-compat: config lama yang masih plaintext
    if "pin" in cfg:
        return hmac.compare_digest(str(pin), str(cfg["pin"]))
    return False

def apply_new_pin(cfg, new_pin):
    salt = secrets.token_hex(16)
    cfg["salt"] = salt
    cfg["pin_hash"] = _hash_pin(new_pin, salt)
    cfg.pop("pin", None)  # buang plaintext
    return cfg

# --- rate limiting buat /api/pair (anti brute-force PIN di LAN) ---
_pair_attempts = defaultdict(list)  # ip -> [timestamps]
_pair_lock = Lock()
PAIR_MAX_ATTEMPTS = 5
PAIR_WINDOW_SEC = 600  # 10 menit

def pair_rate_limited(ip):
    now = time.time()
    with _pair_lock:
        attempts = [t for t in _pair_attempts[ip] if now - t < PAIR_WINDOW_SEC]
        _pair_attempts[ip] = attempts
        return len(attempts) >= PAIR_MAX_ATTEMPTS

def record_pair_attempt(ip):
    with _pair_lock:
        _pair_attempts[ip].append(time.time())

# ---------- lock state helpers ----------

def running_lock_kind():
    """Return 'bedtime'/'force'/'fatigue' kalau ada lock jalan, else None."""
    try:
        out = subprocess.run(["pgrep", "-fl", "turublok"], capture_output=True, text=True).stdout
    except Exception:
        return None
    for line in out.splitlines():
        if "--force-lock" in line:
            return "force"
        if "--fatigue-lock" in line:
            return "fatigue"
        if "turublok --lock" in line or line.endswith("--lock"):
            return "bedtime"
    return None

def now_wib():
    return datetime.now(WIB)

def in_lock_window(dt):
    h = dt.hour
    if LOCK_START_HOUR < LOCK_END_HOUR:
        return LOCK_START_HOUR <= h < LOCK_END_HOUR
    return h >= LOCK_START_HOUR or h < LOCK_END_HOUR

def next_window_start(dt):
    start = dt.replace(hour=LOCK_START_HOUR, minute=0, second=0, microsecond=0)
    if start <= dt:
        start += timedelta(days=1)
    return start

def paused_until():
    if not PAUSE_PATH.exists():
        return None
    try:
        s = PAUSE_PATH.read_text().strip()
        # ISO8601 dari Swift (Z atau +00:00)
        s = s.replace("Z", "+00:00")
        return datetime.fromisoformat(s)
    except Exception:
        return None

def is_paused(now_utc):
    pu = paused_until()
    return pu is not None and now_utc < pu

ID_MONTHS = ["", "Jan", "Feb", "Mar", "Apr", "Mei", "Jun",
             "Jul", "Agu", "Sep", "Okt", "Nov", "Des"]

def human_remaining(secs):
    secs = max(0, int(secs))
    h = secs // 3600
    m = (secs % 3600) // 60
    if h >= 24:
        d = h // 24
        return f"{d} hari lagi"
    if h >= 1:
        return f"{h} jam lagi" if m == 0 else f"{h} jam {m} mnt lagi"
    return f"{max(m,1)} menit lagi"

def get_status():
    now = now_wib()
    now_utc = datetime.now(timezone.utc)
    kind = running_lock_kind()
    pu = paused_until()
    paused = is_paused(now_utc)

    # "pin" plaintext masih ada = PIN belum pernah diganti (masih default).
    pin_is_default = "pin" in load_config()
    s = {
        "now": now.strftime("%H:%M"),
        "locked": kind is not None,
        "lockKind": kind,
        "inWindow": in_lock_window(now),
        "window": f"{LOCK_START_HOUR:02d}:00–{LOCK_END_HOUR:02d}:00",
        "snoozed": paused,
        "snoozedUntil": None,
        "snoozedRemaining": None,
        "pinIsDefault": pin_is_default,
    }
    if pu and paused:
        pw = pu.astimezone(WIB)
        s["snoozedUntil"] = f"boleh begadang sampai {pw.strftime('%H:%M')}"
        s["snoozedRemaining"] = human_remaining((pu - now_utc).total_seconds()) + " ke-lock"
    return s

# ---------- actions ----------

def action_lock():
    subprocess.run(
        ["launchctl", "kickstart", "-k", f"gui/{UID}/com.turublok.forcelock"],
        capture_output=True,
    )
    return {"ok": True, "msg": "Lock dipicu"}

def action_unlock():
    UNLOCK_PATH.write_text(str(time.time()))
    return {"ok": True, "msg": "Unlock dipicu"}

def action_snooze(body=None):
    now = now_wib()
    until = (body or {}).get("until")  # "HH:MM" — sampai jam berapa boleh begadang
    if until:
        try:
            hh, mm = map(int, str(until).split(":"))
            assert 0 <= hh < 24 and 0 <= mm < 60
            target = now.replace(hour=hh, minute=mm, second=0, microsecond=0)
            if target <= now:
                target += timedelta(days=1)  # jam udah lewat hari ini → besok
        except Exception:
            return {"ok": False, "msg": "Format jam salah (contoh: 02:00)"}
    else:
        target = next_window_start(now)
    iso = target.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    PAUSE_PATH.write_text(iso)
    UNLOCK_PATH.write_text(str(time.time()))  # batalin lock yang lagi jalan
    return {"ok": True, "msg": f"Boleh begadang sampai {target.strftime('%H:%M')} 🌙"}

def action_snooze_off():
    if PAUSE_PATH.exists():
        PAUSE_PATH.unlink()
    return {"ok": True, "msg": "Izin dibatalin — lock aktif lagi"}

# ---------- HTTP ----------

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # quiet

    def _send_json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _send_error_code(self, code):
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _send_file(self, path: Path):
        if not path.exists() or not path.is_file():
            return self._send_error_code(404)
        ctype = {
            ".html": "text/html; charset=utf-8",
            ".js": "application/javascript",
            ".json": "application/json",
            ".css": "text/css",
            ".png": "image/png",
            ".svg": "image/svg+xml",
        }.get(path.suffix, "application/octet-stream")
        if path.name == "manifest.json":
            ctype = "application/manifest+json"
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _token(self):
        return self.headers.get("X-Token", "")

    def _client_is_local(self):
        # Izinin LAN/private/loopback. Blok internet.
        # IPv6 global di-izinin kalau se-prefix /64 dgn Mac (= se-LAN, bukan internet).
        try:
            ip = ipaddress.ip_address(self.client_address[0])
        except Exception:
            return False
        if ip.is_loopback or ip.is_private or ip.is_link_local:
            return True
        if ip.version == 6:
            for net in LOCAL_V6_PREFIXES:
                if ip in net:
                    return True
        return False

    def _body_json(self):
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            return {}
        try:
            return json.loads(self.rfile.read(length))
        except Exception:
            return {}

    def do_GET(self):
        if not self._client_is_local():
            print(f"[BLOCKED non-local] {self.client_address[0]}", flush=True)
            return self._send_error_code(403)
        path = self.path.split("?")[0]
        if path == "/api/status":
            if not token_valid(self._token()):
                return self._send_json({"error": "unauthorized"}, 401)
            return self._send_json(get_status())
        # static
        if path == "/":
            return self._send_file(PUBLIC_DIR / "index.html")
        # Tolak path mencurigakan mentah-mentah (anti path-traversal).
        if ".." in path or "\\" in path or "\0" in path:
            return self._send_error_code(404)
        rel = path.lstrip("/")
        if not rel:
            return self._send_file(PUBLIC_DIR / "index.html")
        candidate = (PUBLIC_DIR / rel).resolve()
        # Pastikan hasil resolve masih di dalam PUBLIC_DIR.
        if not str(candidate).startswith(str(PUBLIC_DIR) + os.sep):
            return self._send_error_code(404)
        return self._send_file(candidate)

    def do_POST(self):
        if not self._client_is_local():
            print(f"[BLOCKED non-local] {self.client_address[0]}", flush=True)
            return self._send_error_code(403)
        path = self.path.split("?")[0]
        body = self._body_json()

        if path == "/api/pair":
            ip = self.client_address[0]
            if pair_rate_limited(ip):
                return self._send_json(
                    {"ok": False, "error": "Terlalu banyak percobaan. Tunggu 10 menit."}, 429)
            record_pair_attempt(ip)
            cfg = load_config()
            if verify_pin(body.get("pin", ""), cfg):
                token = secrets.token_hex(24)
                # STRICT 1 device: device baru gantiin yang lama (yang lama ke-logout).
                cfg["tokens"] = [token]
                save_config(cfg)
                return self._send_json({"ok": True, "token": token})
            return self._send_json({"ok": False, "error": "PIN salah"}, 403)

        # semua action di bawah butuh token valid
        if not token_valid(self._token()):
            return self._send_json({"error": "unauthorized"}, 401)

        if path == "/api/set_pin":
            new_pin = str(body.get("new_pin", "")).strip()
            if not new_pin.isdigit() or len(new_pin) < 4:
                return self._send_json({"ok": False, "error": "PIN minimal 4 angka"}, 400)
            cfg = load_config()
            apply_new_pin(cfg, new_pin)
            # Revoke SEMUA device lain — sisain cuma HP ini (yang lagi set PIN).
            current = self._token()
            cfg["tokens"] = [current] if current in cfg.get("tokens", []) else []
            save_config(cfg)
            return self._send_json({"ok": True, "msg": "PIN diganti. Device lain di-logout."})

        if path == "/api/lock":
            return self._send_json(action_lock())
        if path == "/api/unlock":
            return self._send_json(action_unlock())
        if path == "/api/snooze":
            return self._send_json(action_snooze(body))
        if path == "/api/snooze_off":
            return self._send_json(action_snooze_off())

        return self._send_json({"error": "not found"}, 404)


def main():
    load_config()  # ensure exists
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"TURU-BLOK control server di :{PORT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
