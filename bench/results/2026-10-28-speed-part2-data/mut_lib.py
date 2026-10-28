import sys, shutil, os, subprocess
root, tmp, test = sys.argv[1], sys.argv[2], sys.argv[3]
muts = [
 ("core.kh", "cmpctz", "            let k = i + (__ctz(d) >> 3)\n            return load8(ap + k) - load8(bp + k)\n", "            let k = i\n            return load8(ap + k) - load8(bp + k)\n"),
 ("core.kh", "cmptail", "            let d = load64(ap + n - 8) ^ load64(bp + n - 8)\n", "            let d = load64(ap + i) ^ load64(bp + i)\n"),
 ("core.kh", "cmptail2", "                let k = n - 8 + (__ctz(d) >> 3)\n", "                let k = n - 8\n"),
 ("core.kh", "memeqtail", "        return i == n || load64(a + n - 8) == load64(b + n - 8)\n", "        return true\n"),
 ("core.kh", "memeq4", "        return load32(a) == load32(b) && load32(a + n - 4) == load32(b + n - 4)\n", "        return load32(a) == load32(b)\n"),
 ("core.kh", "hashlen", "        var h = n\n        var i = 0\n        while i + 8 <= n {", "        var h = 0\n        var i = 0\n        while i + 8 <= n {"),
]
for f, name, old, new in muts:
    d = os.path.join(tmp, "mlib"); shutil.rmtree(d, ignore_errors=True); shutil.copytree(os.path.join(root, "lib"), d)
    p = os.path.join(d, f); s = open(p).read()
    if s.count(old) != 1: print(name, "NOT FOUND"); continue
    open(p, "w").write(s.replace(old, new))
    env = dict(os.environ, KHRIP_LIB=d)
    r = subprocess.run([os.path.join(root, "build/khc"), "-o", os.path.join(tmp, "mprog"), os.path.join(root, test)], env=env, capture_output=True, text=True)
    if r.returncode: print(name, "compile failed"); continue
    q = subprocess.run([os.path.join(tmp, "mprog")], capture_output=True, text=True, timeout=120)
    want = open(os.path.join(root, test[:-3] + ".out")).read()
    print(name, "caught" if (q.returncode != 0 or q.stdout != want) else "NOT CAUGHT", q.stdout.strip().splitlines()[-1:] if q.stdout else q.returncode)
