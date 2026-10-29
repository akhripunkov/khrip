# ClickHouse

Like `sql`: the expected type picks the result, `{x}` is always a parameter,
failures end the request, and the server checks every table and query against
ClickHouse at start. The connection is `CLICKHOUSE_URL=http://user:pass@host:8123/db`
(`CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD` override).

```khrip
migration ch 1 `CREATE TABLE events (ts DateTime, user_id UInt64,
    page LowCardinality(String), ms Float32) ENGINE = MergeTree ORDER BY (page, ts)`

type Event { ts: int, user_id: int, page: str, ms: float }
type PageStat { page: str, views: int, users: int, avg_ms: float }

table events: Event

route POST "/events" (body: [Event]) -> 202 { inserted: int } {
    return 202 { inserted: events.insert(body) }
}

route GET "/stats/pages" (from: int, to: int, page: str?, limit: int = 10) -> [PageStat] {
    return ch `SELECT page, count() AS views, uniq(user_id) AS users, avg(ms) AS avg_ms
        FROM events WHERE ts >= {from} AND ts < {to} AND ({page} IS NULL OR page = {page})
        GROUP BY page ORDER BY views DESC LIMIT {limit}`
}
```

- `migration ch N` runs once, in order, at start. DDL goes only there; it is not
  transactional: one statement each, or `IF NOT EXISTS`.
- `table t: T` binds a row type to a table. `t.insert(rows)` takes `[S]` or `S`
  (`S` has some of T's fields) and returns the rows sent. Rows are encoded to the
  real column types (`int` into `UInt*`, `Date`, `DateTime`; `str` into `Enum`,
  `UUID`, `Decimal`; `T?` into `Nullable`); a value that does not fit is a 400.
  Start refuses a column with neither a field nor a `DEFAULT`.
- Results: `[R]` all rows, `R?` one row or none, `R` one row (none: 404, the
  route lists `| 404`), a scalar for one column. Columns match fields by name.
  `DateTime` and `Date` → `int` (seconds) or `str` (ISO); `Decimal` → `str` or
  `float`; `Nullable(T)` → `T?`; `Array(T)` → `[T]`. Queries run in UTC.
- `{x}`: `int` Int64, `float`, `bool`, `str` and enums String, `[T]` Array (`x IN
  {xs}`). A `T?` only in `({x} IS NULL OR col = {x})` or `coalesce`: elsewhere it
  is a compile error. `'%{q}%'` after `LIKE` matches q literally. `ORDER BY {o}`
  takes a local made of string literals.
- Compile errors, with fixes: `INSERT ... VALUES` (use `t.insert`), `LIMIT`
  without `ORDER BY`, `{x:Int64}`, `ch` inside `tx`, and more. `ALTER TABLE t
  UPDATE/DELETE ...` waits for the change.
- Errors: a bad value 400, no row 404, server down or busy 503 with
  `Retry-After`, a write whose reply was lost 500 "write outcome unknown".
  `let r: DbResult = events.insert(rows)` returns the outcome instead
  (`r.ok`, `r.error`, `r.unknown_outcome`; it must be checked).
- Other servers: `clickhouse metrics = env("METRICS_URL")`; `table hits: Hit in
  metrics`, `migration metrics 1`, `ch metrics "..."`.
- `khc test` creates a temporary database on `KHRIP_TEST_CLICKHOUSE_URL` (else
  `CLICKHOUSE_URL`) and drops it; tests may call `ch` and `t.insert`.
