# Khrip language reference (v0.13)

Khrip is a compiled, strictly typed language for HTTP APIs on Linux x86-64.
One project = one namespace: no imports, declaration order does not matter.

This file is the full reference. The Khrip skill
([skill/khrip/SKILL.md](../skill/khrip/SKILL.md) and its chapters) teaches the
same language in compressed form for AI agents: a core of at most 3,000 tokens
and a chapter per task. Everything it says is here or, for the details of the
database drivers, in [DATABASES.md](DATABASES.md).

```
khc run app.kh            # build in memory and run
khc test app.kh           # run test blocks
khc check app.kh [--json] # report all errors with fixes
khc -o app app.kh         # build a static binary
```

## Types

`int` (64-bit, overflow panics), `float` (64-bit), `bool`, `str` (immutable
UTF-8 text), `[T]` list, `map[K, V]` (K is int or str), `T?` optional, an
anonymous struct `{ id: int, name: str }` (usable wherever a type is written)
and named types:

```khrip
type Point { x: int, y: int }
type Named {
    name: str
    ...Point          // spread: copies fields x, y
    tags: [str] = []  // default: a literal, [], {} or an enum value
    note: str?        // optional fields default to none
}
type Role = Admin | Member | Guest                     // enum
type Shape = Circle { r: int } | Rect { w: int, h: int } | Empty
```

`let s: Shape = Circle { r: 2 }`, `let r = Admin`; enum values compare with `==`,
variant fields are read with `match`. No null (use `T?` and `none`), classes,
generics or exceptions. Implicit conversions: `T` → `T?`, variant → its type, int
*literal* → float (`t * 2`); otherwise `n.to_float()`, `x.to_int()`, `x.round()`:
int and float never mix, and `7 / 2` is 3. Keep money in int cents. Conditions
must be `bool`.

Anonymous struct types are structural: the same fields (names, types,
defaults) in the same order are one type. The order is part of the type,
because fields go to JSON and BSON in that order; types that differ only in
order or in a default do not mix, and the error says how they differ. Named
types are nominal (see Values).

## Declarations

```khrip
const LIMIT = 10            // one int, float, str or bool literal
var count: int = 0          // global (not allowed in servers: use store)
fn add(a: int, b: int = 1) -> int {   // defaults are literals
    return a + b
}
fn log(msg: str) {          // no result: omit ->
    print(msg)
}
```

A constant is a single literal (`-2.25` too); `const N = 2 + 3` is an error: for
a computed value write a function. Parameters are read-only. `let` is immutable,
`var` is mutable; local types are inferred: `let total = price * qty`.

## Statements and expressions

```khrip
if x > 0 && !done {
} else if x == 0 {
} else {
}
let size = if n > 100 { "big" } else { "small" }    // if is also a value
let area = match s {                                // exhaustive
    Circle c => 3 * c.r * c.r
    Rect r => r.w * r.h
    Empty => 0
}
while i < n {
    i += 1                  // += -= *= /= %= ; there is no ++
}
for x in xs { }             // items, characters, map keys; for i, x in xs
for k, v in m { }           // keys and values of a map
for i in 0..n { }           // 0..n excludes n, 0..=n includes it
```

`break` and `continue` work in every loop. Operators: `+ - * / %`,
`== != < <= > >=`, `&& || !`, `& | ^ ~ << >>`; `+` also joins strings (`"n=" +
n` with an int is an error: write `"n={n}"`); comparisons do not chain. A block
used as a value ends with its value: `if c { let a = f(); a + 1 } else { 0 }`.
`match` works on variants, int, str and bool (`200 | 201 => ...`), arms may be
blocks or `return ...`, and must cover every case (or have `_ =>`).

Strings: `"Hi, {user.name}!"` interpolates an expression that does not start
with a quote (`{2,5}` stays text); there are no format specs: `{x.round_to(2)}`.
Escapes: `\n \t \r \0 \\ \" \' \{`, and a code point as `\u{e9}`,
`\u00e9` or `\U0001F600`. Raw strings in backticks have neither and may span
lines: `` `\d{4}` ``, `` `{"id": 1}` ``. `len`, `s[i]`, slices, `find`,
`for c in s` and regexes count characters (`s[i]` is a one-character str);
`byte_len()` is the size in UTF-8 bytes. Slices `s[a..b]`, `xs[a..]`, `xs[..b]`
are clamped to the bounds. `'a'` is a one-character str, or its code point where
an int is expected (`let code: int = 'я'` is 1103).

## Optionals

```khrip
let name = find(id) ?? "nobody"        // default
let user = users[id] else {            // unwrap or leave the scope
    return 404
}
if let u = users[id] { }               // u is the value
if role == Admin { }                   // role: Role? compares directly
if limit != none && n > limit { }      // after the check, limit is an int
let ok = tag == none || item.tags.contains(tag)
if q == none {
    return 400
}                                      // from here on q is a str
```

Checks against `none` narrow a `let` or a parameter, not a `var` or a field:
`if let t = body.title { }`. Narrowing and `if let` work in `if` statements, not
in an `if` used as a value: unwrap before it. `m[k]`, `.get(k)`, `.remove(k)`,
`.find(s)`, `.to_int()`, `.to_float()`, `.index_of(x)`, `read_file`, `env`,
`header`, `parse_time`, `parse_date` and `from_json` return `T?`.

## Values

```khrip
let p = Point { x: 1, y: 2 }
let q = Point { x, y }                 // field shorthand: x: x, y: y
let n = Named { name: "a", ...p }      // spread fields of p
let u = Product { ...old, ...patch }   // patch's none fields are skipped
let r: Point = { x, y: 0 }             // no name: the type expected here
let t = { id: 1, tags: ["a"] }         // nothing expected: its fields' type
let zeros = [0] * 100
var m: map[str, int] = {}
let ages = {"ann": 30, (key): 41}      // map keys: "text" or (expression)
```

`{ x: 1 }` takes the type expected by a typed `let`/`var`, assignment, argument,
`return`, list item, field, map value or `??`, else the anonymous type of its
fields (map keys are `"k"` or `(k)`); `{}` is an empty map unless a struct is
expected. `{k: v}`, where `k` is also a local int or str variable, is an error:
give it a type or rename `k` (for a map write `{(k): v}`). At a statement start,
in a match arm, in a condition, a `match` value or a `for` header write
`({ ... })`: `{` there is a block. Types can be inline: `-> { token: str }`; a
named type takes an anonymous value only as `T { ...x }`, so a literal with an
expected type is checked in full (missing, extra and mistyped fields), while a
typo in a literal without one goes unnoticed, as in a map key. A spread of the same type
(`...old`) copies every field; of another type (a patch) it skips `none` fields,
so clearing a field is explicit: `note: patch.note`. Field names may be `type`,
`in`, `match`, `test` or `call` (JSON keys), except `type` in a variant; `type`
and `test` are keywords only where a top-level declaration starts, so a query
parameter or a local may be called `type` too. Structs, lists and maps are
references: assigning shares (a field changed through `let u = users[id] else
{...}` changes the store); `.copy()` copies a list.

## Methods

A function you declare is also a method of its first argument: `p.describe()`.
Built-ins are methods only (`xs.sum()`, `a.max(b)`), except `len(xs)`;
`to_json`, `url_encode` and `print` are functions only. Other methods of the
library are not reachable (`xs.slice(0, 2)` is an error: `xs[0..2]`).

- `str`: `len contains starts_with ends_with find trim lower upper split
  replace repeat to_int to_float`, `find_from(x, i)` (index or -1),
  `matches(regex)` (whole string, by characters; `[a-z] \d \w \s . * + ? {n,m}
  ( | )`, linear time; a literal or `const` pattern is checked when compiling).
  `trim` removes Unicode white space, `lower` and `upper` map letters one to one
  (`"ÉCOLE Ёж".lower()` is `"école ёж"`, `ß` stays), `split("")` gives the
  characters. Bytes: `byte_len`, `byte(i)` (int), `byte_slice(a, b)`,
  `byte_find(x)`, `byte_find_from(x, i)` (index or -1), `ascii_lower`,
  `ascii_upper`, `ascii_trim`. A function you declare cannot take the name of a
  str method if its first parameter is a str.
- `int`: `to_str to_float abs min max`; `bool`: `to_str`
- `float`: `to_str to_int round floor ceil` (→ int) `round_to(digits) abs sqrt
  min max`
- `[T]`: `len push pop last insert remove_at clear truncate copy contains
  index_of`, `sort reverse` (in place, return the list; sort: int or str),
  `join` ([str]: `xs.map(x => x.to_str()).join(", ")` for others), `sum`
  ([int], [float])
- lambdas `x => expr` in list methods: `map filter find` (T?) `any all count
  sort_by` (int, float or str key; stable, in place, returns the list); they see
  local variables: `users.filter(u => u.age >= min).map(u => u.name)`
- `map[K, V]`: `len has get remove keys values clear`, `m[k]` (V?), `m[k] = v`;
  keys and values come in insertion order

Chains run element by element, like LINQ, Rust iterators and Java Streams:
in `m.values().filter(f).map(g).count(h)` each item goes through `f`, `g`
and `h` before the next item, and no lists are built in between; `any`,
`all` and `find` stop at the item that decides the answer, and `sort_by` takes
every item before the methods after it. You only see this when lambdas panic:
the panic comes from the first item (in order) that panics. Lambdas with side
effects (assignments, printing, store writes, `fetch`, databases, `fail`,
`return`, or calling a function that does any of these) are not chained: each
method then runs over the whole list in turn.

Functions: `print(s)`, `eprint(s)`, `write(s)`, `args()`, `env(name) -> str?`,
`read_file(path) -> str?`, `write_file(path, text, executable) -> bool`,
`exit(code)`, `sleep(ms)`, `now()` (unix seconds), `now_ms()`, `time_iso(t)` →
`"2026-10-19T15:04:05Z"`, `parse_time(s) -> int?` (ISO 8601, offsets allowed),
`parse_date("2026-10-19") -> int?`, `random_str(n)` (A-Za-z0-9), `sha256(s)`
(hex), `hash_password(p)`, `check_password(p, hash) -> bool`, `url_encode(s)`,
`to_json(value)`, `from_json(text) -> T?` (the type comes from the annotation:
`let u: User? = from_json(text)`), `json_error()` (why the last `from_json` gave
none).

Index out of range, overflow, int division by zero and `pop` or `last` on an
empty list panic: the program exits with code 101; in a server the request gets
500 and the server goes on; a panic in `every` is logged. Float division by zero
gives Infinity or NaN (`null` in JSON). `fn main() -> int` sets the exit code.

## HTTP API

A program with `route` or `every` declarations runs by itself (no `fn main`);
`PORT` sets the port (8080), `THREADS` the worker threads (all cores, at most
4000).

```khrip
type NewUser { name: str, email: str, age: int }
type User { id: int, ...NewUser }

store users: map[int, User]
store last_id: int

route POST "/users" (body: NewUser) -> 201 User | 400 str {
    if !body.email.matches(`[^@\s]+@[^@\s]+`) {
        return 400 "email is invalid"
    }
    last_id += 1
    let user = User { id: last_id, ...body }
    users[user.id] = user
    return 201 user
}

route GET "/users/{id}" (id: int) -> User | 404 {
    return users[id] ?? 404
}

route GET "/users" (min_age: int?, page: int = 1) -> { items: [User], total: int } {
    let all = users.values()
        .filter(u => min_age == none || u.age >= min_age)
        .sort_by(u => u.name)
    return { items: all[(page - 1) * 20..page * 20], total: all.len() }
}

route DELETE "/users/{id}" (id: int) -> 204 | 404 {
    users.remove(id) else {
        return 404
    }
    return 204
}
```

- Method: `GET POST PUT PATCH DELETE`. Path parameters `{id}` are declared too.
  A struct, list or map parameter is the JSON body; others come from the query
  string: `T?` is optional, `page: int = 1` has a default. Missing body fields
  take their defaults; `none` is `null` both ways; enums are JSON strings
  ("Admin"), other variants objects with a "type" field. Bad input gets 400 with
  a message, a wrong method 405, an unknown path 404. A request (head and body)
  is at most 64 KiB: more gets 413, too large headers 431, a chunked body 501.
- Results: `-> Type` (200), `-> 201 Type | 400 str | 404`; `return 201 user`,
  `return 404`, `return x ?? 404`, `return x ?? 404 "no user"` (with `| 404
  str`). Every status returned is declared, and a status declared without a type
  (`| 409`) has no body: `return 409 "busy"` there is an error. In a route that
  returns `int`, `return 404` and `x ?? 404` (any number from 100 to 599) are
  statuses: write `(404)` for the number. A struct literal without a type name
  takes the type of its status; beside another struct or an error variant a 200
  is `return 200 { ... }`. `x ?? 404` answers 404 only in `return`; elsewhere
  write `x ?? fail(404)` or `let v = x else { return 404 }`. `str` is sent as
  text, other types as JSON. No `->`: 204.
- `header(name) -> str?` reads a request header (any case); `set_header(name,
  value)` adds one to the response. `fail(status)` or `fail(status, message)`
  ends the request from any function: `let key = header("X-API-Key") else {
  fail(401) }`.
- `store name: T` (or `store name: T = value`) outlives requests; handlers see
  it as if requests ran one at a time (no locks needed); routes that only read
  it run in parallel (`khc check --locks app.kh` lists them). Replaced and
  removed values are freed automatically; a value a request still holds stays
  valid.

## Calling other services, background tasks

```khrip
let r = fetch GET "https://api.example.com/v1/items?q={url_encode(q)}"
let items: [Item]? = from_json(r.body)
fetch POST hook Notice { text: "done" } headers {"Authorization": "Bearer {key}"}

every 10 min {
    refresh()
}
```

`fetch METHOD url [body] [headers map]` returns `Response { status, body,
headers }` (names lower case); `status` 0 means unreachable or a TLS error (`body`
says why). A body value is sent as JSON, a str as text. https is built in (TLS
1.3, system root certificates or `SSL_CERT_FILE`); `HTTPS_PROXY`, `HTTP_PROXY`,
`NO_PROXY` are honored; connections are reused; `fetch` gives up after 30 s.
`fetch`, `sql`, the database drivers and `sleep` are plain calls (no
async/await): while a request waits, the server runs other requests, and they
may change store (so may password hashing): read store again after the call.
A long computation, unlike a wait, holds its thread. `every N ms|s|min|h|d` runs
a block in a background thread. `KHRIP_DATA=file.json` keeps store across
restarts: loaded at start and saved as JSON a second after changes and on
SIGTERM or SIGINT; a missing or unreadable file starts from the initial values,
an unparsable one stops the start.

## PostgreSQL

```khrip
migration 1 `
CREATE TABLE accounts (id bigserial PRIMARY KEY, owner text NOT NULL,
    balance bigint NOT NULL DEFAULT 0, created_at timestamptz NOT NULL DEFAULT now());
`
route GET "/accounts/{id}" (id: int) -> Account | 404 {
    return sql "SELECT * FROM accounts WHERE id = {id}"      // no row: 404
}
route POST "/accounts" (body: NewAccount) -> 201 Account {
    return 201 sql "INSERT INTO accounts {body} RETURNING *"  // fields → columns
}
let a: Account? = sql "SELECT * FROM accounts WHERE owner = {name} LIMIT 1"
let all: [Account] = sql `SELECT * FROM accounts
    WHERE ({owner} IS NULL OR owner = {owner}) AND id IN ({ids}) ORDER BY id`
let n: int = sql "SELECT count(*) FROM accounts"
let changed = sql "DELETE FROM accounts WHERE balance = 0"   // rows changed
sql "UPDATE accounts SET {patch} WHERE id = {id}"            // only fields sent
tx {
    let from: Account = sql "SELECT * FROM accounts WHERE id = {a}"
    if from.balance < amount {
        return 409 "insufficient funds"                      // rolls back
    }
    sql "UPDATE accounts SET balance = balance - {amount} WHERE id = {a}"
}
```

- `sql "..."` (or `` `...` `` for several lines) runs one statement; `{expr}` is
  sent as a typed parameter (no `::cast`), never as SQL text (`none` is NULL, so
  compare an optional as `({x} IS NULL OR col = {x})`); `IN ({list})` takes a
  list; `name ILIKE '%{q}%'` matches q literally; `ORDER BY {o}` takes `o` made
  of string literals (`const`, `if`, `match`).
- The expected type picks the result: `T` one row, none → 404 (the route lists
  `| 404`, or answer yourself: `let r: T = sql "..." else { return 401 }`); `T?`
  one row or none, more is a 500 (add `LIMIT 1`); `[T]` all rows; no type:
  rows changed. `T` is a struct (columns by name) or one column's type.
  timestamptz → `str` (as `time_iso`) or `int`; date → `"2026-01-02"` or `int`;
  numeric → `float`, `int` or `str`; json and jsonb → any type; a nullable
  column needs `T?`.
- `INSERT INTO t {v}` puts fields into columns of the same name (`none` → the
  column default), `{rows}` with a list inserts them all in one statement; `SET
  {patch}` sets only the fields the request sent. Duplicate allowed: `let r: T? =
  sql "INSERT ... ON CONFLICT DO NOTHING RETURNING *"` (none: it existed).
- `migration N` runs once, in order, when the server starts (`DATABASE_URL`);
  never edit one that ran: add the next number. The compiler checks every `sql`
  against the migrations; at start the server checks it against the database
  and refuses to run with precise errors.
- A failed statement ends the request: duplicate or CHECK 409, missing foreign
  key 404, row still referenced 409, NOT NULL or a bad value 400, database down
  or busy 503.
- Outside `tx` each statement commits on its own, so in a route a write after
  another statement (or in a loop) is an error: put them in `tx { }`. `tx` is
  SERIALIZABLE and re-runs on a conflict, so inside it no `fetch`, `sleep`,
  MongoDB or ClickHouse network operations, `call`, store or outer-variable
  changes; a status from 400, `fail` or a panic rolls it back. `let t = tx {
  ...; value }` commits and gives the value.

## ClickHouse

Like `sql`: the expected type picks the result, `{x}` is always a parameter,
failures end the request, and the server checks every table and query against
ClickHouse at start. The connection is `CLICKHOUSE_URL=http://user:pass@host:8123/db`
(`CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD` override the URL's).

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
  `let r: DbResult = events.insert(rows)` returns the outcome instead (`r.ok`,
  `r.error`, `r.unknown_outcome`; it must be checked).
- Other servers: `clickhouse metrics = env("METRICS_URL")`; `table hits: Hit in
  metrics`, `migration metrics 1`, `ch metrics "..."`.

The low-level API (`ChConfig`, `ch_query`, `ch_query_params`, `ch_insert`,
`ch_encode`, `ch_decode`) is for system code. Details:
[DATABASES.md](DATABASES.md).

## MongoDB

A library driver (MongoDB 6+, one server or the primary with
`directConnection=true`): calls take an explicit `Mongo { uri, timeout_ms: 10000
}` and return results; they are never retried, stay outside `tx` and wait like
`fetch`.

```khrip
let r = mongo_insert(db, "app", "events", [to_bson(Event { _id: object_id(), user: 1 })])
if r.error != "" {                     // r.code == 11000: duplicate key
    fail(500, r.error)
}
let c = mongo_find_with(db, "app", "events", to_bson({ user: 1 }),
    MongoFindOptions { sort: to_bson({ ts: -1 }), limit: 50 })
```

- `to_bson(v)` takes a struct or `map[str, T]` (a `none` field is not written, so
  `to_bson({ "$set": patch })` sets only the sent fields); `from_bson(doc)`
  gives `T?` by the annotation (why none: `bson_error()`); `object_id()` is a new
  ObjectId in hex.
- Calls start with `(client, db, coll, ...)`: `mongo_insert(..., docs)`,
  `mongo_update(..., filter, update, many = false, upsert = false)`,
  `mongo_delete(..., filter, many = false)` (both refuse a filter that lost a
  `none` field: it would match everything), `mongo_find(..., filter)`,
  `mongo_find_with(..., filter, MongoFindOptions { sort, projection, skip, limit
  })`, `mongo_cursor(..., command)`, `mongo_create_indexes(..., [MongoIndex {
  keys, unique }])`; `mongo_command(client, db, command)`.
- `MongoResult { document, error, code, unknown_outcome }`: always check
  `error`; `unknown_outcome`: the write may have happened. A cursor has
  `documents`, `error`, `id`: read `documents`, then `mongo_next(c)` (false at
  the end or on error); cursors close when the request ends.

Types, URI options, limits and the builder API (`bson_new`, `bson_int`, ...,
`bson_get_int`, ...): [DATABASES.md](DATABASES.md).

## Tests

```khrip
test "create user" {
    let r = call POST "/users" NewUser { name: "Ann", email: "a@x.io", age: 30 }
    expect r.status == 201
    expect (call GET "/users/1" headers {"X-Key": "k"}).body.contains(`"Ann"`)
}
```

`call METHOD "path?query" [body] [headers map]` runs a request in-process and
returns a `Response`; with a literal path, a body literal without a type name
takes the route's body type; a typed body leaves out `none` fields, as a client
that did not send them (`note: none` written there is an error; `null` goes in a
raw body: `` `{"note": null}` ``). `expect cond` records a failure and continues; `a == b`
failures show both sides; `expect r != none` stops the test when `r` is none, and
after it `r` is a value: `let u: User? = from_json(r.body)`, `expect u != none`,
`expect u.name == "Ann"`. Tests run in order and share store and the databases:
PostgreSQL (`KHRIP_TEST_DATABASE_URL`, else `DATABASE_URL`; khc test works in a
temporary schema and drops it) and ClickHouse (`KHRIP_TEST_CLICKHOUSE_URL`, else
`CLICKHOUSE_URL`; a temporary database, dropped at the end).

## Production

`khc -o app app.kh` builds a static Linux x86-64 binary without libc.
`khc check --json` reports errors (and warnings, such as an anonymous type
written three times, with `"severity"`) as JSON; warnings do not stop a build.
`khc check --locks app.kh` shows which routes only read the store.
`khc --version` prints the version.

| Variable | Meaning |
|---|---|
| `PORT` | port, 8080 |
| `THREADS` | worker threads, all cores; at most 4000 |
| `KHRIP_DATA=file.json` | the store, loaded at start and saved as JSON |
| `KHRIP_COROUTINES` | waiting requests per thread (4096), then a queue |
| `KHRIP_GC` | store collector: heap headroom over live data, % (50); `off`: no collection |
| `KHRIP_GC_MIN_MB`, `KHRIP_GC_LIMIT_MB` | smallest collection goal (4 MB); soft limit of the store heap (none) |
| `KHRIP_GC_LOG=1` | one stderr line per collection, if the program was also built with it set |
| `DATABASE_URL` | PostgreSQL; `sslmode` `disable`, `prefer` (default), `require`, `verify-ca`, `verify-full` |
| `DATABASE_POOL` | PostgreSQL connections, 4 per thread, at most 32 |
| `DATABASE_TIMEOUT` | ms per statement or `tx` with retries (10000), then 503 |
| `DATABASE_MIGRATE` | `apply` (default) runs migrations at start; `check` only verifies (`./app migrate` applies and exits) |
| `CLICKHOUSE_URL`, `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD` | ClickHouse |
| `CLICKHOUSE_TIMEOUT`, `CLICKHOUSE_MAX_RESULT`, `CLICKHOUSE_INFLIGHT` | ms per operation (`DATABASE_TIMEOUT`, 10000), bytes of one result (64 MiB), operations per thread (32) |
| `SSL_CERT_FILE` | root certificates for https (else the system's) |
| `HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY` | for `fetch` |

Each request has its own memory arena, freed at the end; the store has its own
heap and an incremental collector, which marks in slices of at most 200 µs that
only writers wait for and returns free pages to the system. While a request
waits (`fetch`, databases, `sleep`, password hashing), its thread runs other
requests. A program without routes runs `fn main()` once.

## Habits from other languages

`null nil None` → `none`; `and or not` → `&& || !`; `elif` → `else if`;
`x++` → `x += 1`; `func def function` → `fn`; `String` → `str`;
`x.length x.size() x.Count` → `x.len()`; `let mut` → `var`;
`switch` → `match`; `enum` → `type Role = A | B`; `cond ? a : b` → `if`;
`x in xs`, `k in m` → `xs.contains(x)`, `m.has(k)`; `d.get(k, v)` → `m[k] ?? v`;
`str(n)`, `int(s)` → `n.to_str()`, `s.to_int()`; `f"{x}"`, `${x}` → `"{x}"`;
`try/catch`, `raise HTTPException` → optionals, `else`, `fail(status)`;
`return 400, "msg"` → `return 400 "msg"`; `lambda x:`, `(x) => {...}` →
`x => expr`; a sort comparator → `sort_by(x => -x.n)`;
`import` → not needed; `$1`, `?` in SQL → `{value}`; `BEGIN`/`COMMIT` → `tx { }`;
catching a duplicate key → `ON CONFLICT DO NOTHING` into `T?`.
