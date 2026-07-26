#!/usr/bin/env python3
"""Проверка разделения объектов (клиентов).

Запуск:  python3 server-logs/test_tenants.py

Тест самодостаточный: поднимает модуль во временной папке со своими
tenants.json и планшетами, ничего не трогает на сервере. Смысл — не дать
незаметно сломать две вещи:
  1) клиент не должен видеть чужие планшеты и не должен входить в чужой
     кабинет;
  2) работающая точка ходит со старым общим токеном и сессией без поля
     объекта — она обязана продолжать работать после выкатки.
"""
import hashlib
import hmac
import importlib.util
import json
import os
import sys
import tempfile
import time

FAILURES = []


def check(condition, title):
    print(("  ok   " if condition else "  ПРОВАЛ ") + title)
    if not condition:
        FAILURES.append(title)


class FakeHandler:
    """Минимальный запрос: только то, что читает проверяемый код."""

    def __init__(self, cookie="", host="brandmen.example.ru", auth=""):
        self.headers = {"Cookie": cookie, "Host": host, "Authorization": auth}
        self.path = "/panel"


def load_module(base):
    os.environ.update({
        "LOG_TOKEN": "SERVICE-TOKEN",
        "LOG_DIR": os.path.join(base, "logs"),
        "CMDS_DIR": os.path.join(base, "cmds"),
        "AGENTS_DIR": os.path.join(base, "agents"),
        "TENANTS_PATH": os.path.join(base, "tenants.json"),
        "ADMIN_USER": "sluzhba",
        "ADMIN_PASSWORD_HASH": "",
        "SESSION_SECRET": "s" * 40,
        "CERT": os.path.join(base, "none"),
        "KEY": os.path.join(base, "none"),
    })
    here = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, here)
    spec = importlib.util.spec_from_file_location(
        "logserver_under_test", os.path.join(here, "logserver.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    base = tempfile.mkdtemp(prefix="brandmen-tenants-")
    for sub in ("logs", "cmds", "agents"):
        os.makedirs(os.path.join(base, sub), exist_ok=True)
    m = load_module(base)

    m.save_tenants({
        "stambul": {
            "name": "Стамбул", "subdomain": "stambul", "token": "TOK-STAMBUL",
            "users": {"vlad": {"hash": m.hash_password("pass-A", 1000)}},
        },
        "kemerovo": {
            "name": "Кемерово", "subdomain": "kemerovo", "token": "TOK-KEMEROVO",
            "users": {"anna": {"hash": m.hash_password("pass-B", 1000)}},
        },
    })
    # По планшету на объект плюс «легаси» без принадлежности — такие сейчас
    # на работающей точке, и они не должны попасть в чужой кабинет.
    for site, tenant in (("tab-A", "stambul"), ("tab-B", "kemerovo"), ("tab-OLD", None)):
        meta = {"ip": "192.168.0.1"}
        if tenant:
            meta["tenant"] = tenant
        with open(os.path.join(base, "cmds", site + ".json"), "w") as f:
            json.dump({"meta": meta, "queue": []}, f)

    print("разделение планшетов")
    everything = {x["site"] for x in m.list_cmd_sites("*")}
    stambul = {x["site"] for x in m.list_cmd_sites("stambul")}
    kemerovo = {x["site"] for x in m.list_cmd_sites("kemerovo")}
    check(everything == {"tab-A", "tab-B", "tab-OLD"}, "служебный доступ видит все")
    check(stambul == {"tab-A"}, "объект видит только свои планшеты")
    check(kemerovo == {"tab-B"}, "второй объект видит только свои")
    check("tab-OLD" not in stambul and "tab-OLD" not in kemerovo,
          "планшет без объекта не достаётся никому, кроме служебного доступа")

    print("токены")
    check(m.tenant_for_token("SERVICE-TOKEN") == "*", "служебный токен открывает всё")
    check(m.tenant_for_token("TOK-STAMBUL") == "stambul", "токен объекта — свой объект")
    check(m.tenant_for_token("посторонний") is None, "неизвестный токен отвергнут")
    check(m.tenant_for_token("") is None, "пустой токен отвергнут")

    print("вход в кабинет")
    check(m.authenticate_user("stambul", "vlad", "pass-A") == "stambul",
          "свой логин в своём кабинете")
    check(m.authenticate_user("kemerovo", "vlad", "pass-A") is None,
          "свой логин в чужом кабинете отвергнут")
    check(m.authenticate_user("stambul", "vlad", "не тот") is None,
          "неверный пароль отвергнут")

    print("поддомены")
    check(m.tenant_for_host(FakeHandler(host="stambul.example.ru")) == "stambul",
          "поддомен определяет объект")
    check(m.tenant_for_host(FakeHandler(host="brandmen.example.ru")) is None,
          "основной домен объекта не задаёт")

    print("совместимость с работающей точкой")
    legacy = {"u": "sluzhba", "exp": int(time.time()) + 3600, "csrf": "x"}
    raw = m._b64e(json.dumps(legacy, separators=(",", ":")).encode())
    sig = hmac.new(m.SESSION_SECRET.encode(), raw.encode(), hashlib.sha256).hexdigest()
    session = m.web_session(FakeHandler(cookie=f"{m.SESSION_COOKIE}={raw}.{sig}"))
    check(session is not None, "сессия, выданная до появления объектов, работает")
    check(session and session.get("t", "*") == "*", "и означает служебный доступ")
    check(m.request_tenant(FakeHandler(auth="Bearer SERVICE-TOKEN")) == "*",
          "пульт со старым общим токеном видит всё")

    print("чужой кабинет по своей куке")
    cookie = f"{m.SESSION_COOKIE}={m.new_session('vlad', 'stambul')}"
    check(m.web_session(FakeHandler(cookie=cookie, host="stambul.example.ru")) is not None,
          "свой кабинет открывается")
    check(m.web_session(FakeHandler(cookie=cookie, host="kemerovo.example.ru")) is None,
          "чужой кабинет не открывается")

    print()
    if FAILURES:
        print(f"ПРОВАЛЕНО ПРОВЕРОК: {len(FAILURES)}")
        for title in FAILURES:
            print("  -", title)
        return 1
    print("все проверки пройдены")
    return 0


if __name__ == "__main__":
    sys.exit(main())
