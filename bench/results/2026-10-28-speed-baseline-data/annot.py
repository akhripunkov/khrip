"""annot.py <cg-файл> <запросов> <бинарник с символами> <функция> — дизассемблер функции с собственными инструкциями на запрос у каждой команды."""
import subprocess
import sys

cg, reqs, binp, fn = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
here = __file__.rsplit("/", 1)[0]
instr = subprocess.run([sys.executable, here + "/cgparse.py", cg, reqs, "instr", fn], capture_output=True, text=True).stdout
cnt = {}
for line in instr.splitlines():
    a, c = line.split()
    cnt[int(a, 16)] = float(c)
nm = subprocess.run(["nm", binp], capture_output=True, text=True).stdout
start = size = None
syms = sorted((int(l.split()[0], 16), l.split()[2]) for l in nm.splitlines())
for i, (a, n) in enumerate(syms):
    if n == fn:
        start = a
        end = syms[i + 1][0] if i + 1 < len(syms) else a + 4096
asm = subprocess.run(["objdump", "-d", "--no-show-raw-insn", binp, f"--start-address={start}", f"--stop-address={end}"],
                     capture_output=True, text=True).stdout
for line in asm.splitlines()[6:]:
    try:
        a = int(line.split(":")[0].strip(), 16)
    except ValueError:
        print(line)
        continue
    print(f"{cnt.get(a, 0):9.1f} {line}")
