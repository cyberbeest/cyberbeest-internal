#!/usr/bin/env python3
"""Cyberbeest report receiver.

Accepts user-triggered failure reports (plain text, POST /report) and stores
each one as a file. Runs behind Caddy on 127.0.0.1 only.

Privacy: sender IP addresses are never written anywhere. The rate limiter
keeps a salted hash of the IP in memory for one hour, the salt is random per
process start, and nothing is logged per request.
"""

import hashlib
import os
import secrets
import sys
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Lock

LISTEN_ADDR = ("127.0.0.1", 8181)
REPORT_DIR = Path(os.environ.get("REPORT_DIR", "/var/lib/cyberbeest-reports"))
MAX_REPORT_BYTES = 64 * 1024
MAX_TOTAL_BYTES = 200 * 1024 * 1024
RATE_LIMIT = 5            # reports per sender per window
RATE_WINDOW = 3600        # seconds

INFO_TEXT = (
    "Cyberbeest report receiver.\n\n"
    "Cyberbeest machines send a failure report here only when their owner\n"
    "clicks \"Send report\" and has seen the exact text being sent.\n"
    "Sender IP addresses are not stored.\n"
)

_salt = secrets.token_bytes(32)
_hits = {}
_hits_lock = Lock()


def _rate_limited(ip):
    key = hashlib.sha256(_salt + ip.encode()).digest()
    now = time.monotonic()
    with _hits_lock:
        for k in [k for k, ts in _hits.items() if now - ts[-1] > RATE_WINDOW]:
            del _hits[k]
        recent = [t for t in _hits.get(key, []) if now - t < RATE_WINDOW]
        if len(recent) >= RATE_LIMIT:
            _hits[key] = recent
            return True
        recent.append(now)
        _hits[key] = recent
        return False


def _dir_size():
    return sum(f.stat().st_size for f in REPORT_DIR.rglob("*") if f.is_file())


class Handler(BaseHTTPRequestHandler):
    server_version = "cyberbeest-reports"
    sys_version = ""

    def log_message(self, format, *args):
        pass  # no per-request logging, it would contain IPs

    def _reply(self, code, text):
        body = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path in ("/", "/report"):
            self._reply(200, INFO_TEXT)
        else:
            self._reply(404, "Not found\n")

    def do_POST(self):
        if self.path != "/report":
            return self._reply(404, "Not found\n")
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            return self._reply(411, "Content-Length required\n")
        if length <= 0:
            return self._reply(400, "Empty report\n")
        if length > MAX_REPORT_BYTES:
            return self._reply(413, "Report too large (max 64 KB)\n")

        # Caddy sets X-Forwarded-For to the real client address.
        ip = self.headers.get("X-Forwarded-For", self.client_address[0]).split(",")[0].strip()
        if _rate_limited(ip):
            return self._reply(429, "Too many reports, try again later\n")

        body = self.rfile.read(length)
        try:
            text = body.decode("utf-8")
        except UnicodeDecodeError:
            return self._reply(400, "Report must be UTF-8 text\n")

        if _dir_size() + length > MAX_TOTAL_BYTES:
            return self._reply(507, "Report storage full, please try again later\n")

        now = datetime.now(timezone.utc)
        day_dir = REPORT_DIR / now.strftime("%Y-%m-%d")
        day_dir.mkdir(parents=True, exist_ok=True)
        report_id = now.strftime("%H%M%S-") + secrets.token_hex(4)
        (day_dir / f"{report_id}.txt").write_text(text, encoding="utf-8")
        self._reply(200, f"{now:%Y-%m-%d}/{report_id}\n")


def main():
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(LISTEN_ADDR, Handler)
    print(f"listening on {LISTEN_ADDR[0]}:{LISTEN_ADDR[1]}, storing in {REPORT_DIR}", file=sys.stderr)
    server.serve_forever()


if __name__ == "__main__":
    main()
