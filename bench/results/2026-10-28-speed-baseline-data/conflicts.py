"""Одинаковы ли ответы двух серверов bookings на одну и ту же последовательность POST.

    python3 conflicts.py <порт A> <порт B> [запросов]

Оба сервера уже заполнены load/seed.py. Запросы — как eval/load/bookings.lua
(комната 1–20, день 1–28, час 0–21, бронь на час с :30), зерно фиксировано.
Печатает число 201/409/прочих у каждого и первые расхождения.
"""
import collections
import http.client
import json
import random
import sys

pa, pb = int(sys.argv[1]), int(sys.argv[2])
n = int(sys.argv[3]) if len(sys.argv) > 3 else 20000
ca, cb = http.client.HTTPConnection("127.0.0.1", pa), http.client.HTTPConnection("127.0.0.1", pb)
rnd = random.Random(11)
cnt = [collections.Counter(), collections.Counter()]
diff = 0
for i in range(n):
    room, day, hour = rnd.randint(1, 20), rnd.randint(1, 28), rnd.randint(0, 21)
    body = json.dumps({"room_id": room, "title": "Load",
                       "start": f"2026-11-{day:02}T{hour:02}:30:00Z", "end": f"2026-11-{day:02}T{hour + 1:02}:30:00Z"})
    st = []
    for k, c in enumerate((ca, cb)):
        c.request("POST", "/bookings", body, {"Content-Type": "application/json"})
        r = c.getresponse()
        r.read()
        st.append(r.status)
        cnt[k][r.status] += 1
    if st[0] != st[1]:
        diff += 1
        if diff <= 5:
            print("различие", i, body, st)
print("A:", dict(cnt[0]), "B:", dict(cnt[1]), "различий", diff)
