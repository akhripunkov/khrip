#!/usr/bin/env bash
# One checker process keeps requests inside the two-second window even under
# amd64 emulation. Assertions and the server's window are unchanged.
set -euo pipefail
python3 - <<'PY'
import concurrent.futures
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

url = os.environ.get("U", "http://127.0.0.1:8080")
passed = 0
total = 0


def request(path, key=None):
    headers = {} if key is None else {"X-API-Key": key}
    req = urllib.request.Request(url + path, headers=headers)
    try:
        response = urllib.request.urlopen(req, timeout=10)
    except urllib.error.HTTPError as error:
        response = error
    except (OSError, urllib.error.URLError) as error:
        return 0, {}, {}, str(error)
    with response:
        text = response.read().decode("utf-8")
        try:
            body = json.loads(text)
        except ValueError:
            body = {}
        return response.status, body, response.headers, text


def check(name, path, status, predicate=lambda body, headers: True, key=None):
    global passed, total
    total += 1
    actual, body, headers, text = request(path, key)
    try:
        valid = actual == status and predicate(body, headers)
    except (KeyError, TypeError, ValueError):
        valid = False
    if valid:
        passed += 1
    else:
        print(f"FAIL {name}: {actual} {text[:300]}")


def remaining(n):
    return lambda body, headers: body["remaining"] == n


check("no key", "/api/ping", 401)
check("limits idle", "/limits/alpha", 200,
      lambda b, h: b["key"] == "alpha" and b["used"] == 0
      and b["remaining"] == 5 and b["reset_in"] == 0)
check("ping 1", "/api/ping", 200,
      lambda b, h: b["pong"] is True and b["remaining"] == 4, "alpha")
check("ping 2", "/api/ping", 200, remaining(3), "alpha")
check("time", "/api/time", 200,
      lambda b, h: re.fullmatch(r"20[0-9]{2}-[01][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-6][0-9](\.[0-9]+)?(Z|\+00:00)", b["time"]), "alpha")
check("limits", "/limits/alpha", 200,
      lambda b, h: b["key"] == "alpha" and b["used"] == 3
      and b["remaining"] == 2 and b["reset_in"] in (1, 2))
check("ping 4", "/api/ping", 200, remaining(1), "alpha")
check("ping 5", "/api/ping", 200, remaining(0), "alpha")
for name, path in (("ping 6", "/api/ping"), ("time 7", "/api/time")):
    check(name, path, 429, lambda b, h: h.get("Retry-After") in ("1", "2"), "alpha")
check("limits full", "/limits/alpha", 200,
      lambda b, h: b["used"] == 5 and b["remaining"] == 0)
check("other key", "/api/ping", 200, remaining(4), "beta")
check("limits other", "/limits/beta", 200,
      lambda b, h: b["key"] == "beta" and b["used"] == 1)
time.sleep(2.2)
check("new window", "/api/ping", 200, remaining(4), "alpha")
check("limits new window", "/limits/alpha", 200,
      lambda b, h: b["used"] == 1 and b["remaining"] == 4)
with concurrent.futures.ThreadPoolExecutor(max_workers=20) as pool:
    codes = list(pool.map(lambda _: request("/api/ping", "gamma")[0], range(20)))
total += 1
if codes.count(200) == 5 and codes.count(429) == 15:
    passed += 1
else:
    print(f"FAIL concurrent requests: {codes}")
print(f"passed {passed}/{total}")
sys.exit(0 if passed == total else 1)
PY
