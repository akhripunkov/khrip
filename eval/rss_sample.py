#!/usr/bin/env python3
"""RSS процесса во времени (eval/perf.sh, RATE_MODE=1).

    rss_sample.py <pid>[,<pid>...] <файл> <фаза> [интервал, мс = 100] [abs]
        каждые «интервал» мс дописывает в файл строку «фаза<TAB>мс от начала
        фазы<TAB>VmRSS, КБ» (из /proc/<pid>/status; у нескольких процессов —
        сумма, например node-cluster: главный и рабочие), пока жив первый и пока не
        придёт SIGTERM или SIGINT; с abs вместо мс от начала фазы — мс
        CLOCK_MONOTONIC (их можно сопоставить с другими журналами)

    rss_sample.py --stats <файл> <фаза> [окно, с = 30]
        печатает по строкам фазы: «пик среднее последнее наклон пик_окна
        среднее_окна» — МБ и МБ/с; окно — последние «окно» секунд фазы, наклон —
        прямая по наименьшим квадратам через него
"""
import signal
import sys
import time


def sample(pids, path, phase, interval_ms, absolute=False):
    stop = False

    def on_signal(_sig, _frame):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)
    step = interval_ms / 1000.0
    t0 = time.monotonic()
    k = 0
    with open(path, "a", buffering=1) as out:
        while not stop:
            rss = 0
            for i, pid in enumerate(pids):
                try:
                    with open(f"/proc/{pid}/status") as f:
                        kb = next((int(l.split()[1]) for l in f if l.startswith("VmRSS:")), None)
                except OSError:
                    kb = None
                if kb is None and i == 0:
                    rss = None
                    break
                rss += kb or 0
            if rss is None:
                break
            t = time.monotonic()
            out.write(f"{phase}\t{int((t if absolute else t - t0) * 1000)}\t{rss}\n")
            k += 1
            delay = t0 + k * step - time.monotonic()
            if delay > 0:
                time.sleep(delay)


def stats(path, phase, window_s):
    rows = []
    with open(path) as f:
        for line in f:
            p, t, kb = line.split("\t")
            if p == phase:
                rows.append((int(t) / 1000.0, int(kb) / 1024.0))
    if not rows:
        print("- - - - - -")
        return
    mbs = [r[1] for r in rows]
    end = rows[-1][0]
    tail = [r for r in rows if r[0] >= end - window_s]
    slope = 0.0
    if len(tail) > 2:
        mx = sum(r[0] for r in tail) / len(tail)
        my = sum(r[1] for r in tail) / len(tail)
        den = sum((r[0] - mx) ** 2 for r in tail)
        if den > 0:
            slope = sum((r[0] - mx) * (r[1] - my) for r in tail) / den
    tm = [r[1] for r in tail]
    print(f"{max(mbs):.1f} {sum(mbs) / len(mbs):.1f} {mbs[-1]:.1f} {slope:.4f} {max(tm):.1f} {sum(tm) / len(tm):.1f}")


if __name__ == "__main__":
    a = sys.argv[1:]
    if a and a[0] == "--stats":
        stats(a[1], a[2], float(a[3]) if len(a) > 3 else 30.0)
    else:
        sample([int(p) for p in a[0].split(",")], a[1], a[2], int(a[3]) if len(a) > 3 else 100, len(a) > 4 and a[4] == "abs")
