"""Заполнить bookings до N броней теми же случайными POST, что eval/load/bookings.lua.

    python3 fill_bookings.py <порт> <N>   — печатает, сколько броней стало и сколько POST ушло
"""
import http.client
import json
import random
import sys

port, target = int(sys.argv[1]), int(sys.argv[2])
c = http.client.HTTPConnection("127.0.0.1", port)


def count():
    n = 0
    for r in range(1, 21):
        c.request("GET", f"/rooms/{r}/bookings")
        n += len(json.loads(c.getresponse().read()))
    return n


rnd = random.Random(7)
n = count()
posts = 0
while n < target:
    room, day, hour = rnd.randint(1, 20), rnd.randint(1, 28), rnd.randint(0, 21)
    body = json.dumps({"room_id": room, "title": "Load",
                       "start": f"2026-11-{day:02}T{hour:02}:30:00Z", "end": f"2026-11-{day:02}T{hour + 1:02}:30:00Z"})
    c.request("POST", "/bookings", body, {"Content-Type": "application/json"})
    r = c.getresponse()
    r.read()
    posts += 1
    if r.status == 201:
        n += 1
print(n, posts)
