#!/usr/bin/env python3
"""Ловушка пауз сервера под нагрузкой (этап памяти, часть 1b).

    stall_probe.py <pid> <папка> [--port 8080] [--path /__probe] [--conns 4]
                   [--every-ms 5] [--slow-ms 20] [--blocked-ms 30]

Пока жив процесс <pid> (или до SIGTERM), два занятия одновременно; время —
CLOCK_MONOTONIC в мс (как у ts_lines.py и rss_sample.py ... abs), поэтому
строки разных файлов можно сопоставить:

  - зонд: --conns соединений keep-alive, по каждому каждые --every-ms мс —
    дешёвый запрос (по умолчанию 404 без store); ответ дольше --slow-ms — в
    probe.tsv (время отправки, соединение, задержка мс). Соединения
    раскладываются ядром по рабочим потокам (SO_REUSEPORT), так что видно паузу
    любого из них;
  - потоки: каждые --every-ms мс /proc/<pid>/task/*/stat (состояние, процессор)
    и, если поток спит, /proc/<pid>/task/<tid>/syscall (номер вызова и
    аргументы: futex с адресом и ожидаемым значением, epoll_wait, nanosleep).
    Отрезок сна в одном и том же вызове дольше --blocked-ms — в threads.tsv
    (поток, начало, длительность, вызов, процессор потока за отрезок в тиках).

В конце — summary.txt: число запросов зонда, медленных, наибольшая задержка.
"""
import os
import signal
import socket
import sys
import threading
import time


def now_ms():
    return time.monotonic() * 1000.0


stop = threading.Event()


def prober(port, path, conn_no, every_ms, slow_ms, out, lock, stats):
    req = f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".encode()
    s = None
    nxt = now_ms()
    while not stop.is_set():
        try:
            if s is None:
                s = socket.create_connection(("127.0.0.1", port), timeout=10)
                s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            t0 = now_ms()
            s.sendall(req)
            buf = b""
            while b"\r\n\r\n" not in buf:
                chunk = s.recv(65536)
                if not chunk:
                    raise OSError("closed")
                buf += chunk
            head, _, body = buf.partition(b"\r\n\r\n")
            n = 0
            for line in head.split(b"\r\n"):
                if line.lower().startswith(b"content-length:"):
                    n = int(line.split(b":")[1])
            while len(body) < n:
                chunk = s.recv(65536)
                if not chunk:
                    raise OSError("closed")
                body += chunk
            lat = now_ms() - t0
            with lock:
                stats["n"] += 1
                stats["max"] = max(stats["max"], lat)
                if lat > slow_ms:
                    stats["slow"] += 1
                    out.write(f"{t0:.1f}\t{conn_no}\t{lat:.1f}\n")
        except OSError:
            if s is not None:
                s.close()
            s = None
            time.sleep(0.05)
        nxt += every_ms
        d = nxt - now_ms()
        if d > 0:
            time.sleep(d / 1000.0)
        else:
            nxt = now_ms()


def read(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return None


def sampler(pid, every_ms, blocked_ms, out):
    cur = {}  # tid -> [начало, вызов, тики в начале]
    task = f"/proc/{pid}/task"
    nxt = now_ms()
    while not stop.is_set():
        try:
            tids = os.listdir(task)
        except OSError:
            break
        t = now_ms()
        for tid in tids:
            st = read(f"{task}/{tid}/stat")
            if st is None:
                continue
            f = st[st.rfind(")") + 2:].split()
            state = f[0]
            ticks = int(f[11]) + int(f[12])
            sc = None
            if state != "R":
                s = read(f"{task}/{tid}/syscall")
                if s is not None:
                    p = s.split()
                    # номер и первые три аргумента: адрес, операция, значение
                    sc = " ".join(p[:4])
            c = cur.get(tid)
            if c is not None and c[1] == sc and sc is not None:
                continue
            if c is not None and c[1] is not None and t - c[0] >= blocked_ms:
                out.write(f"{tid}\t{c[0]:.1f}\t{t - c[0]:.1f}\t{c[1]}\t{ticks - c[2]}\n")
            cur[tid] = [t, sc, ticks]
        nxt += every_ms
        d = nxt - now_ms()
        if d > 0:
            time.sleep(d / 1000.0)
        else:
            nxt = now_ms()


def main():
    a = sys.argv[1:]
    pid, d = int(a[0]), a[1]

    def opt(name, dflt):
        return type(dflt)(a[a.index(name) + 1]) if name in a else dflt
    port = opt("--port", 8080)
    path = opt("--path", "/__probe")
    conns = opt("--conns", 4)
    every = opt("--every-ms", 5.0)
    slow = opt("--slow-ms", 20.0)
    blocked = opt("--blocked-ms", 30.0)
    os.makedirs(d, exist_ok=True)
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    po = open(os.path.join(d, "probe.tsv"), "a", buffering=1)
    to = open(os.path.join(d, "threads.tsv"), "a", buffering=1)
    lock = threading.Lock()
    stats = {"n": 0, "slow": 0, "max": 0.0}
    ths = [threading.Thread(target=prober, args=(port, path, i, every, slow, po, lock, stats), daemon=True)
           for i in range(conns)]
    ths.append(threading.Thread(target=sampler, args=(pid, every, blocked, to), daemon=True))
    for t in ths:
        t.start()
    while not stop.is_set() and os.path.exists(f"/proc/{pid}"):
        stop.wait(0.2)
    stop.set()
    for t in ths:
        t.join(timeout=2)
    with open(os.path.join(d, "summary.txt"), "a") as f:
        f.write(f"probes {stats['n']}, slower than {slow:g} ms {stats['slow']}, max {stats['max']:.1f} ms\n")


if __name__ == "__main__":
    main()
