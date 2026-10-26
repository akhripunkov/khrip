# Нагрузка bench/gc/dense.sh: nhold держателей (GET /hold?ms=...) и один
# писатель (POST /churn/2000) secs секунд; печатает задержки писателя и ответы.
import http.client, sys, threading, time

port, secs, ms, nhold = int(sys.argv[1]), float(sys.argv[2]), sys.argv[3], int(sys.argv[4])
stop = time.time() + secs
res = {}
lock = threading.Lock()


def hold():
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=120)
    while time.time() < stop:
        c.request("GET", "/hold?ms=" + ms)
        b = c.getresponse().read().decode()
        with lock:
            res[b] = res.get(b, 0) + 1


def churn():
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=120)
    lat = []
    while time.time() < stop:
        t = time.time()
        c.request("POST", "/churn/2000", body=b"")
        c.getresponse().read()
        lat.append(time.time() - t)
    lat.sort()
    print("writer: %d requests, p50 %.2f ms, p99 %.2f ms, max %.2f ms" % (len(lat), lat[len(lat) // 2] * 1e3, lat[int(len(lat) * 0.99)] * 1e3, lat[-1] * 1e3))


ts = [threading.Thread(target=hold) for _ in range(nhold)] + [threading.Thread(target=churn)]
for t in ts:
    t.start()
for t in ts:
    t.join()
print("holders:", res)
