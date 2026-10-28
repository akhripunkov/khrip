"""Из чего состоят выполненные команды: callgrind (--dump-instr=yes) + objdump.

    python3 insnmix.py <cg-файл> <бинарник с символами> [запросов]

Каждой выполненной команде — вид по её тексту в дизассемблере:
  кадр: пролог и эпилог (push rbp, mov rbp,rsp, sub rsp, сохранение и
        восстановление rbx/r12–r15 в кадре, leave/pop rbp/ret);
  стек операндов: push/pop внутри тела;
  локальные в памяти: mov/арифметика с операндом [rbp-…] (не пролог);
  bool в регистр: setcc, movzbl %al и test, идущие за ними;
  вызовы: call;
  rep (каждый повтор — отдельная команда у callgrind);
  прочее.
Запросов — по умолчанию вызовы __dispatch в файле.
"""
import collections
import re
import subprocess
import sys

cg, binp = sys.argv[1], sys.argv[2]
reqs = int(sys.argv[3]) if len(sys.argv) > 3 else None
cost = collections.Counter()
fn = None
after_calls = False
dispatch = 0
cfn = None
for line in open(cg):
    if line.startswith("fn="):
        fn = line[3:].strip()
        continue
    if line.startswith("cfn="):
        cfn = line[4:].strip()
        continue
    if line.startswith("calls="):
        after_calls = True
        if cfn == "__dispatch":
            dispatch += int(line[6:].split()[0])
        continue
    if not line or line[0] not in "0":
        continue
    p = line.split()
    if len(p) < 3:
        continue
    if after_calls:
        after_calls = False
        continue
    cost[int(p[0], 16)] += int(p[2])
reqs = reqs or dispatch

asm = subprocess.run(["objdump", "-d", "--no-show-raw-insn", binp], capture_output=True, text=True).stdout
insn = {}
func_of = {}
cur = None
for line in asm.splitlines():
    m = re.match(r"^([0-9a-f]+) <(.*)>:", line)
    if m:
        cur = m.group(2)
        continue
    m = re.match(r"^\s+([0-9a-f]+):\s+(.*)$", line)
    if m:
        a = int(m.group(1), 16)
        insn[a] = m.group(2).strip()
        func_of[a] = cur

kinds = collections.Counter()
addrs = sorted(insn)
prev = {}
for i, a in enumerate(addrs):
    prev[a] = insn[addrs[i - 1]] if i else ""
for a, c in cost.items():
    t = insn.get(a)
    if t is None:
        kinds["вне кода программы"] += c
        continue
    op = t.split()[0]
    if op in ("push", "pop") and ("%rbp" in t):
        k = "кадр: пролог и эпилог"
    elif op == "ret" or op == "leave":
        k = "кадр: пролог и эпилог"
    elif re.match(r"mov\s+%rsp,%rbp|sub\s+\$0x[0-9a-f]+,%rsp|mov\s+%rbp,%rsp", t):
        k = "кадр: пролог и эпилог"
    elif re.match(r"mov\s+%(rbx|r12|r13|r14|r15),-0x[0-9a-f]+\(%rbp\)", t) or re.match(r"mov\s+-0x[0-9a-f]+\(%rbp\),%(rbx|r12|r13|r14|r15)$", t):
        k = "кадр: пролог и эпилог"
    elif op in ("push", "pop"):
        k = "стек операндов (push/pop)"
    elif op == "call":
        k = "вызовы (call)"
    elif op.startswith("rep") or "rep " in t:
        k = "rep stos/movs (повторы)"
    elif op.startswith("set") or (op.startswith("movzb") and prev[a].startswith("set")):
        k = "bool в регистр (setcc, movzx)"
    elif "(%rbp)" in t:
        k = "локальные в памяти ([rbp-…])"
    else:
        k = "прочее"
    kinds[k] += c
tot = sum(kinds.values())
print(f"{tot / reqs:,.0f} команд на запрос ({reqs} запросов)")
for k, v in kinds.most_common():
    print(f"{v / reqs:12,.0f}  {100 * v / tot:5.1f}%  {k}")
