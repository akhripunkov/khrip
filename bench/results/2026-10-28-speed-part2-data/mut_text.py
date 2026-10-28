import sys, shutil, os, subprocess
root, tmp = sys.argv[1], sys.argv[2]
muts = {
 "words": ("    while i < n - 8 {\n        let x = load64(p + i)\n        hi = hi | x\n", "    while i < n - 16 {\n        let x = load64(p + i)\n        hi = hi | x\n"),
 "tailhi": ("    let t = load64(p + n - 8)\n    hi = hi | t\n", "    let t = load64(p + n - 8)\n"),
 "short": ("        store64(h + 8, w ^ ((b >> 2) & flip))\n", "        store64(h + 8, w ^ (b >> 2))\n"),
 "mask": ("        if last - i < 7 {\n", "        if last - i < 6 {\n"),
 "cmhi": ("            hi = hi | load64(p + n - 8)\n", "            hi = hi | load64(p)\n"),
 "shift": ("            x = load64(p + n - 8) >> ((i + 8 - n) * 8)\n", "            x = load64(p + n - 8) >> ((i + 7 - n) * 8)\n"),
 "eqtail": ("        if c >= 'A' && c <= 'Z' {\n            c += 32\n        }\n        if c != load8(b + j) {", "        if c != load8(b + j) {"),
 "mgtn": ("    if m > n {\n        return false\n    }\n    let q = __str_ptr(sub)", "    let q = __str_ptr(sub)"),
}
ok = True
for name, (old, new) in muts.items():
    d = os.path.join(tmp, "mlib")
    shutil.rmtree(d, ignore_errors=True)
    shutil.copytree(os.path.join(root, "lib"), d)
    f = os.path.join(d, "text.kh")
    s = open(f).read()
    if s.count(old) != 1:
        print(name, "NOT FOUND", s.count(old)); ok = False; continue
    open(f, "w").write(s.replace(old, new))
    env = dict(os.environ, KHRIP_LIB=d)
    r = subprocess.run([os.path.join(root, "build/khc"), "-o", os.path.join(tmp, "mprog"), os.path.join(root, "tests/run/text_lower_fast.kh")], env=env, capture_output=True, text=True)
    if r.returncode != 0:
        print(name, "compile failed", r.stdout[-300:]); ok = False; continue
    p = subprocess.run([os.path.join(tmp, "mprog")], capture_output=True, text=True, timeout=120)
    want = open(os.path.join(root, "tests/run/text_lower_fast.out")).read() if os.path.exists(os.path.join(root, "tests/run/text_lower_fast.out")) else None
    caught = p.returncode != 0 or (want is not None and p.stdout != want)
    print(name, "caught" if caught else "NOT CAUGHT", p.stdout.strip().splitlines()[-1] if p.stdout.strip() else p.stderr[-200:])
