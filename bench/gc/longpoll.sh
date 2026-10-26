#!/usr/bin/env bash
# Долгий опрос (docs/design/v0.13-store-gc.md §16): 200 клиентов по 30 с держат
# products.values() (GET /poll: снимок всех товаров, 60 ожиданий по 500 мс,
# затем проверка каждого имени — у имён своя контрольная сумма), пока писатели
# заменяют товары (PATCH /p/{id}). Ни одной ошибки; RSS, пока опросы держат
# снимки, не больше цели store без опросов + того, что опросы держат, + 10 МБ.
# Сервер tests/gc/server.kh на 4 потоках. Последние секунды не в счёт: 200
# опросов разом проверяют по 2000 товаров, и временные строки проверки — в
# аренах запросов (до 1,3 МБ на запрос), к сборщику они не относятся; общий
# пик печатается отдельно.
#
#   bench/gc/longpoll.sh [корень khc]   (по умолчанию этот репозиторий)
#
# Порт GATE_PORT (по умолчанию 8080).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
kroot=${1:-$root}
port=${GATE_PORT:-8080}
tmp=$(mktemp -d)
pid=
trap '[[ -n $pid ]] && kill $pid 2>/dev/null; wait 2>/dev/null; rm -rf "$tmp"' EXIT
KHRIP_GC_LOG=1 "$kroot/build/khc" -o "$tmp/srv" "$root/tests/gc/server.kh" || exit 1
url=http://127.0.0.1:$port

PORT=$port THREADS=4 KHRIP_GC_LOG=1 "$tmp/srv" 2>"$tmp/log" &
pid=$!
for _ in $(seq 500); do
	curl -s -o /dev/null --max-time 1 "$url/count" && break
	sleep 0.01
done
curl -s -o /dev/null -X POST "$url/seed"
python3 - "$port" "$pid" "$tmp/log" <<'PY'
import http.client, re, sys, threading, time
port, pid, logf = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]

def get(path, method="GET"):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=120)
    c.request(method, path, body=b"" if method != "GET" else None)
    r = c.getresponse()
    b = r.read().decode()
    c.close()
    return r.status, b

def rss():
    for l in open(f"/proc/{pid}/status"):
        if l.startswith("VmRSS:"):
            return int(l.split()[1])

def stats():
    cyc, heap, live = map(int, get("/gcstats")[1].split())
    return cyc, heap, live

# цель store без опросов: всё, что заполнение положило в store, живо
# (KHRIP_GC = 100, не меньше 4 МБ)
time.sleep(0.5)
c0, live0, _ = stats()
goal0 = max(4 << 20, 2 * live0)
rss0 = rss()
stop = time.time() + 32
res, bad = {}, []
lock = threading.Lock()
patches = [0]

def poll():
    s, b = get("/poll?ms=500")
    with lock:
        res[(s, b)] = res.get((s, b), 0) + 1

def churn(k):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=120)
    i = k
    while time.time() < stop:
        c.request("PATCH", f"/p/{i % 2000}")
        r = c.getresponse()
        b = r.read().decode()
        if r.status != 200 or b != "ok":
            with lock:
                bad.append(f"PATCH {r.status} {b}")
        with lock:
            patches[0] += 1
        i += 7

ws = [threading.Thread(target=churn, args=(k,)) for k in range(4)]
ps = [threading.Thread(target=poll) for _ in range(200)]
for t in ws + ps:
    t.start()
peak, hold_peak, live_peak = 0, 0, 0
t0 = time.time()
while any(t.is_alive() for t in ps):
    time.sleep(0.5)
    r = rss()
    peak = max(peak, r)
    if time.time() - t0 < 28:
        hold_peak = max(hold_peak, r)
    live_peak = max(live_peak, stats()[2])
for t in ws + ps:
    t.join()
c1, h1, live1 = stats()
ok = res.get((200, "ok"), 0) + res.get((200, "ok~"), 0) + res.get((200, "ok+"), 0)
errors = sum(v for k, v in res.items() if k[0] != 200 or k[1] not in ("ok", "ok~", "ok+")) + len(bad)
pinned = max(0, live_peak - live0)
limit = (goal0 + pinned) // 1024 + 10 * 1024
log = open(logf).read()
inreq = len(re.findall(r"in request", log))
print(f"200 polls x 30 s: {ok} ok, {errors} errors ({dict(list(res.items())[:4])}, {bad[:3]}); {patches[0]} patches; {c1 - c0} cycles ({inreq} at the hard limit)")
print(f"store before: live {live0 // 1024} KB, goal {goal0 // 1024} KB; live peak during the polls {live_peak // 1024} KB (pinned {pinned // 1024} KB); RSS before {rss0} KB, while holding {hold_peak} KB, peak with the final checks {peak} KB; gate goal + pinned + 10 MB = {limit} KB: {'ok' if hold_peak <= limit and errors == 0 else 'FAIL'}")
sys.exit(0 if hold_peak <= limit and errors == 0 else 1)
PY
