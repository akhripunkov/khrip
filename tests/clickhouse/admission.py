#!/usr/bin/env python3
"""Admission is worker-shared; queued coroutines retain their original deadline,
are served first come first served and do not spin while they wait."""
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


def cpu_seconds(pid):
    with open(f"/proc/{pid}/stat") as f:
        fields = f.read().rsplit(")", 1)[1].split()
    return (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")


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
                assert (stats["active"], stats["peak"], stats["requests"]) == (0, 2, 24), stats
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

            # FIFO: with one slot, requests are served in arrival order (the
            # sleep(1) poll let late requests overtake early ones)
            request(mock, "/reset")
            with concurrent.futures.ThreadPoolExecutor(max_workers=20) as pool:
                ordered = []
                for i in range(20):
                    ordered.append(pool.submit(request, base, f"/order/{i}"))
                    time.sleep(0.025)
                assert all(f.result()["ok"] for f in ordered)
            order = request(mock, "/stats")["order"]
            assert order == list(range(20)), order

            # Н12: the queued request sends the rest of its budget, not timeout_ms
            request(mock, "/reset")
            with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                held = [pool.submit(request, base, "/run/hold") for _ in range(2)]
                for _ in range(200):
                    if request(mock, "/stats")["active"] == 2:
                        break
                    time.sleep(0.002)
                echoed = request(base, "/budget?timeout_ms=1000")
                assert all(f.result()["ok"] for f in held)
            budget = float(echoed.split("max_execution_time=")[1].split("&")[0].split()[0])
            assert 0.3 < budget < 0.85, echoed

            # 300 queued coroutines wait without CPU: one slot is busy for the
            # whole window, the rest wait in the FIFO until their deadline
            with concurrent.futures.ThreadPoolExecutor(max_workers=300) as pool:
                waiters = [pool.submit(request, base, "/run/hold?inflight=1&timeout_ms=2500") for _ in range(300)]
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
            # the slot moves on every 0.4 s; the rest time out in the queue or
            # get the slot too late for the 0.4 s reply
            assert sum(r["ok"] for r in results) >= 3, results[:5]
            assert all(r["ok"] or r["error"] for r in results), results
            assert request(base, "/active") == 0 and request(base, "/waiting") == 0
            print(f"ClickHouse admission: peak=2, queued deadline, broken I/O and panic/fail release, FIFO, budget {budget:.3f}s, {spent:.3f}s CPU for 300 waiters: ok")
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
