"""same.py <порт A> <порт B> <сценарий> — одинаковы ли ответы двух серверов на набор запросов"""
import http.client, random, sys
pa, pb, sc = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
ca, cb = http.client.HTTPConnection("127.0.0.1", pa), http.client.HTTPConnection("127.0.0.1", pb)
rnd = random.Random(1)
words = ["apple", "steel", "green", "pro", "mini", "ultra", "classic", "smart", "eco", "max", "APPLE", "Gre", ""]
paths = []
if sc == "catalog":
    for _ in range(300):
        r = rnd.random()
        if r < 0.4:
            paths.append(("GET", f"/products?category=cat{rnd.randint(0,19)}&sort={rnd.choice(['price','-price','name'])}&page={rnd.randint(1,3)}&per_page=20", None))
        elif r < 0.8:
            lo = rnd.randint(1, 400)
            paths.append(("GET", f"/products?q={rnd.choice(words)}&min_price={lo}&max_price={lo+100}&sort={rnd.choice(['price','-price','name'])}", None))
        elif r < 0.9:
            paths.append(("GET", f"/products?tag={rnd.choice(words)}&per_page=100&page={rnd.randint(1,5)}", None))
        else:
            paths.append(("GET", "/categories", None))
else:
    for _ in range(300):
        room, day = rnd.randint(1, 21), rnd.randint(1, 28)
        if rnd.random() < 0.6:
            paths.append(("GET", f"/rooms/{room}/bookings?date=2026-11-{day:02}", None))
        else:
            h = rnd.randint(0, 21)
            paths.append(("POST", "/bookings", f'{{"room_id":{room},"title":"T","start":"2026-11-{day:02}T{h:02}:30:00Z","end":"2026-11-{day:02}T{h+1:02}:30:00Z"}}'))
    for room in range(1, 21):
        paths.append(("GET", f"/rooms/{room}/bookings", None))
bad = 0
for m, p, body in paths:
    out = []
    for c in (ca, cb):
        c.request(m, p, body, {"Content-Type": "application/json"} if body else {})
        r = c.getresponse()
        out.append((r.status, r.read()))
    if out[0] != out[1]:
        bad += 1
        if bad <= 3:
            print("DIFF", m, p, out[0][0], out[1][0], out[0][1][:120], out[1][1][:120])
print(f"{len(paths)} запросов, различий {bad}")
