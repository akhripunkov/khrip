#!/usr/bin/env python3
"""Паузы прогона bench/mem/long.sh: что было в машине и в сервере, пока зонд
ждал ответа.

    stalls.py <папка варианта> [--min-ms 50] [--all]   (--all — и вне замера)

Эпизод — подряд идущие медленные ответы зонда (probe.tsv), окно — от первой
отправки до последнего ответа. Для каждого эпизода:
  - соединения зонда, которые его видели (у сервера два рабочих потока, и
    соединения разложены по ним: все соединения сразу — пауза процесса или машины);
  - кража гипервизора на ядрах 0–1 (сервер) и 2–3 (wrk2, зонд) и процессор
    потоков сервера за окно (cpu.tsv): время на процессоре и время в очереди;
  - сон потоков сервера в одном вызове дольше 30 мс, пересекающий окно (threads.tsv);
  - сборки Khrip (stderr.log), которые шли в окне: начало — конец строки минус
    длительность разметки «over … ms» и уборки «sweep … ms».
Затем — щели в отправке у потоков wrk2 (gaps.<поток>, bench/mem/gaps.lua) не
короче --min-ms с тем же окружением: видел ли их зонд, кража, сборки.
"""
import os
import re
import sys


def load(path):
    try:
        return [l.rstrip("\n").split("\t") for l in open(path)]
    except OSError:
        return []


def main():
    d = sys.argv[1]
    min_ms = float(sys.argv[sys.argv.index("--min-ms") + 1]) if "--min-ms" in sys.argv else 50.0
    probe = sorted((float(r[0]), int(r[1]), float(r[2])) for r in load(os.path.join(d, "probe.tsv")) if len(r) == 3)
    cpu = []
    for r in load(os.path.join(d, "cpu.tsv")):
        if len(r) < 10:
            continue
        th = {}
        for x in r[9].split(","):
            if x:
                tid, run, wait = x.split(":")
                th[tid] = (float(run), float(wait))
        cpu.append((float(r[0]), [float(x) for x in r[1:5]], [float(x) for x in r[5:9]], th))
    threads = [(r[0], float(r[1]), float(r[2]), r[3], r[4]) for r in load(os.path.join(d, "threads.tsv")) if len(r) == 5]
    gcs = []
    for r in load(os.path.join(d, "stderr.log")):
        if len(r) < 2 or not r[1].startswith("gc "):
            continue
        t = float(r[0])
        line = r[1]
        over = re.search(r"over ([0-9.]+) ms", line)
        sw = re.search(r"sweep ([0-9.]+) ms", line)
        pause = re.search(r"pause ([0-9.]+) ms", line)
        dur = (float(over.group(1)) if over else 0) + (float(sw.group(1)) if sw else 0) + (float(pause.group(1)) if pause else 0)
        gcs.append((t - dur, t, line))
    run = load(os.path.join(d, "run.txt"))
    t0 = t1 = None
    for r in run:
        p = r[0].split()
        if p and p[0] == "run":
            t0, t1 = float(p[1]), float(p[2])
    # эпизоды: медленные ответы, окна которых пересекаются
    eps = []
    for t, c, lat in probe:
        if lat < min_ms:
            continue
        if eps and t <= eps[-1][1] + 5:
            eps[-1][1] = max(eps[-1][1], t + lat)
            eps[-1][2].add(c)
            eps[-1][3] = max(eps[-1][3], lat)
        else:
            eps.append([t, t + lat, {c}, lat])
    print(f"{d}: probe answers {len(probe)} slow (≥ 20 ms), episodes ≥ {min_ms:g} ms: {len(eps)}"
          + (f"; run {t0:.0f}..{t1:.0f}" if t0 else ""))
    gaps = []
    for name in sorted(os.listdir(d)):
        if name.startswith("gaps."):
            for r in load(os.path.join(d, name)):
                if len(r) == 2 and float(r[1]) >= min_ms:
                    gaps.append((float(r[0]), float(r[0]) + float(r[1]), {"wrk2 thread " + name[5:]}, float(r[1]), "gap"))
    items = [(a, b, cs, mx, "probe") for a, b, cs, mx in eps] + gaps
    if t0 is not None and "--all" not in sys.argv:
        # только замер: после него — проверка инвариантов (seed.py verify),
        # а она читает весь store одним запросом
        items = [x for x in items if t0 <= x[0] <= t1]
        gaps = [x for x in gaps if t0 <= x[0] <= t1]
    items.sort()
    print(f"  wrk2 send gaps ≥ {min_ms:g} ms: {len(gaps)}")
    for a, b, cs, mx, kind in items:
        if kind == "gap":
            seen = [p for p in probe if p[0] < b and p[0] + p[2] > a]
            cs = set(cs) | {f"probe max {max(p[2] for p in seen):.0f} ms" if seen else "probe saw nothing"}
        rel = f"{(a - t0) / 1000:+.1f} s" if t0 else ""
        rel = f"[{kind}] " + rel
        bins = [x for x in cpu if a - 50 <= x[0] <= b + 50]
        steal_srv = sum(x[1][0] + x[1][1] for x in bins)
        steal_cli = sum(x[1][2] + x[1][3] for x in bins)
        idle_srv = sum(x[2][0] + x[2][1] for x in bins)
        tsum = {}
        for x in bins:
            for tid, (run_ms, wait_ms) in x[3].items():
                s = tsum.setdefault(tid, [0.0, 0.0])
                s[0] += run_ms
                s[1] += wait_ms
        ths = ", ".join(f"{k} run {v[0]:.0f} wait {v[1]:.0f}" for k, v in sorted(tsum.items()) if v[0] + v[1] > 1)
        blocked = [f"{tid} {s:.0f}+{dur:.0f} ms [{sc}]" for tid, s, dur, sc, _ in threads if s < b and s + dur > a]
        g = [line[:160] for s, e, line in gcs if s < b and e > a]
        print(f"  {rel} window {b - a:.0f} ms, max {mx:.0f} ms, {sorted(map(str, cs))}; steal server cpus {steal_srv:.0f} ms, "
              f"client cpus {steal_cli:.0f} ms, idle server cpus {idle_srv:.0f} ms (over {len(bins)} bins)")
        if ths:
            print(f"    threads: {ths}")
        for x in blocked:
            print(f"    blocked: {x}")
        for x in g:
            print(f"    gc: {x}")


if __name__ == "__main__":
    main()
