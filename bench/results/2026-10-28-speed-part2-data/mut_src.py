# mut_src.py <root> <tmp> <mutations.py> — мутации исходников компилятора:
# для каждой: копия src/ с заменой, khc из неё, тесты (run|test|locks) должны упасть
import sys, os, shutil, subprocess, importlib.util
root, tmp, mfile = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("m", mfile)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
env = dict(os.environ, KHRIP_LIB=os.path.join(root, "lib"))
allok = True
for name, f, old, new, tests in m.MUTS:
    d = os.path.join(tmp, "msrc")
    shutil.rmtree(d, ignore_errors=True)
    shutil.copytree(os.path.join(root, "src"), d)
    p = os.path.join(d, f)
    s = open(p).read()
    if s.count(old) != 1:
        print(f"{name}: NOT FOUND ({s.count(old)})"); allok = False; continue
    open(p, "w").write(s.replace(old, new))
    khc = os.path.join(tmp, "mkhc")
    srcs = sorted(os.path.join(d, x) for x in os.listdir(d) if x.endswith(".kh"))
    r = subprocess.run([os.path.join(root, "build/khc"), "--system", "-o", khc] + srcs, env=env, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"{name}: compiler build failed: {r.stdout[-400:]}"); allok = False; continue
    caught = []
    for kind, t in tests:
        tp = os.path.join(root, t)
        try:
            if kind == "run":
                q = subprocess.run([khc, "run", tp], env=env, capture_output=True, text=True, timeout=120)
                want = open(tp[:-3] + ".out").read()
                bad = q.stdout != want
            elif kind == "test":
                q = subprocess.run([khc, "test", tp], env=env, capture_output=True, text=True, timeout=300)
                want = open(tp[:-3] + ".out").read()
                bad = q.stdout + q.stderr != want and q.stdout != want
            elif kind == "locks":
                q = subprocess.run([khc, "check", "--locks", tp], env=env, capture_output=True, text=True, timeout=120)
                want = open(tp[:-3] + ".out").read()
                bad = q.stdout != want
        except subprocess.TimeoutExpired:
            bad = True
        caught.append(bad)
    ok = any(caught)
    allok = allok and ok
    print(f"{name}: {'caught' if ok else 'NOT CAUGHT'} {caught}")
print("all caught" if allok else "SOME NOT CAUGHT")
