#!/usr/bin/env python3
"""Admission is worker-shared; queued coroutines retain their original deadline."""
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
    req = urllib.request.Request(base + path, method=method,
                                 headers={"Connection": "close"})
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            status, body = response.status, response.read()
    except urllib.error.HTTPError as response:
        status, body = response.code, response.read()
        response.close()
    assert status == expected, (path, status, body)
    try:
        return json.loads(body)
    except json.JSONDecodeError:
        return body.decode()


def main(binary, mock):
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    base = f"http://127.0.0.1:{port}"
    env = dict(os.environ, PORT=str(port), THREADS="1", CH_MOCK_URL=mock)
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
                raise AssertionError("admission test server not ready")
            request(mock, "/reset")
            with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
                results = list(pool.map(lambda _: request(base, "/run/admission"), range(24)))
                assert all(r["ok"] for r in results), results
                stats = request(mock, "/stats")
                assert stats == {"active": 0, "peak": 2, "requests": 24}, stats
                assert request(base, "/active") == 0

                request(mock, "/reset")
                held = [pool.submit(request, base, "/run/hold") for _ in range(2)]
                for _ in range(200):
                    if request(mock, "/stats")["active"] == 2:
                        break
                    time.sleep(0.002)
                else:
                    raise AssertionError("two leases were not acquired")
                queued = request(base, "/run/admission?timeout_ms=30")
                assert not queued["ok"] and not queued["unknown"] and "admission" in queued["error"], queued
                assert all(f.result()["ok"] for f in held)
                assert request(mock, "/stats")["requests"] == 2, "timed-out queue entry was sent"
                assert request(base, "/active") == 0

                results = list(pool.map(lambda _: request(base, "/run/admission-truncated"), range(12)))
                assert all(not r["ok"] and r["unknown"] for r in results), results
                assert request(mock, "/stats")["peak"] <= 2
                assert request(base, "/active") == 0
                list(pool.map(lambda i: request(base, f"/fault/{i % 2}", "POST", 409 if i % 2 == 0 else 500), range(24)))
                assert request(base, "/active") == 0
                assert request(base, "/run/admission")["ok"]
                assert request(base, "/active") == 0
            print("ClickHouse admission: peak=2, queued deadline, broken I/O and panic/fail release: ok")
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
    main(sys.argv[1], sys.argv[2])
