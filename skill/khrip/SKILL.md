---
name: khrip
description: Khrip, a compiled language for HTTP JSON backends (.kh files, khc). Use it for any Khrip code.
---

# Khrip (short form of `docs/KHRIP.md`)

A compiled, strictly typed language for HTTP APIs. One namespace: no imports,
declarations in any order. `khc run|test|check app.kh` runs it, runs its
tests, lists all errors with fixes.

Chapters (read one when needed):
- `postgresql.md`: PostgreSQL (`sql "..."`, `tx`, migrations).
- `mongodb.md`: MongoDB.
- `clickhouse.md`: ClickHouse (`ch "..."`, `table`).
- `production.md`: environment, `KHRIP_DATA`, threads, memory, limits, CLI.

## Types and declarations

`int` (64-bit, overflow panics), `float`, `bool`, `str` (UTF-8), `[T]`,
`map[K, V]` (K is int or str), `T?`, `{ id: int, name: str }`
(anonymous struct) and named types. In a type, `...Point` copies its fields,
`tags: [str] = []` has a default (a literal, `[]`, `{}` or an enum value), and
`note: str?` defaults to none.

```khrip top
type Point { x: int, y: int }
type Role = Admin | Member | Guest                     // enum
type Shape = Circle { r: int } | Rect { w: int, h: int } | Empty

const LIMIT = 10                       // int, float, str or bool literal
fn add(a: int, b: int = 1) -> int {    // defaults are literals; no result: no ->
    return a + b
}
```

`let s: Shape = Circle { r: 2 }`, `let r = Admin`; enum values compare with `==`,
variant fields are read with `match`. No null (`T?`, `none`), classes,
generics or exceptions. Implicit conversions: `T` → `T?`, variant → its type, int
*literal* → float (`t * 2`); otherwise `n.to_float()`, `x.to_int()`, `x.round()`:
int and float never mix, `7 / 2` is 3. `let` is immutable, `var` mutable. A
global `var` is not allowed in servers: use `store`.

## Statements

`if`/`else if`/`else` and `match` are values too: `let v = if c { let a = f();
a + 1 } else { 0 }` (a block ends with its value).
`while c { }`, `i += 1` (`-= *= /= %=`, no `++`), `break`, `continue`; `for x in
xs` (items, characters), `for i, x in xs`, `for k, v in m`, `for i in 0..n`
(`0..=n` includes n).

```khrip body
let area = match s {        // every case, or _ =>
    Circle c => 3 * c.r * c.r
    Rect r => r.w * r.h
    Empty => 0
}
```

`match` also takes int, str and bool; arms may be `200 | 201 => ...`, blocks or
`return ...`. `+` also joins strings.

`"Hi, {user.name}!"` interpolates an expression that does not start with a quote
(`{2,5}` stays text). Escapes: `\n \" \{` and more. Raw strings in
backticks have neither and may span lines; JSON and regexes go there:
`` `{"id": 1}` ``, `` `\d{4}` ``. `len`, `s[i]` (a str), slices and `find` count
characters. Slices `s[a..b]`, `xs[a..]`, `xs[..b]` are clamped to the bounds.

## Optionals

```khrip body
let name = find(id) ?? "nobody"
let user = users[id] else {            // unwrap or leave the scope
    return 404
}
if limit != none && n > limit { }      // after the check, limit is an int
if q == none {
    return 400
}                                      // from here on q is a str
```

Checks against `none` narrow a `let` or a parameter, not a `var` or a field:
`if let t = body.title { }`. Narrowing and `if let` work in `if` statements, not
in an `if` used as a value: unwrap before it. `m[k]`, `.get(k)`, `.remove(k)`,
`.find(s)`, `.to_int()`, `.to_float()`, `.index_of(x)`, `env`, `header`,
`parse_time`, `parse_date` and `from_json` return `T?`.

## Values

```khrip body
let p = Point { x: 1, y: 2 }
let q = Point { x, y }                 // x: x, y: y
let u = Product { ...old, ...patch }   // patch's none fields are skipped
let r: Point = { x, y: 0 }             // the type expected here
let t = { id: 1, tags: ["a"] }         // else its fields' type
var m: map[str, int] = {}
let ages = {"ann": 30, (key): 41}      // map keys: "text" or (expression)
```

`...old` of the same type copies all fields; clear one explicitly: `note:
patch.note`. A type is expected by a typed `let`, assignment, argument,
`return`, list item or field. `{k: v}` with an int or str variable `k` that `v`
does not use is an error: add a type or rename `k`. At a statement start and in
a `match` arm `{` opens a block: write `({ ... })`. A named type takes an
anonymous value only as `T { ...x }`. Structs, lists and maps are references:
assigning shares (a field changed through `let u = users[id] else {...}`
changes the store); `.copy()` copies a list.

## Methods and functions

Built-ins are methods (`xs.sum()`, `a.max(b)`; `len(xs)` too); a function
(yours or a call below) is also a method of its first argument (not of a map or
`T?`; a built-in method name of that type is an error: `fn max(a: int, b: int)`);
`to_json` and `from_json` are functions only.

- `str`: `len contains starts_with ends_with find trim lower upper split replace
  repeat to_int to_float`, `matches(regex)` (whole string; `[a-z] \d \w \s . * +
  ? {n,m} ( | )`)
- `int`: `to_str to_float abs min max`; `bool`: `to_str`; `float`: `to_str to_int
  round floor ceil` (→ int) `round_to(digits) abs sqrt min max`
- `[T]`: `len push pop last insert remove_at clear truncate copy`, `contains
  index_of` (int, str, bool; else `xs.any(x => x == v)`), `sort reverse`
  (in place, return the list; sort: int or str), `join` ([str]), `sum` ([int],
  [float])
- lambdas `x => expr` in list methods: `map filter find` (T?) `any all count
  sort_by` (int, float or str key; stable, in place); they see locals
- `map[K, V]`: `len has get remove keys values clear`, `m[k]` (V?), `m[k] = v`;
  insertion order

`print(s)`, `eprint(s)`, `env(name)`, `sleep(ms)`, `now()` (Unix seconds),
`now_ms()`, `time_iso(t)`, `parse_time(s)`, `parse_date(s)` (ISO 8601),
`random_str(n)`, `sha256(s)`, `hash_password(p)`, `check_password(p,
hash)`, `url_encode(s)`, `to_json(x)`, `from_json(text)` (type from the
annotation: `let u: User? = from_json(t)`).

## HTTP API

A program with `route` or `every` runs by itself (no `fn main`) on `PORT` (8080).

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

route GET "/users" (min_age: int?, page: int = 1) -> { items: [User], total: int } {
    let all = users.values()
        .filter(u => min_age == none || u.age >= min_age)
    return { items: all[(page - 1) * 20..page * 20], total: all.len() }
}

route DELETE "/users/{id}" (id: int) -> 204 | 404 {
    users.remove(id) else {
        return 404
    }
    return 204
}

test "create and delete" {
    let r = call POST "/users" { name: "Ann", email: "a@x.io", age: 30 }
    expect r.status == 201
    expect (call DELETE "/users/1").status == 204
}
```

- Path parameters `{id}` are declared too. A struct, list or map parameter is
  the JSON body; others come from the query. Missing body fields take their
  defaults; enums are JSON strings ("Admin"), other variants objects with a
  "type" field; `none` is `null` both ways (not in a typed `call` body). Bad
  input gets 400 with a message.
- `-> Type` is 200, no `->` is 204; every status returned is listed: `return
  users[id] ?? 404` (`?? 404 "no user"` with `| 404 str`; a bare `| 409` has no
  body). Beside a struct or error variant, a literal 200 is `return 200 { ... }`.
  `str` is sent as text, other types as JSON.
- `header(name)` reads a request header, `set_header(name, value)` adds a
  response header; `fail(status[, message])` ends the request from anywhere.
- `store name: T` (or `= value`) outlives requests; they see it as if run
  one at a time.
- Tests run in order and share the store. `call METHOD "path?query" [body]
  [headers map]` returns `Response { status, body, headers }`; a typed body
  leaves `none` fields unsent (`f: none` is an error; for `null` send a raw
  string). `expect` records a failure and goes on, `expect x != none` stops on
  none and narrows `x`.

## Other services, background tasks

```khrip top
every 10 min {
    let r = fetch GET "https://api.example.com/items?q={url_encode(q)}"
    let items: [Item]? = from_json(r.body)
    fetch POST hook { text: "done" } headers {"Authorization": "Bearer {key}"}
}
```

`fetch METHOD url [body] [headers map]` returns a `Response` (header names lower
case); `status` 0 means unreachable or a TLS error. A body value is sent as
JSON, a str as text. `fetch`, `sql`, `sleep` and `hash_password` wait without
async/await; other requests may change the store meanwhile: read it again.
`every N ms|s|min|h|d` runs in a background thread.

## Traps from other languages

- `null nil None` → `none`; `c ? a : b` → `if`; `switch` → `match`;
  `enum E { A, B }` → `type E = A | B`; `if xs` → `if xs.len() > 0`
  (conditions are `bool`); `x in xs`, `k in m` → `xs.contains(x)`, `m.has(k)`;
  `d.get(k, v)` → `m[k] ?? v`.
- `str(n)`, `int(s)` → `n.to_str()`, `s.to_int()` (`int?`); `f"{x}"`, `${x}` →
  `"{x}"`; `{x:.2f}` → `{x.round_to(2)}`; `"n=" + n` is an error.
- `try/catch`, `throw`, `raise HTTPException` → optionals, `else`, `fail`.
- `lambda x:`, `(x) => {...}` → `x => expr`; sorting with a comparator →
  `sort_by(x => -x.n)` (descending), stable `sort_by` calls for several keys
  (last key first).
