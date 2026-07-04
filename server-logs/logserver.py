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
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

PORT = int(os.environ.get("PORT", "8443"))
TOKEN = os.environ.get("LOG_TOKEN", "")
DIR = os.environ.get("LOG_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs"))
CERT = os.environ.get("CERT", os.path.join(os.path.dirname(os.path.abspath(__file__)), "cert.pem"))
KEY = os.environ.get("KEY", os.path.join(os.path.dirname(os.path.abspath(__file__)), "key.pem"))
os.makedirs(DIR, exist_ok=True)

# --- Очередь команд для планшетов (outbound-канал) -------------------------
# Планшет сам ходит на сервер (poll), забирает команды и шлёт ack. Это убирает
# зависимость «ПК должен дотянуться до планшета в локалке»: пока у планшета есть
# интернет — он управляем, IP/NAT не важны.
CMDS_DIR = os.environ.get("CMDS_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), "cmds"))
os.makedirs(CMDS_DIR, exist_ok=True)
CMDS_LOCK = threading.Lock()
CMDS_KEEP = 50  # сколько последних команд на планшет хранить


def safe(s):
    return (re.sub(r"[^A-Za-z0-9._-]", "_", (s or ""))[:120]) or "unknown"


def _cmds_path(site):
    return os.path.join(CMDS_DIR, safe(site) + ".json")


def _load_cmds(site):
    try:
        with open(_cmds_path(site), "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {"meta": {}, "queue": []}


def _save_cmds(site, data):
    tmp = _cmds_path(site) + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    os.replace(tmp, _cmds_path(site))


def enqueue_cmd(site, cmd, args):
    with CMDS_LOCK:
        data = _load_cmds(site)
        cid = int(data.get("next_id", 1))
        data["next_id"] = cid + 1
        data.setdefault("queue", []).append({
            "id": cid, "cmd": cmd, "args": args or {},
            "status": "pending", "result": "",
            "ts": datetime.datetime.utcnow().isoformat() + "Z",
        })
        data["queue"] = data["queue"][-CMDS_KEEP:]
        _save_cmds(site, data)
        return cid


def poll_cmds(site, meta=None):
    """Возвращает pending-команды и помечает их sent (чтобы не выполнить дважды)."""
    with CMDS_LOCK:
        data = _load_cmds(site)
        if meta:
            m = data.setdefault("meta", {})
            m.update(meta)
            m["last_seen"] = datetime.datetime.utcnow().isoformat() + "Z"
        pending = [c for c in data.get("queue", []) if c["status"] == "pending"]
        for c in pending:
            c["status"] = "sent"
        _save_cmds(site, data)
        return [{"id": c["id"], "cmd": c["cmd"], "args": c["args"]} for c in pending]


def ack_cmd(site, cid, ok, result):
    with CMDS_LOCK:
        data = _load_cmds(site)
        for c in data.get("queue", []):
            if c["id"] == cid:
                c["status"] = "done" if ok else "error"
                c["result"] = str(result or "")[:500]
                c["ack_ts"] = datetime.datetime.utcnow().isoformat() + "Z"
                break
        _save_cmds(site, data)


def list_cmd_sites():
    out = []
    if not os.path.isdir(CMDS_DIR):
        return out
    for fn in sorted(os.listdir(CMDS_DIR)):
        if not fn.endswith(".json"):
            continue
        site = fn[:-5]
        data = _load_cmds(site)
        meta = data.get("meta", {})
        ls = meta.get("last_seen")
        age = None
        if ls:
            try:
                t = datetime.datetime.strptime(ls, "%Y-%m-%dT%H:%M:%S.%fZ")
                age = round((datetime.datetime.utcnow() - t).total_seconds() / 60, 1)
            except Exception:
                age = None
        out.append({"site": site, "meta": meta, "age_min": age,
                    "queue": data.get("queue", [])[-8:]})
    return out


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
        files = sorted(f for f in os.listdir(sp) if f.endswith(".log") and not f.startswith("_"))
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
    # Рвём зависшие соединения — иначе мёртвые клиенты копят потоки.
    timeout = 30

    def setup(self):
        # TLS-handshake ЗДЕСЬ, в потоке этого соединения. Раньше слушающий
        # сокет был обёрнут целиком (wrap_socket в main), и handshake шёл в
        # accept-потоке: один зависший клиент (сканер/полуоткрытое соединение)
        # блокировал приём ВСЕХ соединений — сервер «висел» при живом процессе
        # (очередь listen переполнена, снаружи таймауты). 2026-06-10.
        self.request.settimeout(20)
        self.request = self.server.ssl_context.wrap_socket(
            self.request, server_side=True)
        super().setup()

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

    def _cmds_console(self, tok):
        tok = html.escape(tok or "")
        rows = []
        for s in list_cmd_sites():
            site = html.escape(s["site"])
            meta = s.get("meta", {})
            name = html.escape(str(meta.get("name") or meta.get("model") or s["site"]))
            ip = html.escape(str(meta.get("ip") or ""))
            ver = html.escape(str(meta.get("v") or ""))
            age = s["age_min"]
            color = "#4c4" if (age is not None and age < 2) else ("#fc0" if (age is not None and age < 10) else "#f44")
            seen = "—" if age is None else (str(age) + " мин назад")
            q = s.get("queue", [])[-4:]
            qhtml = "<br>".join(
                f"#{c['id']} {html.escape(c['cmd'])} — {html.escape(c['status'])}"
                + (f": {html.escape(str(c.get('result','')))}" if c.get("result") else "")
                for c in reversed(q)
            ) or "<i>пусто</i>"
            btns = "".join(
                f"<button onclick=\"send('{site}','{c}')\">{label}</button> "
                for c, label in [("launch", "▶ Запустить"), ("restart", "⟳ С начала"),
                                 ("wake", "☀ Разбудить"), ("sleep", "🌙 Сон"),
                                 ("reboot", "⏻ Ребут")]
            )
            rows.append(
                f"<tr><td><b>{name}</b><br><small>{site}</small></td>"
                f"<td>{ip}</td><td>{ver}</td>"
                f"<td style='color:{color}'>{seen}</td>"
                f"<td>{btns}</td><td><small>{qhtml}</small></td></tr>"
            )
        body = "".join(rows) or "<tr><td colspan=6><i>планшеты ещё не выходили на связь</i></td></tr>"
        return (
            "<html><head><meta charset='utf-8'><title>Brandmen — команды</title>"
            "<meta http-equiv='refresh' content='15'>"
            "<style>body{font-family:system-ui;background:#111;color:#ddd;padding:20px}"
            "table{border-collapse:collapse}td{border:1px solid #333;padding:6px 10px;vertical-align:top}"
            "button{background:#234;color:#cef;border:1px solid #456;border-radius:6px;"
            "padding:4px 8px;margin:2px;cursor:pointer}button:hover{background:#345}</style>"
            "<script>function send(site,cmd){fetch('/commands/enqueue?site='+encodeURIComponent(site)"
            "+'&token=" + tok + "',{method:'POST',headers:{'Content-Type':'application/json'},"
            "body:JSON.stringify({cmd:cmd})}).then(r=>r.ok?location.reload():alert('ошибка '+r.status))}"
            "</script></head><body>"
            "<h2>Brandmen — команды планшетам</h2>"
            "<p>Планшет забирает команду в течение ~15 c. Зелёный = на связи (&lt;2 мин). Обновление каждые 15 c.</p>"
            "<table><tr><td>Планшет</td><td>IP</td><td>Версия</td><td>На связи</td>"
            "<td>Команды</td><td>Последние</td></tr>" + body + "</table></body></html>"
        )

    def _read_json(self):
        n = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(n) if n else b""
        try:
            return json.loads(raw.decode("utf-8")) if raw else {}
        except Exception:
            return {}

    def do_POST(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        # --- Команды планшетам --------------------------------------------
        if u.path == "/commands/enqueue":
            if not authed(self):
                return self._send(401, "unauthorized")
            site = safe(q.get("site", [""])[0])
            b = self._read_json()
            cmd = str(b.get("cmd", "")).strip()
            if not cmd:
                return self._send(400, "missing cmd")
            cid = enqueue_cmd(site, cmd, b.get("args") or {})
            print(f"[cmd] enqueue {site} <- {cmd} #{cid}", flush=True)
            return self._send(200, json.dumps({"id": cid}), "application/json; charset=utf-8")
        if u.path == "/commands/ack":
            if not authed(self):
                return self._send(401, "unauthorized")
            site = safe(q.get("site", [""])[0])
            b = self._read_json()
            try:
                cid = int(b.get("id"))
            except Exception:
                return self._send(400, "missing id")
            ack_cmd(site, cid, bool(b.get("ok", True)), b.get("result", ""))
            return self._send(200, "ok")
        if u.path == "/live":
            # Живой поток: дописываем новые строки в один файл _live.log на сайт,
            # обрезаем по размеру, чтобы не рос бесконечно. Для отладки в реалтайме.
            if not authed(self):
                return self._send(401, "unauthorized")
            site = safe(q.get("site", [""])[0])
            n = int(self.headers.get("Content-Length", "0") or "0")
            body = self.rfile.read(n) if n else b""
            d = os.path.join(DIR, site)
            os.makedirs(d, exist_ok=True)
            lf = os.path.join(d, "_live.log")
            with open(lf, "ab") as f:
                f.write(body)
                if not body.endswith(b"\n"):
                    f.write(b"\n")
            try:
                cap = 2 * 1024 * 1024
                if os.path.getsize(lf) > cap:
                    with open(lf, "rb") as f:
                        f.seek(-cap // 2, os.SEEK_END)
                        tail = f.read()
                    with open(lf, "wb") as f:
                        f.write(b"...(truncated)...\n" + tail)
            except Exception:
                pass
            return self._send(200, "ok")
        if u.path != "/logs":
            return self._send(404, "not found")
        if not authed(self):
            return self._send(401, "unauthorized")
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
        if u.path == "/commands/poll":
            if not authed(self):
                return self._send(401, "unauthorized")
            site = safe(q.get("site", [""])[0])
            meta = {k: q.get(k, [""])[0] for k in ("name", "ip", "v", "model") if q.get(k)}
            return self._send(200, json.dumps(poll_cmds(site, meta), ensure_ascii=False),
                              "application/json; charset=utf-8")
        if u.path in ("/list", "/view", "/dash", "/live", "/cmds", "/commands") and not authed(self):
            return self._send(401, "unauthorized")
        if u.path == "/commands":
            return self._send(200, json.dumps(list_cmd_sites(), ensure_ascii=False, indent=2),
                              "application/json; charset=utf-8")
        if u.path == "/cmds":
            return self._send(200, self._cmds_console(q.get("token", [""])[0]),
                              "text/html; charset=utf-8")
        if u.path == "/live":
            site = safe(q.get("site", [""])[0])
            lf = os.path.join(DIR, site, "_live.log")
            if not os.path.isfile(lf):
                return self._send(404, "no live stream for site")
            with open(lf, "rb") as fh:
                return self._send(200, fh.read())
        if u.path == "/list":
            return self._send(200, json.dumps(list_sites(), ensure_ascii=False, indent=2),
                              "application/json; charset=utf-8")
        if u.path == "/view":
            site = safe(q.get("site", [""])[0])
            f = q.get("file", ["last"])[0]
            sp = os.path.join(DIR, site)
            if f in ("", "last", "latest"):
                files = sorted(x for x in os.listdir(sp)) if os.path.isdir(sp) else []
                files = [x for x in files if x.endswith(".log") and not x.startswith("_")]
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


class QuietThreadingHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        # Сканеры и не-TLS мусор валятся на handshake — одна строка в журнал
        # вместо полного трейсбека на каждое такое соединение.
        import sys
        et, ev = sys.exc_info()[:2]
        name = et.__name__ if et else "?"
        print(f"conn error {client_address}: {name}: {ev}", flush=True)


def main():
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(CERT, KEY)
    httpd = QuietThreadingHTTPServer(("0.0.0.0", PORT), H)
    # НЕ оборачиваем слушающий сокет: TLS делается per-соединение в H.setup(),
    # чтобы handshake не блокировал accept-поток (причина зависания 2026-06-09).
    httpd.ssl_context = ctx
    print(f"brandmen log server on :{PORT}  dir={DIR}  token={'yes' if TOKEN else 'no'}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
