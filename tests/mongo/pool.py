#!/usr/bin/env python3
"""The MongoDB pool queue: first come first served, no CPU while waiting, slots
come back after fail and panic. No MongoDB server is needed."""
import concurrent.futures
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request


def request(base, path, method="GET", expected=200):
    req = urllib.request.Request(base + path, method=method, headers={"Connection": "close"})
    try:
        with urllib.request.urlopen(req, timeout=20) as response:
            status, body = response.status, response.read()
    except urllib.error.HTTPError as response:
        status, body = response.code, response.read()
        response.close()
    assert status == expected, (path, status, body)
    return json.loads(body) if body[:1] in (b"{", b"[") or body.isdigit() else body.decode()


def cpu_seconds(pid):
    with open(f"/proc/{pid}/stat") as f:
        fields = f.read().rsplit(")", 1)[1].split()
    return (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")


def main(binary):
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    base = f"http://127.0.0.1:{port}"
    env = dict(os.environ, PORT=str(port), THREADS="1")
    with tempfile.TemporaryFile() as log:
        server = subprocess.Popen([binary], env=env, stdout=log, stderr=log)
        try:
            for _ in range(100):
                try:
                    if request(base, "/ready") == "ready":
                        break
                except OSError:
                    pass
                time.sleep(0.02)
            else:
                raise AssertionError("pool test server not ready")
            # FIFO: one slot, 20 requests in a known order get it in that order
            with concurrent.futures.ThreadPoolExecutor(max_workers=20) as pool:
                grants = []
                for _ in range(20):
                    grants.append(pool.submit(request, base, "/hold?hold=80"))
                    time.sleep(0.025)
                times = [f.result() for f in grants]
            assert all(g["ok"] for g in times), times
            assert [g["at"] for g in times] == sorted(g["at"] for g in times), times
            assert request(base, "/held") == 0 and request(base, "/waiting") == 0
            # 300 waiters cost no CPU; the deadline still holds in the queue
            with concurrent.futures.ThreadPoolExecutor(max_workers=300) as pool:
                waiters = [pool.submit(request, base, "/hold?hold=600&timeout_ms=2000") for _ in range(300)]
                for _ in range(500):
                    if request(base, "/waiting") >= 290:
                        break
                    time.sleep(0.01)
                else:
                    raise AssertionError("waiters did not queue")
                before = cpu_seconds(server.pid)
                time.sleep(1.0)
                spent = cpu_seconds(server.pid) - before
                results = [f.result() for f in waiters]
            assert spent < 0.15, f"{spent:.2f}s CPU while 300 requests wait"
            assert sum(r["ok"] for r in results) >= 2, results[:5]
            assert request(base, "/held") == 0 and request(base, "/waiting") == 0
            # fail and panic with a slot: the end of the request returns it
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                list(pool.map(lambda i: request(base, f"/fault/{i % 2}", "POST", 409 if i % 2 == 0 else 500), range(16)))
            assert request(base, "/held") == 0 and request(base, "/waiting") == 0
            assert request(base, "/hold?hold=1")["ok"]
            print(f"MongoDB pool queue: FIFO, {spent:.3f}s CPU for 300 waiters, fail/panic release: ok")
        except Exception:
            log.seek(0)
            sys.stderr.write(log.read().decode(errors="replace")[-10000:])
            raise
        finally:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()


if __name__ == "__main__":
    main(sys.argv[1])
