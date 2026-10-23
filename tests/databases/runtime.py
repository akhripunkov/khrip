#!/usr/bin/env python3
"""Exercise both drivers in one real HTTP process, including failure cleanup."""
import concurrent.futures
import json
import os
import pathlib
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid


def run(binary, threads):
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    env = dict(os.environ, PORT=str(port), THREADS=str(threads),
               KHRIP_RUNTIME_NAME="kh_runtime_" + uuid.uuid4().hex)
    base = f"http://127.0.0.1:{port}"

    def request(path, method="GET", expected=200):
        req = urllib.request.Request(base + path, method=method,
                                     headers={"Connection": "close"})
        try:
            with urllib.request.urlopen(req, timeout=20) as response:
                status, data = response.status, response.read()
        except urllib.error.HTTPError as response:
            status, data = response.code, response.read()
            response.close()
        assert status == expected, (method, path, status, data[:1000])
        if data.startswith(b"{"):
            return json.loads(data)
        return data

    def work(i):
        result = request(f"/work/{i}", "POST")
        assert result == {"id": i, "value": f"value-{i}-Привет"}, result

    def fault(i):
        mode = i % 2
        request(f"/fault/{mode}", "POST", 409 if mode == 0 else 500)

    with tempfile.TemporaryFile() as logs:
        server = subprocess.Popen([binary], env=env, stdout=logs, stderr=logs)
        initialized = False
        try:
            for _ in range(200):
                if server.poll() is not None:
                    raise AssertionError(f"server exited {server.returncode}")
                try:
                    if request("/ready") == b"ready":
                        break
                except (OSError, urllib.error.URLError):
                    pass
                time.sleep(0.05)
            else:
                raise AssertionError("server readiness timeout")
            request("/init", "POST", 204)
            initialized = True
            assert request("/tls-cleanup", "POST") == {
                "block": True, "input": True, "plain": True, "pending": 0}
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                list(pool.map(work, range(32)))
                assert request("/counts") == {"requests": 32, "mongo": 32, "clickhouse": 32}
                time.sleep(0.1)
                before = len(list(pathlib.Path(f"/proc/{server.pid}/fd").iterdir()))
                list(pool.map(fault, range(160)))
                # Pool exhaustion or a stale arena pointer makes this second
                # wave fail, time out or read another request's result.
                list(pool.map(work, range(32, 64)))
            assert request("/counts") == {"requests": 64, "mongo": 64, "clickhouse": 64}
            for _ in range(12):
                assert request("/resources") == {
                    "mongo_active": 0, "mongo_held": 0,
                    "clickhouse_active": 0, "clickhouse_held": 0,
                    "tls_pending": 0}
            assert request("/tls-cleanup", "POST") == {
                "block": True, "input": True, "plain": True, "pending": 0}
            time.sleep(0.1)
            after = len(list(pathlib.Path(f"/proc/{server.pid}/fd").iterdir()))
            # A small allowance accommodates newly populated per-worker idle
            # pools. A lost socket per fault would add 160 descriptors.
            assert after <= before + 16, ("descriptor leak", before, after)
            request("/cleanup", "DELETE", 204)
            initialized = False
            print(f"shared database runtime: THREADS={threads}, 64 writes/reads, 160 faults, TLS pages unmapped, fd {before}->{after}: passed")
        except Exception:
            logs.seek(0)
            sys.stderr.write(logs.read().decode("utf-8", errors="replace")[-12000:])
            raise
        finally:
            if initialized and server.poll() is None:
                try:
                    request("/cleanup", "DELETE", 204)
                except Exception:
                    pass
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()


if __name__ == "__main__":
    for threads in (1, 2):
        run(sys.argv[1], threads)
