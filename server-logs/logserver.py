#!/usr/bin/env python3
"""Brandmen log receiver (чистый stdlib, без зависимостей).

Принимает логи от ПК-приложения и отдаёт их обратно через защищённые
read-эндпоинты, чтобы можно было смотреть статус из браузера/curl.

Контракт приёма (как в server.js):
    POST {URL}/logs?site=<имя ПК>&version=<версия>&ts=<ISO>
    Authorization: Bearer <LOG_TOKEN>      (если задан)
    Content-Type: text/plain; charset=utf-8
    тело: текст лога  ->  пишется в logs/<site>/<ts>__v<version>.log

Чтение (требует токен — в Bearer или ?token=...):
    GET /list                 — JSON: сайты, число файлов, время последнего
    GET /view?site=&file=     — сырой лог (file=last — последний)
    GET /dash                 — простой HTML-дашборд
    GET /                      — health "brandmen log server"

Запуск:  PORT=8443 LOG_TOKEN=секрет CERT=cert.pem KEY=key.pem python3 logserver.py
TLS терминируется самим сервером (самоподписанный серт ок — приложение его
принимает по badCertificateCallback для своего хоста).
"""
import os
import re
import ssl
import json
import html
import time
import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

PORT = int(os.environ.get("PORT", "8443"))
TOKEN = os.environ.get("LOG_TOKEN", "")
DIR = os.environ.get("LOG_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs"))
CERT = os.environ.get("CERT", os.path.join(os.path.dirname(os.path.abspath(__file__)), "cert.pem"))
KEY = os.environ.get("KEY", os.path.join(os.path.dirname(os.path.abspath(__file__)), "key.pem"))
os.makedirs(DIR, exist_ok=True)


def safe(s):
    return (re.sub(r"[^A-Za-z0-9._-]", "_", (s or ""))[:120]) or "unknown"


def authed(handler):
    if not TOKEN:
        return True
    q = parse_qs(urlparse(handler.path).query)
    if q.get("token", [""])[0] == TOKEN:
        return True
    return handler.headers.get("Authorization", "") == f"Bearer {TOKEN}"


def list_sites():
    out = []
    if not os.path.isdir(DIR):
        return out
    for site in sorted(os.listdir(DIR)):
        sp = os.path.join(DIR, site)
        if not os.path.isdir(sp):
            continue
        files = sorted(f for f in os.listdir(sp) if f.endswith(".log"))
        last = files[-1] if files else None
        mtime = os.path.getmtime(os.path.join(sp, last)) if last else 0
        out.append({
            "site": site,
            "count": len(files),
            "last": last,
            "last_utc": (datetime.datetime.utcfromtimestamp(mtime).isoformat() + "Z") if mtime else None,
            "age_min": round((time.time() - mtime) / 60, 1) if mtime else None,
        })
    return out


class H(BaseHTTPRequestHandler):
    server_version = "brandmen-logs/1.0"

    def _send(self, code, body, ctype="text/plain; charset=utf-8"):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except Exception:
            pass

    def log_message(self, *a):
        pass

    def do_POST(self):
        u = urlparse(self.path)
        if u.path != "/logs":
            return self._send(404, "not found")
        if not authed(self):
            return self._send(401, "unauthorized")
        q = parse_qs(u.query)
        site = safe(q.get("site", [""])[0])
        version = safe(q.get("version", [""])[0])
        n = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(n) if n else b""
        ts = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H-%M-%S-%fZ")
        d = os.path.join(DIR, site)
        os.makedirs(d, exist_ok=True)
        fn = os.path.join(d, f"{ts}__v{version}.log")
        with open(fn, "wb") as f:
            f.write(body)
        print(f"[{ts}] {site} v{version} -> {fn} ({len(body)} b)", flush=True)
        return self._send(200, f"ok: {site}/{ts}.log")

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        if u.path == "/":
            return self._send(200, "brandmen log server")
        if u.path in ("/list", "/view", "/dash") and not authed(self):
            return self._send(401, "unauthorized")
        if u.path == "/list":
            return self._send(200, json.dumps(list_sites(), ensure_ascii=False, indent=2),
                              "application/json; charset=utf-8")
        if u.path == "/view":
            site = safe(q.get("site", [""])[0])
            f = q.get("file", ["last"])[0]
            sp = os.path.join(DIR, site)
            if f in ("", "last", "latest"):
                files = sorted(x for x in os.listdir(sp)) if os.path.isdir(sp) else []
                files = [x for x in files if x.endswith(".log")]
                if not files:
                    return self._send(404, "no logs for site")
                f = files[-1]
            f = safe(f)
            path = os.path.join(sp, f)
            if not os.path.isfile(path):
                return self._send(404, "file not found")
            with open(path, "rb") as fh:
                return self._send(200, fh.read())
        if u.path == "/dash":
            rows = []
            for s in list_sites():
                age = s["age_min"]
                color = "#0f0" if (age is not None and age < 15) else ("#fc0" if (age is not None and age < 120) else "#f44")
                tok = q.get("token", [""])[0]
                link = f"/view?site={html.escape(s['site'])}&file=last&token={html.escape(tok)}"
                rows.append(
                    f"<tr><td><b>{html.escape(s['site'])}</b></td>"
                    f"<td style='color:{color}'>{'' if age is None else str(age)+' мин назад'}</td>"
                    f"<td>{s['count']}</td>"
                    f"<td><a href='{link}'>последний лог</a></td></tr>"
                )
            page = (
                "<html><head><meta charset='utf-8'><title>Brandmen logs</title>"
                "<meta http-equiv='refresh' content='30'>"
                "<style>body{font-family:system-ui;background:#111;color:#ddd;padding:20px}"
                "table{border-collapse:collapse}td{border:1px solid #333;padding:6px 12px}"
                "a{color:#6cf}</style></head><body>"
                "<h2>Brandmen — приёмник логов</h2>"
                "<p>Автообновление каждые 30 c. Зелёный = свежий лог (&lt;15 мин).</p>"
                "<table><tr><td>ПК</td><td>последний лог</td><td>всего</td><td></td></tr>"
                + "".join(rows) + "</table></body></html>"
            )
            return self._send(200, page, "text/html; charset=utf-8")
        return self._send(404, "not found")


def main():
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(CERT, KEY)
    httpd = ThreadingHTTPServer(("0.0.0.0", PORT), H)
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    print(f"brandmen log server on :{PORT}  dir={DIR}  token={'yes' if TOKEN else 'no'}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
