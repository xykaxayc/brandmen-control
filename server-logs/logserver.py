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
    GET /files?site=          — JSON: файлы сайта (live первым, новые сверху)
    GET /view?site=&file=     — сырой лог (file=last — последний)
    GET /ui                   — панель просмотра логов (HTML, раскраска/фильтры)
    GET /dash                 — 302 → /ui (легаси)
    GET /cmds                 — консоль команд планшетам (HTML, кнопки)
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
import base64
import hashlib
import hmac
import secrets
import datetime
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, quote, urlencode
from urllib.request import Request, urlopen
from remote_panel import login_page, panel_page, downloads_page

PORT = int(os.environ.get("PORT", "8443"))
TOKEN = os.environ.get("LOG_TOKEN", "")
DIR = os.environ.get("LOG_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs"))
CERT = os.environ.get("CERT", os.path.join(os.path.dirname(os.path.abspath(__file__)), "cert.pem"))
KEY = os.environ.get("KEY", os.path.join(os.path.dirname(os.path.abspath(__file__)), "key.pem"))
PUBLIC_BASE = os.environ.get(
    "PUBLIC_BASE", "https://185.50.203.112").rstrip("/")
ADMIN_USER = os.environ.get("ADMIN_USER", "admin")
ADMIN_PASSWORD_HASH = os.environ.get("ADMIN_PASSWORD_HASH", "")
SESSION_SECRET = os.environ.get("SESSION_SECRET", "")
SESSION_COOKIE = "brandmen_session"
SESSION_TTL = 12 * 60 * 60
os.makedirs(DIR, exist_ok=True)

UPDATE_REPO = "xykaxayc/brandmen-control"
UPDATE_ASSETS = {
    "BrandmenAds.apk",
    "BrandmenControl-macOS.dmg",
    "BrandmenControl-macOS.zip",
    "BrandmenControl-Setup.exe",
    "BrandmenControl-Windows.zip",
}
UPDATE_CACHE = {"at": 0.0, "releases": []}
UPDATE_CACHE_LOCK = threading.Lock()
ASSET_CACHE_DIR = os.environ.get("UPDATE_CACHE_DIR", os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "update-cache"))
os.makedirs(ASSET_CACHE_DIR, exist_ok=True)


def update_releases():
    """GitHub releases с download URL, переписанными на закреплённый сервер."""
    with UPDATE_CACHE_LOCK:
        now = time.time()
        if UPDATE_CACHE["releases"] and now - UPDATE_CACHE["at"] < 60:
            return UPDATE_CACHE["releases"]
        req = Request(
            f"https://api.github.com/repos/{UPDATE_REPO}/releases?per_page=15",
            headers={"Accept": "application/vnd.github+json",
                     "User-Agent": "BrandmenUpdateMirror/1"})
        with urlopen(req, timeout=15) as response:
            releases = json.loads(response.read().decode("utf-8"))
        for release in releases:
            tag = str(release.get("tag_name", ""))
            allowed = []
            for asset in release.get("assets", []):
                name = str(asset.get("name", ""))
                if name not in UPDATE_ASSETS:
                    continue
                item = dict(asset)
                item["browser_download_url"] = (
                    f"{PUBLIC_BASE}/updates/download"
                    f"?tag={quote(tag)}&name={quote(name)}&token={quote(TOKEN)}")
                allowed.append(item)
            release["assets"] = allowed
        UPDATE_CACHE.update(at=now, releases=releases)
        return releases

# --- Очередь команд для планшетов (outbound-канал) -------------------------
# Планшет сам ходит на сервер (poll), забирает команды и шлёт ack. Это убирает
# зависимость «ПК должен дотянуться до планшета в локалке»: пока у планшета есть
# интернет — он управляем, IP/NAT не важны.
CMDS_DIR = os.environ.get("CMDS_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), "cmds"))
os.makedirs(CMDS_DIR, exist_ok=True)
CMDS_LOCK = threading.Lock()
CMDS_KEEP = 50  # сколько последних команд на планшет хранить
AGENTS_DIR = os.environ.get("AGENTS_DIR", os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "agents"))
os.makedirs(AGENTS_DIR, exist_ok=True)
LOGIN_ATTEMPTS = {}
LOGIN_LOCK = threading.Lock()


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


def api_authed(handler):
    if not TOKEN:
        return True
    supplied = handler.headers.get("Authorization", "")
    if supplied.startswith("Bearer ") and hmac.compare_digest(
            supplied[7:].encode(), TOKEN.encode()):
        return True
    # Легаси-клиенты ещё передают токен в URL. Оставляем только для служебных
    # API на время обновления флота; браузерная панель query-token не принимает.
    q = parse_qs(urlparse(handler.path).query)
    candidate = q.get("token", [""])[0]
    return bool(candidate) and hmac.compare_digest(candidate.encode(), TOKEN.encode())


def _b64e(raw):
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def _b64d(value):
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def verify_password(password):
    """Verify pbkdf2_sha256$iterations$salt_b64$digest_b64."""
    try:
        kind, rounds, salt, expected = ADMIN_PASSWORD_HASH.split("$", 3)
        if kind != "pbkdf2_sha256":
            return False
        actual = hashlib.pbkdf2_hmac(
            "sha256", password.encode(), _b64d(salt), int(rounds))
        return hmac.compare_digest(_b64e(actual), expected)
    except Exception:
        return False


def new_session(username):
    payload = {
        "u": username,
        "exp": int(time.time()) + SESSION_TTL,
        "csrf": secrets.token_urlsafe(24),
    }
    raw = _b64e(json.dumps(payload, separators=(",", ":")).encode())
    sig = hmac.new(SESSION_SECRET.encode(), raw.encode(), hashlib.sha256).hexdigest()
    return raw + "." + sig


def web_session(handler):
    if not SESSION_SECRET:
        return None
    cookies = handler.headers.get("Cookie", "")
    value = ""
    for item in cookies.split(";"):
        name, sep, val = item.strip().partition("=")
        if sep and name == SESSION_COOKIE:
            value = val
            break
    try:
        raw, sig = value.rsplit(".", 1)
        expected = hmac.new(
            SESSION_SECRET.encode(), raw.encode(), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(sig, expected):
            return None
        session = json.loads(_b64d(raw).decode())
        if session.get("u") != ADMIN_USER or int(session.get("exp", 0)) < time.time():
            return None
        return session
    except Exception:
        return None


def csrf_ok(handler, session):
    value = handler.headers.get("X-CSRF-Token", "")
    expected = str(session.get("csrf", "")) if session else ""
    return bool(value and expected and hmac.compare_digest(value, expected))


def client_ip(handler):
    forwarded = handler.headers.get("X-Forwarded-For", "").split(",")[0].strip()
    return forwarded or handler.client_address[0]


def login_allowed(ip, success=False):
    now = time.time()
    with LOGIN_LOCK:
        recent = [t for t in LOGIN_ATTEMPTS.get(ip, []) if now - t < 300]
        if success:
            LOGIN_ATTEMPTS.pop(ip, None)
            return True
        allowed = len(recent) < 5
        if allowed:
            recent.append(now)
            LOGIN_ATTEMPTS[ip] = recent
        return allowed


def save_agent_snapshot(body):
    site = safe(str(body.get("site", "")))
    if site == "unknown":
        raise ValueError("missing site")
    devices = body.get("devices") if isinstance(body.get("devices"), list) else []
    clean = {
        "site": site,
        "version": safe(str(body.get("version", ""))),
        "seen_utc": datetime.datetime.utcnow().isoformat() + "Z",
        "devices": [],
    }
    for item in devices[:500]:
        if not isinstance(item, dict):
            continue
        clean["devices"].append({
            "name": str(item.get("name", ""))[:160],
            "ip": str(item.get("ip", ""))[:80],
            "device_id": safe(str(item.get("device_id", ""))) if item.get("device_id") else "",
            "desired_deployment_id": str(item.get("desired_deployment_id", ""))[:160],
        })
    path = os.path.join(AGENTS_DIR, site + ".json")
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(clean, f, ensure_ascii=False)
    os.replace(tmp, path)
    return clean


def list_agent_snapshots():
    out = []
    for fn in sorted(os.listdir(AGENTS_DIR)):
        if not fn.endswith(".json"):
            continue
        try:
            with open(os.path.join(AGENTS_DIR, fn), encoding="utf-8") as f:
                item = json.load(f)
            seen = datetime.datetime.fromisoformat(item["seen_utc"].rstrip("Z"))
            item["age_min"] = round(
                (datetime.datetime.utcnow() - seen).total_seconds() / 60, 1)
            out.append(item)
        except Exception:
            continue
    return out


def dashboard_data():
    devices = list_cmd_sites()
    for device in devices:
        device["controllable"] = True
    by_id = {d["site"]: d for d in devices}
    agents = list_agent_snapshots()
    for agent in agents:
        for item in agent.get("devices", []):
            did = item.get("device_id", "")
            candidates = ([did] if did.startswith("tab-") else [did, "tab-" + did]) if did else []
            found = next((by_id[x] for x in candidates if x in by_id), None)
            if found:
                found.setdefault("name", item.get("name"))
                found.setdefault("ip", item.get("ip"))
                found["agent"] = agent["site"]
            else:
                key = ("tab-" + did) if did else "agent-" + safe(
                    agent["site"] + "-" + item.get("ip", ""))
                row = {
                    "site": key, "name": item.get("name"), "ip": item.get("ip"),
                    "meta": {}, "age_min": None, "queue": [], "agent": agent["site"],
                    "controllable": False,
                }
                devices.append(row)
                by_id[key] = row
    return {"devices": devices, "agents": agents,
            "server_utc": datetime.datetime.utcnow().isoformat() + "Z"}


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


def list_files(site):
    sp = os.path.join(DIR, site)
    out = []
    if not os.path.isdir(sp):
        return out
    for fn in os.listdir(sp):
        if not fn.endswith(".log"):
            continue
        p = os.path.join(sp, fn)
        try:
            st = os.stat(p)
        except OSError:
            continue
        out.append({
            "file": fn,
            "live": fn.startswith("_"),
            "size": st.st_size,
            "mtime_utc": datetime.datetime.utcfromtimestamp(st.st_mtime).isoformat() + "Z",
        })
    # live первым, остальные — новые сверху
    live = [x for x in out if x["live"]]
    rest = sorted([x for x in out if not x["live"]], key=lambda x: x["file"], reverse=True)
    return live + rest


# Панель просмотра логов: одна статичная страница, данные тянет сама
# с /list, /files, /view, /live (токен берёт из своего же URL).
PANEL_HTML = r"""<!doctype html>
<html lang="ru"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Brandmen — логи</title>
<style>
:root{
  --bg:#0d1117; --panel:#161b22; --border:#21262d; --fg:#c9d1d9; --muted:#8b949e;
  --accent:#58a6ff; --err:#f85149; --warn:#d29922; --ok:#3fb950; --status:#7ee787;
  --upd:#bc8cff; --ui:#e3b341;
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.45 system-ui,-apple-system,"Segoe UI",sans-serif;height:100vh;display:flex;flex-direction:column}
header{display:flex;align-items:center;gap:10px;flex-wrap:wrap;padding:10px 14px;background:var(--panel);border-bottom:1px solid var(--border)}
header h1{font-size:15px;margin:0;white-space:nowrap}
header h1 .dot{color:var(--accent)}
select,input[type=search]{background:var(--bg);color:var(--fg);border:1px solid var(--border);border-radius:6px;padding:5px 8px;font:inherit}
input[type=search]{flex:1;min-width:140px;max-width:340px}
label.tgl{display:flex;align-items:center;gap:5px;color:var(--muted);white-space:nowrap;cursor:pointer;user-select:none;font-size:13px}
label.tgl input{accent-color:var(--accent)}
a.raw{color:var(--accent);text-decoration:none;font-size:13px;white-space:nowrap}
a.raw:hover{text-decoration:underline}
#stats{margin-left:auto;color:var(--muted);font-size:12px;white-space:nowrap}
#stats b.e{color:var(--err)} #stats b.w{color:var(--warn)}
main{flex:1;display:flex;min-height:0}
#sites{width:230px;flex-shrink:0;overflow-y:auto;background:var(--panel);border-right:1px solid var(--border);padding:6px}
.site{padding:8px 10px;border-radius:8px;cursor:pointer;display:flex;align-items:center;gap:8px}
.site:hover{background:#1c2330}
.site.sel{background:#1f6feb33;outline:1px solid #1f6feb66}
.site .d{width:9px;height:9px;border-radius:50%;flex-shrink:0}
.site .nm{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.site .meta{font-size:11px;color:var(--muted)}
#logwrap{flex:1;overflow:auto;padding:8px 0;font:12.5px/1.5 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
.ln{padding:0 14px;white-space:pre-wrap;word-break:break-word}
.ln:hover{background:#ffffff08}
.ln .ts{color:var(--muted);opacity:.7;margin-right:8px}
.ln .tag{font-weight:600}
.ln.cmd .tag{color:var(--accent)} .ln.cmdok .tag{color:var(--ok)}
.ln.status .tag{color:var(--status)} .ln.upd .tag{color:var(--upd)} .ln.ui .tag{color:var(--ui)}
.ln.err{color:var(--err)} .ln.err .ts{color:var(--err);opacity:.6}
.ln.warn{color:var(--warn)}
.ln.dim{color:var(--muted);opacity:.55}
.ln.boot{color:var(--accent);font-weight:700;border-top:1px solid var(--border);margin-top:6px;padding-top:6px}
.ln .ip{color:#79c0ff} .ln .q{color:#a5d6ff} .ln .ver{color:var(--upd)}
.ln .ok{color:var(--ok)}
.daychip{position:sticky;top:0;margin:8px 14px 4px;display:inline-block;background:var(--panel);border:1px solid var(--border);border-radius:999px;padding:2px 12px;font-size:11px;color:var(--muted)}
#empty{color:var(--muted);padding:40px;text-align:center;font-family:system-ui}
@media(max-width:760px){#sites{width:64px}.site .nm,.site .meta{display:none}}
</style></head><body>
<header>
  <h1>Brandmen<span class="dot"> ·</span> логи</h1>
  <select id="fsel" title="Файл лога"></select>
  <label class="tgl"><input type="checkbox" id="auto" checked>авто</label>
  <label class="tgl"><input type="checkbox" id="errs">только ошибки</label>
  <label class="tgl"><input type="checkbox" id="fold" checked>схлопывать повторы</label>
  <input type="search" id="q" placeholder="фильтр…">
  <a class="raw" id="raw" target="_blank">raw</a>
  <span id="stats"></span>
</header>
<main>
  <nav id="sites"></nav>
  <div id="logwrap"><div id="empty">Выбери ПК слева</div></div>
</main>
<script>
const T=new URLSearchParams(location.search).get('token')||'';
const $=id=>document.getElementById(id);
let curSite=null,curFile=null,rawText='',timer=null;

const esc=s=>s.replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
async function jget(u){const r=await fetch(u);if(!r.ok)throw new Error(r.status);return r.json()}
async function tget(u){const r=await fetch(u);if(!r.ok)throw new Error(r.status);return r.text()}

function ageColor(m){return m==null?'#555':m<15?'var(--ok)':m<120?'var(--warn)':'var(--err)'}
function ageTxt(m){if(m==null)return'—';if(m<1)return'только что';if(m<60)return Math.round(m)+' мин';if(m<1440)return(m/60).toFixed(1)+' ч';return Math.round(m/1440)+' дн'}

async function loadSites(){
  const sites=await jget('/list?token='+T);
  const nav=$('sites');nav.innerHTML='';
  for(const s of sites){
    const el=document.createElement('div');
    el.className='site'+(s.site===curSite?' sel':'');
    el.title=s.site;
    el.innerHTML=`<span class="d" style="background:${ageColor(s.age_min)}"></span>`+
      `<span><div class="nm">${esc(s.site)}</div><div class="meta">${s.count} файл. · ${ageTxt(s.age_min)} назад</div></span>`;
    el.onclick=()=>selectSite(s.site);
    nav.appendChild(el);
  }
  if(!curSite&&sites.length)selectSite(sites[0].site);
}

function fileLabel(f){
  if(f.live)return'🔴 живой поток';
  const m=f.file.match(/^(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})-(\d{2}).*__v(.*)\.log$/);
  if(!m)return f.file;
  return `${m[3]}.${m[2]} ${m[4]}:${m[5]} UTC · v${m[7]} · ${(f.size/1024).toFixed(0)} КБ`;
}

async function selectSite(site){
  curSite=site;
  const files=await jget(`/files?site=${encodeURIComponent(site)}&token=${T}`);
  const sel=$('fsel');sel.innerHTML='';
  for(const f of files){
    const o=document.createElement('option');o.value=f.file;o.textContent=fileLabel(f);
    sel.appendChild(o);
  }
  curFile=files.length?files[0].file:null;
  if(curFile)sel.value=curFile;
  document.querySelectorAll('.site').forEach(e=>e.classList.toggle('sel',e.title===site));
  await loadLog();
}

function logUrl(){
  return curFile&&curFile.startsWith('_')
    ?`/live?site=${encodeURIComponent(curSite)}&token=${T}`
    :`/view?site=${encodeURIComponent(curSite)}&file=${encodeURIComponent(curFile)}&token=${T}`;
}

async function loadLog(){
  if(!curSite||!curFile){return}
  $('raw').href=logUrl();
  try{rawText=await tget(logUrl())}catch(e){rawText='(ошибка загрузки: '+e.message+')'}
  render();
}

function classify(t){
  if(/СБОЙ|ОШИБКА|ОФЛАЙН|Exception|Timeout|ERROR/i.test(t))return'err';
  if(/не удалась|повтор\.\.\.|неподтвержд/i.test(t))return'warn';
  if(t.includes('--- ЗАПУСК'))return'boot';
  if(t.includes('[КОМАНДА]'))return/: OK \(/.test(t)?'cmdok':'cmd';
  if(t.includes('[СТАТУС]'))return'status';
  if(t.includes('[UPD]'))return'upd';
  if(t.includes('[UI]'))return'ui';
  if(t.includes('Лог отправлен'))return'dim';
  return'';
}

function decorate(t){
  let h=esc(t);
  h=h.replace(/^\[([^\]]+)\]/,'<span class="tag">[$1]</span>');
  h=h.replace(/\b(\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?)\b/g,'<span class="ip">$1</span>');
  h=h.replace(/&quot;([^&]*)&quot;/g,'&quot;<span class="q">$1</span>&quot;');
  h=h.replace(/(?<![\d.])(v?\d+\.\d+\.\d+)(?![\d.])/g,'<span class="ver">$1</span>');
  h=h.replace(/: (OK) \(/g,': <span class="ok">$1</span> (');
  return h;
}

function render(){
  const q=$('q').value.toLowerCase(),errsOnly=$('errs').checked,fold=$('fold').checked;
  const wrap=$('logwrap');
  const pinned=wrap.scrollTop+wrap.clientHeight>=wrap.scrollHeight-40;
  const lines=rawText.split('\n').filter(l=>l.trim());
  const out=[];let nErr=0,nWarn=0,lastDay='';
  let i=0;
  const parse=l=>{const m=l.match(/^\[(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2})\] ?(.*)$/);return m?{d:m[1],t:m[2],txt:m[3]}:{d:'',t:'',txt:l}};
  while(i<lines.length){
    const p=parse(lines[i]);
    // схлопывание серий одинаковых служебных строк
    if(fold&&p.txt.includes('Лог отправлен')){
      let j=i;while(j<lines.length&&parse(lines[j]).txt===p.txt)j++;
      if(j-i>=3){
        const a=parse(lines[i]),b=parse(lines[j-1]);
        if(!(errsOnly)&&(!q||p.txt.toLowerCase().includes(q)))
          out.push(`<div class="ln dim"><span class="ts">${a.t} → ${b.t}</span>${esc(p.txt)} ×${j-i}</div>`);
        i=j;continue;
      }
    }
    const cls=classify(p.txt);
    if(cls==='err')nErr++;if(cls==='warn')nWarn++;
    const visible=(!errsOnly||cls==='err'||cls==='warn')&&(!q||lines[i].toLowerCase().includes(q));
    if(visible){
      if(p.d&&p.d!==lastDay){lastDay=p.d;out.push(`<div><span class="daychip">${p.d}</span></div>`)}
      out.push(`<div class="ln ${cls}"><span class="ts">${p.t}</span>${decorate(p.txt)}</div>`);
    }
    i++;
  }
  wrap.innerHTML=out.join('')||'<div id="empty">пусто</div>';
  if(pinned)wrap.scrollTop=wrap.scrollHeight;
  $('stats').innerHTML=`${lines.length} строк · <b class="e">${nErr} ошиб.</b> · <b class="w">${nWarn} предупр.</b>`;
}

$('fsel').onchange=e=>{curFile=e.target.value;loadLog()};
$('q').oninput=render;$('errs').onchange=render;$('fold').onchange=render;

function tick(){
  if(!$('auto').checked)return;
  const isLive=curFile&&curFile.startsWith('_');
  const isLast=curFile===$('fsel').options[0]?.value||isLive;
  loadSites();
  if(isLast)loadLog();
}
setInterval(tick,10000);
loadSites();
</script></body></html>"""


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
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        if ctype.startswith("text/html"):
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Security-Policy",
                             "default-src 'self'; style-src 'self' 'unsafe-inline'; "
                             "script-src 'self' 'unsafe-inline'; img-src 'self' data:; "
                             "frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
        self.end_headers()
        try:
            self.wfile.write(body)
        except Exception:
            pass

    def _redirect(self, location, cookie=None):
        self.send_response(302)
        self.send_header("Location", location)
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _web_or_redirect(self):
        session = web_session(self)
        if session:
            return session
        self._redirect("/login")
        return None

    def _read_form(self):
        n = min(int(self.headers.get("Content-Length", "0") or "0"), 64 * 1024)
        raw = self.rfile.read(n) if n else b""
        try:
            return {k: v[0] for k, v in parse_qs(
                raw.decode("utf-8"), keep_blank_values=True).items()}
        except Exception:
            return {}

    def _stream_release_asset(self, tag, name):
        if not re.fullmatch(r"v0\.\d+\.0", tag) or name not in UPDATE_ASSETS:
            return self._send(400, "invalid update asset")
        cache_path = os.path.join(ASSET_CACHE_DIR, safe(tag + "__" + name))
        if os.path.isfile(cache_path) and os.path.getsize(cache_path) > 0:
            try:
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Content-Length", str(os.path.getsize(cache_path)))
                self.send_header("Content-Disposition", f'attachment; filename="{name}"')
                self.send_header("X-Content-Type-Options", "nosniff")
                self.send_header("X-Brandmen-Cache", "HIT")
                self.end_headers()
                with open(cache_path, "rb") as cached:
                    while True:
                        chunk = cached.read(256 * 1024)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                return
            except Exception as e:
                print(f"[updates] cached download error {tag}/{name}: {e}", flush=True)
                return
        url = f"https://github.com/{UPDATE_REPO}/releases/download/{quote(tag)}/{quote(name)}"
        tmp = cache_path + ".tmp-" + secrets.token_hex(4)
        try:
            req = Request(url, headers={"User-Agent": "BrandmenUpdateMirror/1"})
            with urlopen(req, timeout=60) as response:
                self.send_response(200)
                self.send_header("Content-Type", response.headers.get(
                    "Content-Type", "application/octet-stream"))
                length = response.headers.get("Content-Length")
                if length:
                    self.send_header("Content-Length", length)
                self.send_header("Content-Disposition", f'attachment; filename="{name}"')
                self.send_header("X-Content-Type-Options", "nosniff")
                self.send_header("X-Brandmen-Cache", "MISS")
                self.end_headers()
                with open(tmp, "wb") as cache_file:
                    while True:
                        chunk = response.read(256 * 1024)
                        if not chunk:
                            break
                        cache_file.write(chunk)
                        self.wfile.write(chunk)
                os.replace(tmp, cache_path)
            return
        except Exception as e:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            print(f"[updates] download error {tag}/{name}: {e}", flush=True)
            return self._send(502, "update download unavailable")

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
        if u.path == "/login":
            ip = client_ip(self)
            if not login_allowed(ip):
                return self._send(429, login_page(
                    "Слишком много попыток. Повторите через 5 минут."),
                    "text/html; charset=utf-8")
            form = self._read_form()
            username = form.get("username", "")
            password = form.get("password", "")
            if (hmac.compare_digest(username, ADMIN_USER)
                    and verify_password(password)):
                login_allowed(ip, success=True)
                cookie = (f"{SESSION_COOKIE}={new_session(username)}; Path=/; "
                          f"Max-Age={SESSION_TTL}; Secure; HttpOnly; SameSite=Lax")
                print(f"[web] login {username} from {ip}", flush=True)
                return self._redirect("/panel", cookie)
            return self._send(401, login_page("Неверный логин или пароль."),
                              "text/html; charset=utf-8")
        if u.path == "/agent/snapshot":
            if not api_authed(self):
                return self._send(401, "unauthorized")
            try:
                snapshot = save_agent_snapshot(self._read_json())
                return self._send(200, json.dumps({
                    "ok": True, "devices": len(snapshot["devices"])}),
                    "application/json; charset=utf-8")
            except ValueError as e:
                return self._send(400, str(e))
        # --- Команды планшетам --------------------------------------------
        if u.path == "/commands/enqueue":
            session = web_session(self)
            if not api_authed(self) and not (session and csrf_ok(self, session)):
                return self._send(401, "unauthorized")
            site = safe(q.get("site", [""])[0])
            b = self._read_json()
            cmd = str(b.get("cmd", "")).strip()
            if site == "unknown":
                return self._send(400, "missing site")
            if cmd not in {"launch", "stop", "restart", "wake", "sleep",
                           "reboot", "unmanage", "volume", "brightness"}:
                return self._send(400, "invalid cmd")
            cid = enqueue_cmd(site, cmd, b.get("args") or {})
            print(f"[cmd] enqueue {site} <- {cmd} #{cid}", flush=True)
            return self._send(200, json.dumps({"id": cid}), "application/json; charset=utf-8")
        if u.path == "/commands/ack":
            if not api_authed(self):
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
            if not api_authed(self):
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
        if not api_authed(self):
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
            return self._redirect("/panel" if web_session(self) else "/login")
        if u.path == "/login":
            if web_session(self):
                return self._redirect("/panel")
            return self._send(200, login_page(), "text/html; charset=utf-8")
        if u.path == "/logout":
            return self._redirect("/login",
                                  f"{SESSION_COOKIE}=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Lax")
        if u.path in ("/downloads", "/downloads/file"):
            session = self._web_or_redirect()
            if not session:
                return
            if u.path == "/downloads/file":
                return self._stream_release_asset(
                    q.get("tag", [""])[0], q.get("name", [""])[0])
            try:
                releases = update_releases()
                release = releases[0] if releases else {}
                return self._send(200, downloads_page(session["u"], release),
                                  "text/html; charset=utf-8")
            except Exception as e:
                print(f"[web] downloads error: {e}", flush=True)
                return self._send(502, "release list unavailable")
        if u.path == "/updates/releases":
            if not api_authed(self):
                return self._send(401, "unauthorized")
            try:
                body = json.dumps(update_releases(), ensure_ascii=False)
                return self._send(200, body, "application/json; charset=utf-8")
            except Exception as e:
                print(f"[updates] releases error: {e}", flush=True)
                return self._send(502, "update source unavailable")
        if u.path == "/updates/download":
            if not api_authed(self):
                return self._send(401, "unauthorized")
            tag = q.get("tag", [""])[0]
            name = q.get("name", [""])[0]
            return self._stream_release_asset(tag, name)
        if u.path == "/commands/poll":
            if not api_authed(self):
                return self._send(401, "unauthorized")
            site = safe(q.get("site", [""])[0])
            meta = {k: q.get(k, [""])[0] for k in ("name", "ip", "v", "model") if q.get(k)}
            return self._send(200, json.dumps(poll_cmds(site, meta), ensure_ascii=False),
                              "application/json; charset=utf-8")
        if u.path == "/api/dashboard":
            session = web_session(self)
            if not session:
                return self._send(401, "unauthorized")
            return self._send(200, json.dumps(dashboard_data(), ensure_ascii=False),
                              "application/json; charset=utf-8")
        if u.path in ("/panel", "/list", "/view", "/dash",
                      "/live", "/ui", "/files", "/cmds", "/commands"):
            session = self._web_or_redirect()
            if not session:
                return
        if u.path == "/panel":
            return self._send(200, panel_page(session["u"], session["csrf"]),
                              "text/html; charset=utf-8")
        if u.path == "/ui":
            return self._send(200, PANEL_HTML, "text/html; charset=utf-8")
        if u.path == "/files":
            site = safe(q.get("site", [""])[0])
            return self._send(200, json.dumps(list_files(site), ensure_ascii=False, indent=2),
                              "application/json; charset=utf-8")
        if u.path == "/commands":
            return self._send(200, json.dumps(list_cmd_sites(), ensure_ascii=False, indent=2),
                              "application/json; charset=utf-8")
        if u.path == "/cmds":
            return self._redirect("/panel")
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
            return self._redirect("/panel")
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
