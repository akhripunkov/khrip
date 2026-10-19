import math
import os
import time
from datetime import datetime, timezone

from fastapi import Depends, FastAPI, Header, HTTPException

app = FastAPI()
LIMIT = 5
WINDOW = int(os.environ.get("WINDOW_SECONDS", "60"))
windows: dict[str, dict] = {}


def active(key: str) -> dict | None:
    w = windows.get(key)
    if w is None or time.monotonic() - w["start"] >= WINDOW:
        return None
    return w


def seconds_left(w: dict) -> int:
    return math.ceil(w["start"] + WINDOW - time.monotonic())


def take(x_api_key: str | None = Header(None)) -> int:
    if not x_api_key:
        raise HTTPException(401, "missing X-API-Key")
    w = active(x_api_key)
    if w is None:
        w = windows[x_api_key] = {"start": time.monotonic(), "used": 0}
    if w["used"] >= LIMIT:
        raise HTTPException(429, "too many requests", headers={"Retry-After": str(seconds_left(w))})
    w["used"] += 1
    return LIMIT - w["used"]


@app.get("/api/ping")
async def ping(remaining: int = Depends(take)):
    return {"pong": True, "remaining": remaining}


@app.get("/api/time")
async def now(_: int = Depends(take)):
    return {"time": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}


@app.get("/limits/{key}")
async def limits(key: str):
    w = active(key)
    used = w["used"] if w else 0
    return {"key": key, "used": used, "remaining": LIMIT - used, "reset_in": seconds_left(w) if w else 0}
