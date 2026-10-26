#!/usr/bin/env python3
"""Процессор машины и потоков сервера во времени (этап памяти, часть 1b):
отличить паузу сервера от паузы машины.

    cpu_trace.py <pid> <файл> [шаг, мс = 50]

Каждые «шаг» мс — строка «мс CLOCK_MONOTONIC<TAB>кража cpu0..cpu3, мс<TAB>
простой cpu0..cpu3, мс<TAB>потоки сервера: tid:на процессоре мс:в очереди мс,…»
по /proc/stat (столбец steal — время, которое гипервизор отдал другим машинам)
и /proc/<pid>/task/*/schedstat (время на процессоре и время готовности без
процессора). Пока жив процесс или до SIGTERM.
"""
import os
import signal
import sys
import time

HZ = os.sysconf("SC_CLK_TCK")


def cpus():
    r = {}
    with open("/proc/stat") as f:
        for line in f:
            if line.startswith("cpu") and line[3].isdigit():
                p = line.split()
                r[p[0]] = (int(p[4]) + int(p[5]), int(p[8]))  # простой (+iowait), кража
    return r


def threads(pid):
    r = {}
    d = f"/proc/{pid}/task"
    for tid in os.listdir(d):
        try:
            with open(f"{d}/{tid}/schedstat") as f:
                run, wait, _ = f.read().split()
            r[tid] = (int(run), int(wait))
        except (OSError, ValueError):
            pass
    return r


def main():
    pid, path = int(sys.argv[1]), sys.argv[2]
    step = (float(sys.argv[3]) if len(sys.argv) > 3 else 50.0) / 1000.0
    stop = []
    signal.signal(signal.SIGTERM, lambda *_: stop.append(1))
    signal.signal(signal.SIGINT, lambda *_: stop.append(1))
    names = ["cpu0", "cpu1", "cpu2", "cpu3"]
    pc, pt = cpus(), threads(pid)
    nxt = time.monotonic()
    with open(path, "a", buffering=1) as out:
        while not stop and os.path.exists(f"/proc/{pid}"):
            nxt += step
            d = nxt - time.monotonic()
            if d > 0:
                time.sleep(d)
            try:
                c, t = cpus(), threads(pid)
            except OSError:
                break
            ms = 1000.0 / HZ
            steal = "\t".join(f"{(c[n][1] - pc[n][1]) * ms:.0f}" if n in c and n in pc else "-" for n in names)
            idle = "\t".join(f"{(c[n][0] - pc[n][0]) * ms:.0f}" if n in c and n in pc else "-" for n in names)
            th = ",".join(f"{k}:{(v[0] - pt[k][0]) / 1e6:.1f}:{(v[1] - pt[k][1]) / 1e6:.1f}"
                          for k, v in sorted(t.items()) if k in pt)
            out.write(f"{time.monotonic() * 1000:.1f}\t{steal}\t{idle}\t{th}\n")
            pc, pt = c, t


if __name__ == "__main__":
    main()
