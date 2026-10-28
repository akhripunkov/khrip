#!/usr/bin/env python3
"""Раскладка RSS работающего сервера Khrip по частям (этап памяти, часть 1).

    khrip_rss.py <pid> [--strace <журнал>] [--live-mb <живое store>] [--json <файл>]

Источники (нужен root или тот же пользователь и ptrace):
  - /proc/<pid>/smaps — области по постоянным адресам рантайма (lib/core.kh,
    lib/gc.kh): STORE, метаданные сборщика GCMETA, арены запросов, сегменты
    бинарника, [stack];
  - /proc/<pid>/pagemap — какие страницы в памяти (по аренам и кускам mmap);
  - /proc/<pid>/mem — метаданные кучи store: карта свободных страниц кучки
    (GC_PHEAP), карта страниц (GC_PAGEMAP), записи спанов (GC_SPANS) и биты
    START: сколько байт в занятых слотах, сколько в свободных слотах спанов,
    сколько в свободных страницах, которые сборщик ещё держит;
  - журнал strace (-f -e trace=mmap,munmap,mremap) от запуска сервера: куски
    mmap без постоянного адреса узнаются по размеру и порядку (lib/http.kh,
    lib/core.kh, lib/api.kh): стек запросов потока 8 МБ + 4 КБ, стеки потоков
    (MAP_NORESERVE), куски кучи потока 1 МБ, буферы соединения 64 КБ + 128 КБ,
    таблица соединений 512 КБ, буферы сопрограмм по 4 КБ и т. д.

--live-mb — живые данные store по журналу сборщика (KHRIP_GC_LOG, «live X MB»);
без него живым считается всё в занятых слотах.
Печатает таблицу (МБ); --json — то же в файл.
"""
import array
import json
import os
import re
import sys

STORE = 0x100000000000
STORE_SIZE = 0x4000000000
GCMETA = 0x180000000000
GCMETA_END = GCMETA + 0x304000000
ARENA_REGION = 0x200000000000
ARENA_END = 0x400000000000
ARENA_SIZE = 1 << 30
GC_START = 0x180000000000
GC_PAGEMAP = 0x180200000000
GC_SPANS = 0x180240000000
GC_PHEAP = 0x180300000000
GC_PH_PART = 0x400000
META_PARTS = [("START", GC_START, 0x180080000000), ("MARK", 0x180080000000, 0x180100000000),
              ("PTRB", 0x180100000000, 0x180200000000), ("PAGEMAP", GC_PAGEMAP, GC_SPANS),
              ("SPANS", GC_SPANS, GC_PHEAP), ("page heap", GC_PHEAP, GCMETA_END)]
PAGE = 8192
MB = 1048576.0

CO_STACK = 8388608 + 4096
CHUNK = 1048576


def read_smaps(pid):
    vmas = []
    cur = None
    with open(f"/proc/{pid}/smaps") as f:
        for line in f:
            m = re.match(r"^([0-9a-f]+)-([0-9a-f]+) (\S+) \S+ \S+ \S+\s*(.*)$", line)
            if m:
                cur = {"start": int(m.group(1), 16), "end": int(m.group(2), 16), "perm": m.group(3),
                       "path": m.group(4).strip(), "rss": 0, "anon": 0}
                vmas.append(cur)
                continue
            k, _, v = line.partition(":")
            if cur is not None and k in ("Rss", "Anonymous"):
                cur["rss" if k == "Rss" else "anon"] = int(v.split()[0]) * 1024
    return vmas


def zero_pfn():
    """Номер страничного кадра нулевой страницы: чтение нетронутой анонимной
    памяти (сборщик Khrip читает целые массивы) отображает её, и pagemap
    показывает такую страницу присутствующей, хотя в RSS её нет."""
    import ctypes
    import mmap
    import struct
    m = mmap.mmap(-1, 4096, flags=mmap.MAP_PRIVATE | mmap.MAP_ANONYMOUS)
    addr = ctypes.addressof(ctypes.c_char.from_buffer(m))
    _ = m[0]
    with open("/proc/self/pagemap", "rb") as f:
        f.seek((addr >> 12) * 8)
        e = struct.unpack("Q", f.read(8))[0]
    return e & ((1 << 55) - 1) if e >> 63 else -1


class Proc:
    def __init__(self, pid):
        self.pid = pid
        self.pm = open(f"/proc/{pid}/pagemap", "rb")
        self.mem = open(f"/proc/{pid}/mem", "rb")
        self.zero = zero_pfn()

    def present(self, addr, npages4k):
        """Флаги «страница в памяти» (не нулевая страница) для npages4k
        страниц по 4 КБ с addr."""
        out = array.array("Q")
        step = 1 << 16
        i = 0
        while i < npages4k:
            n = min(step, npages4k - i)
            self.pm.seek(((addr >> 12) + i) * 8)
            out.frombytes(self.pm.read(n * 8))
            i += n
        z = self.zero
        mask = (1 << 55) - 1
        return [1 if (e >> 63) and (e & mask) != z else 0 for e in out]

    def resident(self, addr, size):
        return sum(self.present(addr, (size + 4095) >> 12)) * 4096

    def read(self, addr, n):
        self.mem.seek(addr)
        return self.mem.read(n)


# ---- куски mmap по журналу strace ----

MMAP_RE = re.compile(r"^(\d+)\s+mmap\((NULL|0x[0-9a-f]+|0), (\d+), ([^,]+), ([^,]+), -1, 0\)\s*= (0x[0-9a-f]+)")
MUNMAP_RE = re.compile(r"^(\d+)\s+munmap\((0x[0-9a-f]+), (\d+)\)\s*= 0")
MREMAP_RE = re.compile(r"^(\d+)\s+mremap\((0x[0-9a-f]+), (\d+), (\d+), [^)]*\)\s*= (0x[0-9a-f]+)")


def join_unfinished(lines):
    """strace -f: «<unfinished ...>» и «<... mmap resumed>» — в одну строку."""
    pend = {}
    for line in lines:
        line = line.rstrip("\n")
        m = re.match(r"^(\d+)\s+(.*) <unfinished \.\.\.>$", line)
        if m:
            pend[m.group(1)] = m.group(2)
            continue
        m = re.match(r"^(\d+)\s+<\.\.\. \w+ resumed>(.*)$", line)
        if m and m.group(1) in pend:
            yield f"{m.group(1)} {pend.pop(m.group(1))}{m.group(2)}"
            continue
        yield line


def mmap_ranges(path):
    """Живые куски mmap без постоянного адреса: [(начало, конец, метка)]."""
    events = []
    for line in join_unfinished(open(path)):
        m = MMAP_RE.match(line)
        if m:
            tid, addr, size, prot, flags, res = m.groups()
            events.append(("map", tid, int(res, 16), int(size), flags, addr not in ("NULL", "0")))
            continue
        m = MUNMAP_RE.match(line)
        if m:
            events.append(("unmap", m.group(1), int(m.group(2), 16), int(m.group(3)), "", False))
            continue
        m = MREMAP_RE.match(line)
        if m:
            tid, old, osz, nsz, res = m.groups()
            events.append(("unmap", tid, int(old, 16), int(osz), "", False))
            events.append(("map", tid, int(res, 16), int(nsz), "MREMAP", False))
    live = []  # [начало, конец, метка]
    for i, (kind, tid, addr, size, flags, fixed) in enumerate(events):
        size = (size + 4095) & ~4095
        if kind == "unmap" or fixed:
            nl = []
            for s, e, lab in live:
                if e <= addr or s >= addr + size:
                    nl.append([s, e, lab])
                    continue
                if s < addr:
                    nl.append([s, addr, lab])
                if e > addr + size:
                    nl.append([addr + size, e, lab])
            live = nl
            if kind == "unmap" or fixed:
                continue
        nxt = next((ev for ev in events[i + 1:] if ev[0] == "map" and ev[1] == tid), None)
        if size == CO_STACK:
            lab = "request stack"
        elif "MAP_NORESERVE" in flags:
            lab = "thread stack"
        elif size == CHUNK:
            lab = "thread heap chunk"
        elif size == 65536:
            lab = "conn in" if nxt and (nxt[3] + 4095) & ~4095 == 131072 else "perm chunk"
        elif size == 131072:
            lab = "conn out"
        elif size == 524288:
            lab = "conn table"
        elif size == 4096:
            lab = "4 KB block"
        elif size in (16384, 69632):
            lab = "db block"
        elif size >= 262144:
            lab = "big block"
        else:
            lab = f"other {size}"
        live.append([addr, addr + size, lab])
    return live


CATEGORY = {
    "request stack": "coroutine stacks",
    "thread stack": "coroutine stacks",
    "thread heap chunk": "thread heaps",
    "big block": "thread heaps",
    "conn in": "buffers and pools",
    "conn out": "buffers and pools",
    "conn table": "buffers and pools",
    "4 KB block": "buffers and pools",
    "db block": "buffers and pools",
}


# ---- куча store ----

def store_heap(proc, vmas):
    rw = [v for v in vmas if STORE <= v["start"] < STORE + STORE_SIZE and v["perm"].startswith("rw")]
    if not rw:
        return None
    end = max(v["end"] for v in rw)
    npg = (end - STORE) // PAGE
    nbytes = (npg + 7) // 8
    free = proc.read(GC_PHEAP, nbytes)
    pmap = array.array("I")
    pmap.frombytes(proc.read(GC_PAGEMAP, npg * 4))
    spans = proc.read(GC_SPANS, npg * 64)
    start_bits = proc.read(GC_START, (end - STORE) // 128)
    pres = proc.present(STORE, (end - STORE) >> 12)
    r = {"committed": end - STORE, "resident": 0, "inuse_resident": 0, "free_resident": 0,
         "free_released": 0, "alloc_bytes": 0, "alloc_resident": 0, "free_slot_bytes": 0, "tail_bytes": 0, "reserve_bytes": 0,
         "spans": 0, "noscan_bytes": 0, "by_class": {}}
    pg = 0
    while pg < npg:
        res = (pres[2 * pg] + pres[2 * pg + 1]) * 4096
        r["resident"] += res
        isfree = (free[pg >> 3] >> (pg & 7)) & 1 if (pg >> 3) < len(free) else 1
        if isfree or pmap[pg] == 0:
            if res:
                r["free_resident"] += res
            else:
                r["free_released"] += PAGE
            pg += 1
            continue
        r["inuse_resident"] += res
        if pmap[pg] - 1 != pg:
            pg += 1
            continue
        w = array.array("Q")
        w.frombytes(spans[pg * 64:pg * 64 + 64])
        base, info, es = w[0], w[1], w[2]
        np_ = info & 0xFFFFFFFF
        ne = w[5] >> 32
        if np_ == 0 or es == 0:
            pg += 1
            continue
        n_alloc = 0
        for i in range(ne):
            g = (base + i * es - STORE) >> 4
            n_alloc += (start_bits[g >> 3] >> (g & 7)) & 1
        alloc = n_alloc * es
        # большой объект (массив словаря или списка) — свой спан: в памяти
        # только тронутые страницы его ёмкости; у мелких спанов страницы заняты
        # целиком
        if (info >> 48) & 4:
            sres = sum(pres[2 * pg:2 * (pg + np_)]) * 4096
            alloc_res = min(alloc, sres)
        else:
            alloc_res = alloc
        r["spans"] += 1
        r["alloc_bytes"] += alloc
        r["alloc_resident"] += alloc_res
        r["free_slot_bytes"] += (ne - n_alloc) * es
        if (info >> 48) & 4:
            # большой спан с запасом для роста на месте (этап памяти, часть 3,
            # п. 3): объект — es байт, остальные страницы спана — запас (не
            # тронут, в памяти его нет)
            r["reserve_bytes"] += np_ * PAGE - es
        else:
            r["tail_bytes"] += np_ * PAGE - ne * es
        if (info >> 48) & 2:
            # спаны без ссылок: у большого — только объект (без запаса роста)
            r["noscan_bytes"] += es if (info >> 48) & 4 else np_ * PAGE
        c = r["by_class"].setdefault(es, [0, 0, 0])
        c[0] += 1
        c[1] += alloc
        c[2] += np_ * PAGE
        # остальные страницы спана — по одной в цикле (resident считается там)
        pg += 1
    return r


def arenas(proc, vmas):
    av = [v for v in vmas if ARENA_REGION <= v["start"] < ARENA_END]
    rss = sum(v["rss"] for v in av)
    per = []
    if av:
        top = max(v["end"] for v in av if v["perm"].startswith("rw")) if any(v["perm"].startswith("rw") for v in av) else ARENA_REGION
        n = (top - ARENA_REGION + ARENA_SIZE - 1) // ARENA_SIZE
        for k in range(n):
            base = ARENA_REGION + k * ARENA_SIZE
            if not any(v["start"] <= base < v["end"] and v["perm"].startswith("rw") for v in av):
                continue
            # память арены — подряд от начала (выделение сдвигом, обнуление
            # memset до верхней отметки); конец — первые 4 МБ без страниц
            got = 0
            off = 0
            while off < ARENA_SIZE:
                p = proc.present(base + off, 1024)
                s = sum(p)
                got += s * 4096
                if s == 0:
                    break
                off += 4 << 20
            per.append(got)
    return rss, per


def main():
    a = sys.argv[1:]
    pid = int(a[0])
    st = a[a.index("--strace") + 1] if "--strace" in a else None
    live_mb = float(a[a.index("--live-mb") + 1]) if "--live-mb" in a else None
    out_json = a[a.index("--json") + 1] if "--json" in a else None
    vmas = read_smaps(pid)
    proc = Proc(pid)
    exe = os.readlink(f"/proc/{pid}/exe")
    total = sum(v["rss"] for v in vmas)
    cat = {}

    def add(k, b):
        cat[k] = cat.get(k, 0) + b

    store_rss = sum(v["rss"] for v in vmas if STORE <= v["start"] < STORE + STORE_SIZE)
    meta_rss = sum(v["rss"] for v in vmas if GCMETA <= v["start"] < GCMETA_END)
    # части метаданных (lib/gc.kh): START и MARK — бит на 16 байт STORE, PTRB —
    # бит на слово, PAGEMAP — 4 байта на страницу, SPANS — 64 байта на страницу,
    # кучка страниц — карты и дерево
    meta_parts = {}
    for v in vmas:
        if GCMETA <= v["start"] < GCMETA_END:
            for name, lo, hi in META_PARTS:
                if lo <= v["start"] < hi:
                    meta_parts[name] = meta_parts.get(name, 0) + v["rss"]
    heap = store_heap(proc, vmas)
    if heap:
        # живое — занятые слоты в памяти (или меньше: по журналу сборщика);
        # остальное в занятых спанах — мусор до сборки и свободные слоты;
        # расхождение smaps и pagemap — в «прочее»
        live = heap["alloc_resident"] if live_mb is None else min(live_mb * MB, heap["alloc_resident"])
        add("live store data", live)
        add("store: free slots and garbage in spans", heap["inuse_resident"] - live)
        add("store: free pages kept", heap["free_resident"])
        add("other", store_rss - heap["resident"])
    else:
        add("live store data", store_rss)
    add("GC metadata", meta_rss)
    arena_rss, per_arena = arenas(proc, vmas)
    add("request arenas", arena_rss)
    binary = sum(v["rss"] for v in vmas if v["path"] == exe)
    add("binary", binary)
    stack = sum(v["rss"] for v in vmas if v["path"] == "[stack]")
    add("coroutine stacks", stack)
    other_anon = [v for v in vmas if not (STORE <= v["start"] < STORE + STORE_SIZE or GCMETA <= v["start"] < GCMETA_END
                                          or ARENA_REGION <= v["start"] < ARENA_END) and v["path"] != exe and v["path"] != "[stack]"]
    other_rss = sum(v["rss"] for v in other_anon)
    labels = {}
    if st:
        for s, e, lab in mmap_ranges(st):
            b = proc.resident(s, e - s)
            labels[lab] = labels.get(lab, 0) + b
    known = 0
    for lab, b in labels.items():
        k = CATEGORY.get(lab)
        if k:
            add(k, b)
            known += b
    add("other", other_rss - known)

    order = ["live store data", "store: free slots and garbage in spans", "store: free pages kept", "GC metadata",
             "request arenas", "thread heaps", "coroutine stacks", "buffers and pools", "binary", "other"]
    with open(f"/proc/{pid}/status") as f:
        vmrss = next(int(l.split()[1]) for l in f if l.startswith("VmRSS:")) * 1024
    print(f"VmRSS {vmrss / MB:.1f} MB, smaps {total / MB:.1f} MB")
    for k in order:
        print(f"  {k:42s} {cat.get(k, 0) / MB:8.2f}")
    if meta_parts:
        print("  GC metadata: " + ", ".join(f"{n} {meta_parts.get(n, 0) / MB:.2f}" for n, _, _ in META_PARTS)
              + (f"; spans without references {heap['noscan_bytes'] / MB:.1f} MB" if heap else ""))
    if heap:
        print(f"  store: committed {heap['committed'] / MB:.1f}, resident {heap['resident'] / MB:.1f}, in spans {heap['inuse_resident'] / MB:.1f}"
              f" (allocated slots {heap['alloc_bytes'] / MB:.2f}, resident {heap['alloc_resident'] / MB:.2f}, free slots {heap['free_slot_bytes'] / MB:.2f}, tails {heap['tail_bytes'] / MB:.2f}, growth reserve {heap['reserve_bytes'] / MB:.2f}),"
              f" free kept {heap['free_resident'] / MB:.2f}, released {heap['free_released'] / MB:.1f}, {heap['spans']} spans")
        top = sorted(heap["by_class"].items(), key=lambda kv: -kv[1][2])[:8]
        print("  classes (slot B: spans, allocated MB / span MB): " + ", ".join(f"{es}: {c[0]}, {c[1] / MB:.1f}/{c[2] / MB:.1f}" for es, c in top))
    if per_arena:
        s = sorted(per_arena)
        print(f"  arenas: {len(s)} with memory, KB min {s[0] // 1024}, median {s[len(s) // 2] // 1024}, max {s[-1] // 1024}, sum {sum(s) / MB:.1f} MB")
    if labels:
        print("  mmap pieces: " + ", ".join(f"{k} {v / MB:.2f}" for k, v in sorted(labels.items(), key=lambda kv: -kv[1])))
    if out_json:
        json.dump({"vmrss": vmrss, "smaps": total, "categories": cat, "gc_metadata": meta_parts, "store": heap and {k: v for k, v in heap.items() if k != "by_class"},
                   "store_classes": heap and {str(k): v for k, v in heap["by_class"].items()},
                   "arenas": per_arena, "mmap_labels": labels}, open(out_json, "w"), indent=1)


if __name__ == "__main__":
    main()
