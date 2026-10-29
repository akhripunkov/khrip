# Production and other details

`khc -o app app.kh` builds a static Linux x86-64 binary (no libc); `khc check
--json app.kh` reports errors as JSON; `khc check --locks app.kh` shows which
routes only read the store.

## Environment

| Variable | Meaning |
|---|---|
| `PORT` | port, 8080 |
| `THREADS` | worker threads, all cores |
| `KHRIP_DATA=file.json` | the store, loaded at start and saved as JSON within a second of changes and on SIGTERM or SIGINT; a missing or unreadable file keeps the initial values, an unparsable one stops the start |
| `DATABASE_URL` | PostgreSQL; `sslmode` `disable`, `prefer` (default), `require`, `verify-ca`, `verify-full` |
| `DATABASE_POOL` | PostgreSQL connections, 4 per thread, at most 32 |
| `DATABASE_TIMEOUT` | ms per statement or `tx` with retries (10000), then 503 |
| `DATABASE_MIGRATE` | `apply` (default) runs migrations at start; `check` only verifies (`./app migrate` applies and exits) |
| `CLICKHOUSE_TIMEOUT`, `CLICKHOUSE_MAX_RESULT`, `CLICKHOUSE_INFLIGHT` | ms per operation (10000), bytes of one result (64 MiB), operations per thread (32) |
| `SSL_CERT_FILE` | root certificates for https (else the system's) |
| `HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY` | for `fetch` |
| `KHRIP_GC`, `KHRIP_GC_MIN_MB`, `KHRIP_GC_LIMIT_MB` | store collector: headroom % over live data (50), smallest goal (4 MB), soft limit |
| `KHRIP_COROUTINES` | waiting requests per thread (4096), then a queue |

## Running

- Each request has its own memory arena, freed at the end; the store has its own
  heap and an incremental collector.
- Routes that only read the store run in parallel; writers take turns. While a
  request waits (`fetch`, databases, `sleep`, password hashing), its thread runs
  other requests, but a long computation holds its thread.
- A request (head and body) is at most 64 KiB: more gets 413, too large headers
  431, a chunked body 501. `fetch` gives up after 30 s; https is TLS 1.3 only,
  and connections are reused.
- Index out of range, overflow, int division by zero, `pop` or `last` on an
  empty list panic: the request gets 500 and the server goes on; a panic in
  `every` is logged; a program without routes exits with code 101. Float
  division by zero gives Infinity or NaN (`null` in JSON).
- In `khc test`, a failed `expect a == b` shows both sides.

## Programs without routes

`fn main()` (or `fn main() -> int` for the exit code) runs once. `args()` is the
command line, `write(s)` prints without a newline, `read_file(path) -> str?`,
`write_file(path, text, executable) -> bool`, `exit(code)`.

## Details

- List chains run item by item, like LINQ: in `xs.filter(f).map(g).count(h)` each
  item goes through `f`, `g`, `h` before the next, no lists are built in between,
  `any`, `all`, `find` stop at the deciding item, and a panic comes from the first
  item that panics. Lambdas with effects (assignments, printing, store writes,
  `fetch`, databases, `fail`, `return`, or calls doing these) are not chained.
- Bit operators `& | ^ ~ << >>`; `[0] * 100` repeats a list. `matches` runs in
  linear time. `s.byte_len()` counts UTF-8 bytes; `"\u{48}"` is a code point.
  `json_error()` says why the last `from_json` gave none.
