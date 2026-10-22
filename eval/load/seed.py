"""Данные для нагрузочного замера и проверка после него.

    python3 seed.py seed <сценарий>    — заполнить сервер; печатает KEY=VALUE для wrk
    python3 seed.py verify <сценарий>  — проверить инварианты после нагрузки

Данные одинаковые для всех языков (фиксированное зерно случайности).
"""
import http.client
import json
import random
import sys

conn = http.client.HTTPConnection("127.0.0.1", 8080)


def req(method, path, body=None, headers=None):
    h = {"Content-Type": "application/json", **(headers or {})}
    conn.request(method, path, json.dumps(body) if body is not None else None, h)
    r = conn.getresponse()
    data = r.read()
    try:
        return r.status, json.loads(data)
    except ValueError:
        return r.status, data


def must(status, want, what):
    if status != want:
        sys.exit(f"seed: {what}: {status}, ожидалось {want}")


ACCOUNTS = 100
BALANCE = 1_000_000_000
ITEMS = 200
STOCK = 1_000_000_000

CATEGORIES = 10
PRODUCTS = 500
USERS = 50
PROJECTS = ["API", "WEB", "OPS", "DATA", "MOB"]
ISSUES = 200

WORDS = ["apple", "steel", "green", "pro", "mini", "ultra", "classic", "smart", "eco", "max"]


def seed(scenario):
    rnd = random.Random(42)
    if scenario == "shortener":
        for i in range(1000):
            s, _ = req("POST", "/links", {"url": f"https://example.com/page/{i}", "code": f"code{i}"})
            must(s, 201, "link")
    elif scenario == "bank":
        for i in range(ACCOUNTS):
            s, a = req("POST", "/accounts", {"owner": f"owner{i}"})
            must(s, 201, "account")
            s, _ = req("POST", f"/accounts/{a['id']}/deposit", {"amount": BALANCE})
            must(s, 200, "deposit")
    elif scenario in ("notes", "login"):
        s, _ = req("POST", "/register", {"username": "bench", "password": "bench-password"})
        must(s, 201, "register")
        s, t = req("POST", "/login", {"username": "bench", "password": "bench-password"})
        must(s, 200, "login")
        for i in range(50):
            s, _ = req("POST", "/notes", {"title": f"note {i}", "text": "x" * 200},
                       {"Authorization": "Bearer " + t["token"]})
            must(s, 201, "note")
        print("TOKEN=" + t["token"])
    elif scenario == "ratelimit":
        pass
    elif scenario in ("catalog", "patch"):
        for i in range(2000):
            body = {
                "name": f"{rnd.choice(WORDS).title()} {rnd.choice(WORDS)} {i}",
                "category": f"cat{i % 20}",
                "price": round(rnd.uniform(1, 500), 2),
                "tags": rnd.sample(WORDS, 2),
            }
            s, _ = req("POST", "/products", body)
            must(s, 201, "product")
    elif scenario == "inventory":
        for i in range(ITEMS):
            s, _ = req("POST", "/items", {"sku": f"SKU-{i:03}", "name": f"Item {i}", "stock": STOCK})
            must(s, 201, "item")
    elif scenario == "polls":
        for i in range(100):
            s, _ = req("POST", "/polls", {"question": f"Question {i}?", "options": [f"option {k}" for k in range(5)]})
            must(s, 201, "poll")
    elif scenario == "bookings":
        for i in range(20):
            s, _ = req("POST", "/rooms", {"name": f"Room {i}", "capacity": 4 + i % 8})
            must(s, 201, "room")
        made = 0
        while made < 500:
            day, hour = rnd.randint(1, 28), rnd.randint(0, 21)
            body = {"room_id": rnd.randint(1, 20), "title": "Meeting",
                    "start": f"2026-11-{day:02}T{hour:02}:00:00Z", "end": f"2026-11-{day:02}T{hour + 1:02}:00:00Z"}
            s, _ = req("POST", "/bookings", body)
            made += s == 201
    elif scenario == "ledger":
        for i in range(ACCOUNTS):
            s, a = req("POST", "/accounts", {"owner": f"owner{i}", "currency": "USD"})
            must(s, 201, "account")
            s, _ = req("POST", f"/accounts/{a['id']}/deposit", {"amount": BALANCE})
            must(s, 200, "deposit")
    elif scenario == "shop":
        for i in range(CATEGORIES):
            s, _ = req("POST", "/categories", {"name": f"Category {i}"})
            must(s, 201, "category")
        for i in range(PRODUCTS):
            body = {"name": f"{rnd.choice(WORDS).title()} {rnd.choice(WORDS)} {i}",
                    "category_id": 1 + i % CATEGORIES, "price": rnd.randint(100, 50000),
                    "stock": STOCK, "tags": rnd.sample(WORDS, 2)}
            s, _ = req("POST", "/products", body)
            must(s, 201, "product")
    elif scenario == "tracker":
        for i in range(USERS):
            s, _ = req("POST", "/users", {"email": f"user{i}@example.com", "name": f"User {i}"})
            must(s, 201, "user")
        for p in PROJECTS:
            s, _ = req("POST", "/projects", {"key": p, "name": f"Project {p}", "owner_id": 1})
            must(s, 201, "project")
            for k in range(ISSUES):
                body = {"title": f"Issue {k} {rnd.choice(WORDS)}", "priority": rnd.choice(["low", "medium", "high"]),
                        "assignee_id": rnd.randint(1, USERS)}
                s, _ = req("POST", f"/projects/{p}/issues", body)
                must(s, 201, "issue")
    else:
        sys.exit(f"неизвестный сценарий {scenario}")


def verify(scenario):
    """Инварианты, которые нарушаются при гонках: деньги и товар не теряются."""
    if scenario == "bank":
        total = 0
        for i in range(1, ACCOUNTS + 1):
            s, a = req("GET", f"/accounts/{i}")
            must(s, 200, "account")
            total += a["balance"]
        return total == ACCOUNTS * BALANCE, f"сумма балансов {total}, должна быть {ACCOUNTS * BALANCE}"
    if scenario == "inventory":
        s, items = req("GET", "/items")
        s2, orders = req("GET", "/orders?status=placed")
        stock = sum(i["stock"] for i in items)
        ordered = sum(o["total_qty"] for o in orders)
        return stock + ordered == ITEMS * STOCK, f"на складе {stock} + в заказах {ordered} ≠ {ITEMS * STOCK}"
    if scenario == "ledger":
        s, st = req("GET", "/stats")
        must(s, 200, "stats")
        total = st["balances"]["USD"]
        return total == ACCOUNTS * BALANCE, f"сумма балансов {total}, должна быть {ACCOUNTS * BALANCE}"
    if scenario == "shop":
        stock = 0
        for page in range(1, PRODUCTS // 50 + 2):
            s, r = req("GET", f"/products?per_page=50&page={page}")
            must(s, 200, "products")
            stock += sum(p["stock"] for p in r["items"])
        s, cats = req("GET", "/stats/categories")
        must(s, 200, "stats")
        sold = sum(c["units_sold"] for c in cats)
        return stock + sold == PRODUCTS * STOCK, f"на складе {stock} + продано {sold} ≠ {PRODUCTS * STOCK}"
    if scenario == "tracker":
        for p in PROJECTS:
            s, issues = req("GET", f"/projects/{p}/issues")
            must(s, 200, "issues")
            nums = [i["number"] for i in issues]
            if nums != list(range(1, len(nums) + 1)):
                return False, f"номера задач {p} с пропусками или повторами"
        return True, ""
    return True, ""


if __name__ == "__main__":
    if sys.argv[1] == "seed":
        seed(sys.argv[2])
    else:
        ok, why = verify(sys.argv[2])
        print("ok" if ok else "FAIL " + why)
