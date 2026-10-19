# Khrip language reference (v0.6)

Khrip is a compiled, strictly typed language for HTTP APIs on Linux x86-64.
One project = one namespace: no imports, declaration order does not matter.

```
khc run app.kh            # build in memory and run
khc test app.kh           # run test blocks
khc check app.kh [--json] # report all errors with fixes
khc -o app app.kh         # build a static binary
```

## Types

`int` (64-bit, overflow panics), `bool`, `str` (immutable bytes), `[T]` list,
`map[K, V]` (K is int or str), `T?` optional, and named types:

```khrip
type Point {
    x: int
    y: int
}
type Named {
    name: str
    ...Point          // spread: copies fields x, y
}
```

No floats (use int cents), no null (use `T?` and `none`), no classes, generics,
closures, exceptions or operator overloading. The only implicit conversion is
`T` → `T?`. Conditions must be `bool`.

## Declarations

```khrip
const LIMIT = 10            // int, str or bool literal
var count: int = 0          // global (not allowed in servers: use store)
fn add(a: int, b: int) -> int {
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
while i < n {
    i += 1                  // += -= *= /= %= ; there is no ++
}
for x in xs { }             // list items, str bytes, map keys
for i, x in xs { }          // index and item; for k, v in m { }
for i in 0..n { }           // 0..n excludes n, 0..=n includes it
break
continue
```

Operators: `+ - * / %` (int; `/` truncates, division by zero panics),
`== != < <= > >=`, `&& || !`, `& | ^ ~ << >>`, `+` also joins strings.
Comparisons do not chain. `'a'` is an int (byte).

Strings: `"Hello, {name}!"` interpolates an expression that starts with a name
(`{user.name}`, `{m["a"]}`, `{xs.len()}`); `\{` is a literal brace. Escapes:
`\n \t \r \0 \\ \" \'`. `s[i]` is a byte (int), `s[a..b]` a substring.

## Optionals

```khrip
let name = find(id) ?? "nobody"        // default
let user = users[id] else {            // unwrap or leave the scope
    return 404
}
if let u = users[id] {
    print(u.name)
}
if user == none { }
```

`m[k]` on a map, `.get(k)`, `.remove(k)`, `.find(s)`, `.to_int()`,
`.index_of(x)`, `read_file`, `env` and `from_json` return `T?`.

## Values

```khrip
let p = Point { x: 1, y: 2 }
let q = Point { x, y }                 // field shorthand: x: x, y: y
let n = Named { name: "a", ...p }      // spread fields of p
var xs: [int] = []
let ys = [1, 2, 3]
let zeros = [0] * 100
var m: map[str, int] = {}
let ages = {"ann": 30, "bob": 41}
```

Structs, lists and maps are references: assigning shares, `.copy()` copies a list.

## Methods

Any function can be called as a method of its first argument: `p.describe()`
is `describe(p)`.

- `str`: `len contains starts_with ends_with find trim lower upper split
  replace repeat to_int`
- `int`: `to_str abs min max`; `bool`: `to_str`
- `[T]`: `len push pop last insert remove_at clear truncate reverse copy
  contains index_of sort` (sort: int or str), `join` ([str]), `sum` ([int]),
  `xs[i]`, `xs[a..b]`
- `map[K, V]`: `len has get remove keys values clear`, `m[k]` (V?), `m[k] = v`

Functions: `print(s)`, `eprint(s)`, `write(s)` (no newline), `len(x)`,
`args() -> [str]`, `env(name) -> str?`, `read_file(path) -> str?`,
`write_file(path, text, executable) -> bool`, `exit(code)`,
`to_json(value) -> str`, `from_json(text) -> T?` (the type comes from the
annotation: `let u: User? = from_json(text)`), `json_error() -> str`.

Index out of range, overflow, division by zero and `pop` on an empty list
panic: the program exits with code 101; in a server the request gets 500.

## HTTP API

A program with `route` declarations is a server (no `fn main`); `PORT` sets
the port (8080), `THREADS` the worker threads (all cores).

```khrip
type NewUser {
    name: str
    email: str
    age: int
}
type User {
    id: int
    ...NewUser
}

store users: map[int, User]
store last_id: int

route POST "/users" (body: NewUser) -> 201 User | 400 str {
    if body.name == "" {
        return 400 "name is required"
    }
    last_id += 1
    let user = User { id: last_id, ...body }
    users[user.id] = user
    return 201 user
}

route GET "/users/{id}" (id: int) -> User | 404 {
    return users[id] ?? 404
}

route GET "/users" (limit: int?) -> [User] {
    return users.values()
}

route DELETE "/users/{id}" (id: int) -> 204 | 404 {
    users.remove(id) else {
        return 404
    }
    return 204
}
```

- Method: `GET POST PUT PATCH DELETE`. Path parameters `{id}` must be declared
  (`int`, `str` or `bool`). A struct, list or map parameter is the JSON body;
  other parameters come from the query string (`T?` makes one optional).
  Bad input gets 400 with a message, a wrong method 405, an unknown path 404.
- Results: `-> Type`, `-> 201 Type | 400 str | 404`; a type without a status
  means 200. `return 201 user`, `return 404`, `return value` (status chosen by
  type), `return x ?? 404`. `str` is sent as text, other types as JSON
  (field names as declared). A route without `->` answers 204.
- `store name: T` is data that outlives requests. Each request runs in its own
  memory arena; writes into store are copied out automatically. Handlers see
  store as if requests ran one at a time.

## Tests

```khrip
test "create user" {
    let r = call POST "/users" NewUser { name: "Ann", email: "a@x.io", age: 30 }
    expect r.status == 201
    let u: User? = from_json(r.body)
    expect (u ?? User { id: 0, name: "", email: "", age: 0 }).name == "Ann"
    expect (call GET "/users/9").status == 404
}
```

`call METHOD "path?query" [body]` runs a request in-process and returns
`Response { status: int, body: str }`; the body is a str or a value sent as
JSON. `expect cond` records a failure and continues; `a == b` failures show
both sides. Tests run in order and share store.

## Habits from other languages

`null nil None` → `none`; `and or not` → `&& || !`; `elif` → `else if`;
`x++` → `x += 1`; `func def function` → `fn`; `String` → `str`;
`x.length x.size() x.Count` → `x.len()`; `let mut` → `var`;
`try/catch` → optionals and `else`; `import` → not needed.
