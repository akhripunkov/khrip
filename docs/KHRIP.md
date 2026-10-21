# Khrip language reference (v0.11)

Khrip is a compiled, strictly typed language for HTTP APIs on Linux x86-64.
One project = one namespace: no imports, declaration order does not matter.

```
khc run app.kh            # build in memory and run
khc test app.kh           # run test blocks
khc check app.kh [--json] # report all errors with fixes
khc -o app app.kh         # build a static binary
```

## Types

`int` (64-bit, overflow panics), `float` (64-bit), `bool`, `str` (immutable
bytes), `[T]` list, `map[K, V]` (K is int or str), `T?` optional, and named types:

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
*literal* → float (`t * 2`); otherwise `n.to_float()`, `x.to_int()`, `x.round()`.
Keep money in int cents. Conditions must be `bool`.

## Declarations

```khrip
const LIMIT = 10            // int, str or bool literal
var count: int = 0          // global (not allowed in servers: use store)
fn add(a: int, b: int = 1) -> int {   // defaults are literals
    return a + b
}
fn log(msg: str) {          // no result: omit ->
    print(msg)
}
```

Parameters are read-only. `let` is immutable, `var` is mutable; local types
are inferred: `let total = price * qty`.

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
for x in xs { }             // items, str bytes, map keys; for i, x in xs
for i in 0..n { }           // 0..n excludes n, 0..=n includes it
```

Operators: `+ - * / %`, `== != < <= > >=`, `&& || !`, `& | ^ ~ << >>`; `+`
also joins strings; comparisons do not chain. `'a'` is an int (byte). A block
used as a value ends with its value: `if c { let a = f(); a + 1 } else { 0 }`.
`match` works on variants, int, str and bool (`200 | 201 => ...`), arms may be
blocks or `return ...`, and must cover every case (or have `_ =>`).

Strings: `"Hi, {user.name}!"` interpolates an expression that does not start
with a quote (`{2,5}` stays text). Escapes: `\n \t \r \0 \\ \" \' \{`. Raw
strings in backticks have neither and may span lines: `` `\d{4}` ``,
`` `{"id": 1}` ``. `s[i]` is a byte (int); slices `s[a..b]`, `xs[a..]`, `xs[..b]`
are clamped to the bounds.

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

Checks against `none` narrow a `let` or a parameter (not a `var`). `m[k]`,
`.get(k)`, `.remove(k)`, `.find(s)`, `.to_int()`, `.index_of(x)`, `read_file`,
`env`, `parse_time` and `from_json` return `T?`.

## Values

```khrip
let p = Point { x: 1, y: 2 }
let q = Point { x, y }                 // field shorthand: x: x, y: y
let n = Named { name: "a", ...p }      // spread fields of p
let u = Product { ...old, ...patch }   // patch's T? fields: only if not none
let zeros = [0] * 100
var m: map[str, int] = {}
let ages = {"ann": 30, "bob": 41}
```

Structs, lists and maps are references: assigning shares, `.copy()` copies a list.

## Methods

Any function is also a method of its first argument: `p.describe()`.

- `str`: `len contains starts_with ends_with find trim lower upper split
  replace repeat to_int`, `matches(regex)` (whole string; `[a-z] \d \w \s . * + ?
  {n,m} ( | )`, linear time)
- `int`: `to_str to_float abs min max`; `bool`: `to_str`
- `float`: `to_str to_int round floor ceil` (→ int) `round_to(digits) abs sqrt
  min max`; `s.to_float()` → `float?`
- `[T]`: `len push pop last insert remove_at clear truncate copy contains
  index_of`, `sort reverse` (in place, return the list; sort: int or str),
  `join` ([str]), `sum` ([int], [float])
- lambdas `x => expr` in list methods: `map filter find` (T?) `any all count
  sort_by` (int, float or str key; stable, in place, returns the list); they see
  local variables: `users.filter(u => u.age >= min).map(u => u.name)`
- `map[K, V]`: `len has get remove keys values clear`, `m[k]` (V?), `m[k] = v`;
  keys and values come in insertion order

Functions: `print(s)`, `eprint(s)`, `write(s)`, `args()`, `env(name) -> str?`,
`read_file(path) -> str?`, `write_file(path, text, executable) -> bool`,
`exit(code)`, `sleep(ms)`, `now()` (unix seconds), `now_ms()`, `time_iso(t)` →
`"2026-10-19T15:04:05Z"`, `parse_time(s) -> int?` (ISO 8601, offsets allowed),
`parse_date("2026-10-19") -> int?`, `random_str(n)` (A-Za-z0-9), `sha256(s)`
(hex), `hash_password(p)`, `check_password(p, hash) -> bool`, `url_encode(s)`,
`to_json(value)`, `from_json(text) -> T?` (the type comes from the annotation:
`let u: User? = from_json(text)`), `json_error()`.

Index out of range, overflow, division by zero and `pop` on an empty list
panic: the program exits with code 101; in a server the request gets 500.

## HTTP API

A program with `route` or `every` declarations runs by itself (no `fn main`);
`PORT` sets the port (8080), `THREADS` the worker threads (all cores).

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

route GET "/users" (min_age: int?, page: int = 1) -> [User] {
    let all = users.values()
        .filter(u => min_age == none || u.age >= min_age)
        .sort_by(u => u.name)
    return all[(page - 1) * 20..page * 20]
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
  string: `T?` is optional, `page: int = 1` has a default. Missing body fields take their defaults; enums are
  JSON strings ("Admin"), other variants objects with a "type" field. Bad input
  gets 400 with a message, a wrong method 405, an unknown path 404.
- Results: `-> Type` (200), `-> 201 Type | 400 str | 404`; `return 201 user`,
  `return 404`, `return x ?? 404`. `str` is sent as text, other types as JSON. No
  `->`: 204.
- `header(name) -> str?` reads a request header (any case); `set_header(name,
  value)` adds one to the response. `fail(status)` or `fail(status, message)`
  ends the request from any function: `let key = header("X-API-Key") else {
  fail(401) }`.
- `store name: T` outlives requests; handlers see it as if requests ran one at a
  time (no locks needed); routes that only read it run in parallel.

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
`NO_PROXY` are honored; connections are reused. `fetch` and
`sleep` are plain calls (no async/await): while a request waits, the server runs
other requests, and they may change store (so may password hashing). `every N
ms|s|min|h|d` runs a block in a background thread. `KHRIP_DATA=file.json` keeps
store across restarts.

## Tests

```khrip
test "create user" {
    let r = call POST "/users" NewUser { name: "Ann", email: "a@x.io", age: 30 }
    expect r.status == 201
    expect (call GET "/users/1" headers {"X-Key": "k"}).body.contains(`"Ann"`)
}
```

`call METHOD "path?query" [body] [headers map]` runs a request in-process and
returns a `Response`. `expect cond` records a failure and continues; `a == b`
failures show both sides; `expect r != none` stops the test when `r` is none, and
after it `r` is a value: `let u: User? = from_json(r.body)`, `expect u != none`,
`expect u.name == "Ann"`. Tests run in order and share store.

## Habits from other languages

`null nil None` → `none`; `and or not` → `&& || !`; `elif` → `else if`;
`x++` → `x += 1`; `func def function` → `fn`; `String` → `str`;
`x.length x.size() x.Count` → `x.len()`; `let mut` → `var`;
`switch` → `match`; `enum` → `type Role = A | B`; `cond ? a : b` → `if`;
`try/catch`, `raise HTTPException` → optionals, `else`, `fail(status)`;
`import` → not needed.
