"""Нагрузка матрицы держателей сборщика store (tests/gc.sh, tests/gc/server.kh).

    python3 drive.py load <порт> <секунд>   — писатели меняют товары, держатели
                                             ждут с ними; печатает итог JSON
    python3 drive.py check <файл KHRIP_DATA> — снимок цел: имена товаров с
                                             правильной проверкой, деньги на месте

Каждый поток — своё соединение keep-alive. Держатели проверяют ответ сервера
("ok"), счётчик и переводы — по итогам в конце.
"""
import http.client
import json
import random
import sys
import threading
import time

N = 2000


def name_ok(pid, s):
    parts = s.split(":")
    if len(parts) != 3 or parts[0] != f"p{pid}" or not parts[1].isdigit():
        return False
    v = int(parts[1])
    return parts[2] == str((pid * 7919 + v * 104729) % 1000003)


def check_file(path):
    data = json.load(open(path, encoding="utf-8"))
    products = data["products"]
    bad = [k for k, p in products.items() if p["id"] != int(k) or not name_ok(p["id"], p["name"]) or p["tags"][:2] != [f"t{k}", "all"]]
    money = sum(a["balance"] for a in data["accounts"].values())
    print(json.dumps({"products": len(products), "bad": bad[:5], "money": money}))


def load(port, seconds):
    stop = time.time() + seconds
    lock = threading.Lock()
    stats = {}
    bad = []
    bumps = [0]

    def note(route, ok, detail=""):
        with lock:
            s = stats.setdefault(route, [0, 0])
            s[0] += 1
            if not ok:
                s[1] += 1
                if len(bad) < 20:
                    bad.append(f"{route}: {detail}")

    def connect():
        return http.client.HTTPConnection("127.0.0.1", port, timeout=120)

    def req(c, method, path):
        c.request(method, path)
        r = c.getresponse()
        return r.status, r.read().decode("utf-8", "replace")

    def loop(fn):
        c = connect()
        rnd = random.Random()
        while time.time() < stop:
            try:
                fn(c, rnd)
            except Exception as e:  # noqa: BLE001 — любой сбой соединения — ошибка теста
                note("connection", False, repr(e))
                c = connect()

    def churn(c, rnd):
        i = rnd.randrange(N)
        if rnd.random() < 0.5:
            s, b = req(c, "PATCH", f"/p/{i}")
        else:
            s, b = req(c, "POST", f"/churn/{i}/20")
        note("churn", s == 200 and b == "ok", f"{s} {b}")

    def holder(c, rnd):
        i = rnd.randrange(N)
        kind = rnd.choice(["hold", "slice", "loop", "temps", "map", "search", "resurrect"])
        if kind == "hold":
            s, b = req(c, "GET", f"/hold/{i}?ms={rnd.choice([5, 50, 200])}")
        elif kind == "resurrect":
            s, b = req(c, "POST", f"/resurrect/{i}")
        else:
            s, b = req(c, "GET", f"/{kind}/{i}")
        note(kind, s == 200 and b == "ok", f"{s} {b}")

    def poll(c, rnd):
        s, b = req(c, "GET", "/poll")
        note("poll", s == 200 and b == "ok", f"{s} {b}")

    def login(c, rnd):
        s, b = req(c, "POST", "/login")
        note("login", s == 200 and b == "ok", f"{s} {b}")

    def rotate(c, rnd):
        s, b = req(c, "POST", "/rotate")
        note("rotate", s == 200 and b == "ok", f"{s} {b}")

    def fx(c, rnd):
        s, b = req(c, "POST", "/fx")
        note("fx", s == 200 and b == "ok", f"{s} {b}")

    def hdrs(c, rnd):
        s, b = req(c, "POST", f"/hdrs/{rnd.randrange(1000)}")
        note("hdrs", s == 200 and b == "ok", f"{s} {b}")

    def boom(c, rnd):
        path = rnd.choice(["/boom/", "/boom-fetch/"]) + str(rnd.randrange(N))
        s, b = req(c, "GET", path)
        note("boom", s == 500, f"{s} {b}")

    def bump(c, rnd):
        s, b = req(c, "POST", f"/bump/{rnd.randrange(1000)}")
        ok = s == 204
        if ok:
            with lock:
                bumps[0] += 1
        note("bump", ok, f"{s} {b}")

    def transfer(c, rnd):
        s, b = req(c, "POST", f"/transfer/{rnd.randrange(100)}/{rnd.randrange(100)}/{rnd.randrange(1, 50)}")
        note("transfer", s == 200 and b == "ok", f"{s} {b}")

    def feed(c, rnd):
        s, b = req(c, "POST", f"/feed/{rnd.randrange(1, 30)}")
        note("feed", s == 200 and b == "ok", f"{s} {b}")

    plan = [churn] * 6 + [holder] * 10 + [poll] * 3 + [login, rotate, fx, fx, hdrs, boom, bump, bump, transfer, transfer, feed]
    threads = [threading.Thread(target=loop, args=(fn,)) for fn in plan]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    c = connect()
    out = {"routes": stats, "bad": bad, "bumps": bumps[0]}
    for key, path in [("count", "/count"), ("sum", "/sum"), ("every", "/every"), ("resurrected", "/resurrected"), ("poll", "/poll?ms=0")]:
        out[key] = req(c, "GET", path)[1]
    print(json.dumps(out))


if __name__ == "__main__":
    if sys.argv[1] == "check":
        check_file(sys.argv[2])
    else:
        load(int(sys.argv[2]), float(sys.argv[3]))
