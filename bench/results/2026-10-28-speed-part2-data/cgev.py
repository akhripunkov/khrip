"""cgev.py <cg-файл> <запросов> <номер события> — собственные события по функциям на запрос"""
import sys, collections
path, reqs, ev = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
cost = collections.Counter()
fn = None
sub = False
for line in open(path):
    if line.startswith("fn="):
        fn = line[3:].strip(); sub = False; continue
    if line.startswith("cfn=") or line.startswith("cfi=") or line.startswith("cob="):
        continue
    if line.startswith("calls="):
        sub = True; continue
    if line[:1].isdigit() or line[:1] in "+-*":
        parts = line.split()
        if sub:
            sub = False; continue
        if len(parts) > ev + 2 and fn:
            try: cost[fn] += int(parts[ev + 2])
            except ValueError: pass
for k, v in cost.most_common():
    print(f"{v / reqs:10.2f} {k}")
