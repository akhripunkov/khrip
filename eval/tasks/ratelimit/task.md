# Rate-limited API

Write an HTTP JSON API server. It listens on port 8080 and keeps data in memory.

Clients send their key in the header `X-API-Key`. Each key may make at most 5
requests to paths under `/api/` per window. A window starts with the key's first
request (or its first request after the previous window ended) and lasts W seconds;
W comes from the environment variable `WINDOW_SECONDS` (60 if it is not set).

- `GET /api/ping`: 200 with `{"pong": true, "remaining": int}` — how many requests
  the key has left in the current window after this one.
- `GET /api/time`: 200 with `{"time": string}` — the current UTC time in ISO 8601,
  like `2026-10-19T15:04:05Z`.
- A request under `/api/` without the header: 401.
- A request over the limit: 429 with the header `Retry-After: <seconds>` — whole
  seconds until the window ends, at least 1. Rejected requests do not count.
- `GET /limits/{key}` needs no key and is not limited: 200 with
  `{"key": string, "used": int, "remaining": int, "reset_in": int}`, where `reset_in`
  is whole seconds until the window ends (0 and `used` 0 when there is no active
  window).

Error responses use the status codes above; the body is a short message in any format.
