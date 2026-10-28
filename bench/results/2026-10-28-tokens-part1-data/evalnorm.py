import re, sys
# normalize nondeterministic parts of eval response logs: times, tokens, random codes
def norm(path):
    s = open(path, encoding='utf-8').read()
    s = re.sub(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?(Z|[+-]\d\d:\d\d)', 'TIME', s)
    s = re.sub(r'\b[A-Za-z0-9]{32}\b', 'TOKEN', s)
    codes = []
    for m in re.finditer(r'"code":"([A-Za-z0-9]{7})"', s):
        if m.group(1) not in codes:
            codes.append(m.group(1))
    for i, c in enumerate(codes):
        s = s.replace(c, f'CODE{i}')
    return s
a, b = norm(sys.argv[1]), norm(sys.argv[2])
if a == b:
    print('identical after normalization')
else:
    import difflib
    sys.stdout.writelines(difflib.unified_diff(a.splitlines(True), b.splitlines(True), 'old', 'new'))
