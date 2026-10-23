# MongoDB and ClickHouse in Khrip: the library-first design

Angle: keep both drivers as typed library functions, with as little new compiler
support as possible. Push that as far as it goes, and say where syntax would
really be needed.

Scratch for this design: `/tmp/claude-0/-home-user-khrip/c69287a0-5c25-565c-bc10-daebb195400d/scratchpad/drvdesign/library-first/`.
Nothing in `/home/user/khrip` was modified.

**What was checked, not only argued:**
- A **compiler and library prototype** of the MongoDB half was built in a temporary
  worktree. It has typed calls, `{...}` documents, `ObjectId`, fail-closed errors and
  `$literal` protection. It took 396 compiler lines and 581 library lines (a new
  551-line file plus 30 changed lines).
  - It compiles the token-counted programs **P1 and P2 exactly as printed in §10**.
  - It ran them against the real MongoDB 8.0 at 127.0.0.1:27019, with the statuses
    shown in §10.3.
  - The worktree is removed. The diff is in `prototype.diff` and the library in
    `prototype_mongo_typed.kh`.
- **ClickHouse behaviour this design relies on** was checked with curl against
  ClickHouse 25.8 at 127.0.0.1:8125:
  - parameter types against real column types;
  - `DESCRIBE (query)` with sample parameter values;
  - `IN`, `LIKE` escaping, NULL parameters;
  - `X-ClickHouse-Summary`;
  - `input_format_null_as_default`.
- **Tokens** were counted with `bench/tokens/count.mjs` (code, comments removed), and
  `spec_tokens.mjs` for the KHRIP.md text. Counts are o200k / Claude.

---

## 0. Summary

| # | Decision |
|---|---|
| L1 | **One compiler mechanism: typed library calls.** About 16 library functions have names the compiler knows. For a call to one of them, the compiler:<br>(a) takes the result shape from the expected type, exactly like `sql` and `from_json`;<br>(b) compiles `{...}` arguments as documents whose values may have different types;<br>(c) compiles the ClickHouse query literal like a `sql` literal, so `{x}` is a typed parameter;<br>(d) requires a literal for collection and table names and for option structs;<br>(e) passes type descriptors to the library.<br>No new keywords and no new statement forms. One reserved function name: `on_start`. Two branded string types: `ObjectId` and `Base64`. |
| L2 | **Results come from the expected type, as with `sql`.**<br>• `T`: one value; none → 404.<br>• `T?`: one or none; more than one is an error.<br>• `[T]`: all.<br>• No type: the count.<br>• `DbResult`: the explicit outcome of a write.<br>Writes into `T` return the stored or changed document (`RETURNING`). |
| L3 | **Fail-closed, with one convention for both drivers and for `sql`:**<br>• duplicate key → 409;<br>• bad value → 400;<br>• server down, busy or timed out → 503 with `Retry-After: 1`;<br>• outcome unknown → 500;<br>• a document that does not match the type → 500, with a precise log line.<br>`let r: DbResult = ...` returns the outcome instead. A `DbResult` that is never checked is a compile error. |
| L4 | **Documents are `{...}` literals, structs or maps.**<br>• Keys are string literals.<br>• Values are encoded by their static type.<br>• `none` leaves the field out, so the PATCH idiom works: `{"$set": patch}`.<br>• In a read filter, `none` drops the condition. In an update or delete filter an optional value is a compile error.<br>• An update must use operators.<br>• `$where`, `$function` and `$accumulator` are compile errors.<br>• In aggregation expressions, every string that is not written in the source is sent as `{"$literal": s}`. This closes a field-path injection that the prototype demonstrated. |
| L5 | **ClickHouse queries are `sql` literals.** `ch_query("... {x} ...")` reuses the `sql` lexer and rewriter in a ClickHouse dialect.<br>• `{x}` becomes `{pN:Type}`, with Type derived from the Khrip type.<br>• A non-literal query is a compile error.<br>• `{name:Type}` written by habit gets a targeted error.<br>• `ch_insert("t", rows)` encodes rows to the real column types (the other team's cached DESCRIBE). |
| L6 | **Clients come from the environment:** `MONGODB_URI` (database in the path) and `CLICKHOUSE_URL`. Optional named servers are `MONGODB_URI_<NAME>` and `CLICKHOUSE_URL_<NAME>`. Configuration is parsed once at start into permanent memory and never lives in `store`. |
| L7 | **Startup checks.**<br>• Connect and authenticate.<br>• Run `fn on_start()` for indexes and idempotent DDL.<br>• ClickHouse: `DESCRIBE TABLE` for every `ch_insert` and `DESCRIBE (query)` for every `ch_query`, checked against the Khrip row types.<br>• MongoDB: a collection that the program reads but never writes must exist.<br>• At compile time, a collection schema is inferred from the types used with each collection literal. It checks filter keys, `$set`/`$inc` types, sort and index keys. |
| L8 | **Binary data (С11).** No `bytes` type is added. Binary BSON values and binary ClickHouse columns map to `Base64`: a branded `str` holding base64 text, valid ASCII everywhere (store, JSON, KHRIP_DATA after UTF-8 steps E/F). Wire bytes (`MongoDoc`, cursor handles) are library-only values that cannot be stored, sent as JSON or returned. |
| L9 | **Runtime.**<br>• Network calls stay forbidden inside `tx`.<br>• MongoDB has no transactions in v1: conditional single-document writes are the idiom (argued in §7.2).<br>• Exactly one store-lock window per driver, built on the GC design §6.5 pattern (everything prepared before release).<br>• Library code never writes into user-reachable objects (cursor handles, not cursor structs).<br>• Typed driver calls do not force the exclusive store lock. |
| L10 | **KHRIP.md section: 561 o200k / 567 Claude tokens.** It replaces the current 124 / 138-token paragraph that names no function. A habits line adds 32 / 39. |
| L11 | **Evidence.** P1 is 262 o200k (PR API 742, Go 1184, Khrip+PostgreSQL 318). P2 is 296 (703, 990). P3 is 238 (424, 889). Go/this design is 3.3–4.5 (o200k) and 4.1–5.5 (Claude), against 2.31 for the PostgreSQL eval tasks. |

**Where syntax would really be needed** (§8.4):
- **ClickHouse query text.** It needs the lexer, because `{x}` must not be
  interpolation. That is the same work as a `ch "..."` keyword. Measured on P3, the
  function form costs 1 o200k / 3 Claude tokens more per query, so the keyword buys
  nothing.
- **MongoDB multi-document transactions.** They need a block that the runtime can
  re-run. A library without closures cannot express it, so they are deferred. If
  needed later, reuse `tx` rather than add a new form.
- **A time type.** BSON Date, ClickHouse DateTime and PostgreSQL timestamptz together
  would need one. That is a language decision, not a driver decision.

Everything else stays a library call.

**How the review's findings are resolved:**

| Finding | Resolution |
|---|---|
| В1 (nested Bson) | `MongoDoc` is embedded as a document; `to_bson` leaves the user surface (§2.1). |
| В2 (none → null) | `none` is omitted; an explicit JSON `null` becomes null, guarded by the not-null check (§4.1). |
| В3 (ClickHouse injection) | The query must be a literal, and `{x}` is a parameter (§3.2). |
| В4 (silent errors) | Fail-closed; `DbResult` must be checked (§5). |
| В5 (cursor protocol) | `[T]` drains the cursor; `db_next` returns typed batches and `[]` at the end (§2.3). |
| В6 (`ch_insert` types) | DESCRIBE-based encoding plus a startup check (§4.2, §6.2). |
| К1 (cursor in store) | Handles that cannot be stored (§7.4). |
| С8 (name collisions) | 24 public names instead of 55; linked only when used. |
| С11 (binary in `str`) | `Base64` (§4.3). |
| С13 (ObjectId) | `ObjectId` type, JSON as hex, routes, `object_id()` (§4.1). |
| С14 (options, indexes) | `MongoOpts`, `mongo_index`, `on_start` (§2, §6). |
| С15/С16 (prompt, tokens) | §9 and §10. |
| Н2 (positional arguments) | Option literals checked per call (§2.4). |
| Н5 (names, shared error slot) | One result type; no error slots (§5). |

---

## 1. Principles

1. **One mental model with `sql`.** An AI that has learned the PostgreSQL section
   already knows these rules:
   - the expected type picks the result;
   - `{x}` is never text;
   - a failure ends the request with a status;
   - the server is checked at start;
   - no locks or awaits.

   The new section mostly says "as with `sql`".
2. **Library-first.** All protocol work is library code on top of the other team's
   layer: BSON validated once, URI options, killCursors, DESCRIBE-encoded inserts,
   FIFO admission, TLS.

   The compiler only does what a library without generics, named arguments or
   dynamic values cannot do:
   - choose the result type;
   - accept mixed-type documents;
   - stop `{x}` from becoming text;
   - see literal names, which makes startup checks and schema inference possible.
3. **Fail-closed by default; explicit by type.** Doing the wrong thing silently must
   take more tokens than doing the right thing.
4. **Nothing driver-specific reaches `store` or JSON.** No wire bytes, cursor structs
   or configuration values. This is what makes GC v0.13 and UTF-8 v0.13 hold without
   special cases.

---

## 2. Surface

`coll` and `table` are string literals or `const` strings. A dotted name means
another database on the same server: `"analytics.events"`.

The last argument `opts` is optional. When given, it must be a `MongoOpts { ... }` or
`ChOpts { ... }` literal (§2.4). Shapes:

| Expected type | Shape |
|---|---|
| `T` | exactly one; none → 404 |
| `T?` | zero or one; more → 500 |
| `[T]` | all, up to `*_MAX_RESULT` |
| none | count |
| `DbResult` | explicit outcome of a write (§5.2) |

`T` is a struct, or a single scalar for `distinct`, `count` and one-column queries.

### 2.1 MongoDB

```
mongo_find(coll, filter, opts?)            -> T | T? | [T]
mongo_count(coll, filter, opts?)           -> int
mongo_distinct(coll, field, filter, opts?) -> [T]            // field: literal; T scalar
mongo_aggregate(coll, pipeline, opts?)     -> T | T? | [T]   // nothing if the last stage is $out/$merge
mongo_insert(coll, doc | [doc], opts?)     -> int | T | T? | [T] | DbResult
mongo_update(coll, filter, update, opts?)  -> int | T | T? | DbResult
mongo_replace(coll, filter, doc, opts?)    -> int | T | T? | DbResult
mongo_delete(coll, filter, opts?)          -> int | T | T? | DbResult
mongo_index(coll, keys, opts?)                                 // createIndexes; idempotent
mongo_command(cmd, opts?)                  -> T              // escape hatch: typed reply
mongo_cursor(coll, filter | pipeline, opts?) -> DbCursor
object_id()                                -> ObjectId
s.to_object_id()                           -> ObjectId?       // str → ObjectId, none if not 24 hex
```

**Arguments.**
- `filter`, `update`, `doc`, `keys`, `cmd`: a `{...}` literal (§3.1), a struct, a
  `map[str, T]` or a `MongoDoc`.
- `pipeline`: a `[...]` literal of stage literals, or a `[MongoDoc]`.

| Call | No type (count) | `T` / `T?` | `[T]` | Notes |
|---|---|---|---|---|
| `mongo_find` | compile error | `find` with `limit 2`, or `limit 1` when `opts.limit == 1` | `find`, drained | Projection = top-level fields of `T`. `_id` is excluded when `T` has no `_id`. |
| `mongo_aggregate` | allowed only with `$out`/`$merge` | `aggregate`, at most one result | drained | `cursor: {}` is added by the library. |
| `mongo_insert` | number inserted | The stored document decoded into `T`, including a generated `_id`. **`T?`: none on a duplicate key** (the `ON CONFLICT DO NOTHING` idiom). | stored documents | A list is sent as one `insert`. Default `ordered: true`; see §5.1 for partial lists. |
| `mongo_update` | `update` with `multi: true` → **matched** count (`upsert` counts as 1) | `findAndModify` with `new: true` (the document after the change); none → 404 / none | — | Changes **all matches** with no type, like SQL `UPDATE`; changes **one** with a document type. |
| `mongo_replace` | `update` with a replacement document, `multi: false` → matched | `findAndModify`, replacement, `new: true` | — | `doc` must be a struct or literal without operators. |
| `mongo_delete` | `delete` with `limit: 0` → deleted count | `findAndModify` with `remove: true` → the deleted document | — | Same "all, or one into a type" rule. |
| `mongo_count` | `aggregate [{$match}, {$count}]` | — | — | Takes `limit` and `skip` options. |
| `mongo_distinct` | — | — | `distinct` | Read-filter rules apply. |
| `mongo_command` | — | the reply document decoded into `T` | — | Command name from the first key. `ok: 0` → fail-closed. Only for admin commands (`collStats`, `collMod`, `ping`). |

`mongo_index(coll, {"email": 1}, MongoOpts { unique: true })`:
- creates the index (default name: Mongo's own, `email_1`);
- does nothing if an identical index exists;
- with other options under the same name, stops the program at start with the
  message in §6.

TTL indexes are not in v1, because writing a BSON Date needs a time type (§4.1).

**Types the AI sees:** `ObjectId`, `MongoOpts`, `DbResult`, `DbCursor`; in
DATABASES.md also `MongoDoc` and `Base64`.

**Gone from the user surface** (kept as library internals, renamed with `__` or
unexported):
- `Mongo`, `MongoResult`, `MongoCursor`;
- `to_bson`, `from_bson`, `bson_*`;
- `mongo_next`, `mongo_close`, `mongo_find_with`, `mongo_create_indexes`;
- `bson_error`.

The AI never sees two API generations.

### 2.2 ClickHouse

```
ch_query("SQL with {x}", opts?)      -> [T] | T? | T | int | DbResult
ch_insert(table, rows | row, opts?)  -> int | DbResult              // rows: [T], row: T (struct)
ch_cursor("SELECT ... {x}", opts?)   -> DbCursor
ch_cancel(query_id, opts?)           -> bool                        // KILL QUERY ... ASYNC; true if one was found
```

**`ch_query` works exactly like `sql`:**
- `[T]`, `T?` (more than one row → 500), `T` (none → 404);
- `T` is a struct (columns by name) or one column's scalar;
- with no type, a statement that returns no rows (DDL, `INSERT ... SELECT`, `ALTER`,
  `OPTIMIZE`, `SYSTEM`) returns `written_rows` from `X-ClickHouse-Summary`;
- with no type, a `SELECT`/`WITH`/`SHOW`/`DESCRIBE`/`EXISTS`/`EXPLAIN` is a compile
  error, as in `sql`.

**`ch_insert(table, rows)`:**
- encodes `[T]` (or one `T`) with RowBinary into the real column types of `table`,
  using the cached `DESCRIBE`;
- returns `rows.len()`;
- an empty list sends nothing and returns 0.

**Async insert** is `ChOpts { async: true }`: `async_insert=1&wait_for_async_insert=1`,
so the call returns after the server flushed. There is no fire-and-forget mode: it
would make write errors invisible, which is against L3.

**Query ids and cancellation.**
- Every call gets `query_id = "khrip-<24 random>"`, unless `ChOpts { query_id }` is
  given. The id appears in error logs.
- When a SELECT hits the client deadline, the library sends a best-effort
  `KILL QUERY WHERE query_id = {id} ASYNC` on a separate pooled connection.
- It never does this for an INSERT: cancelling is not a rollback.
- `max_execution_time` is the remaining budget, not the whole timeout (Н12).
- `ch_cancel(id)` cancels explicitly. It needs `KILL QUERY` rights.

**DDL** goes through `ch_query` in `on_start` (§6.3).

### 2.3 Shared

```
fn on_start() { ... }            // user-defined; runs once after migrations, before serving (§6)
db_next(c: DbCursor) -> [T]      // next batch as [T]; [] when exhausted (and after that)
type DbResult { ... }            // §5.2
```

**Cursors** are for streaming large results, for example in an `every` job:

```khrip
let c = mongo_cursor("events", {"day": day}, MongoOpts { sort: {"_id": 1}, batch: 500 })
while true {
    let batch: [Event] = db_next(c)
    if batch.len() == 0 {
        break
    }
    for e in batch { ... }
}
```

- Nothing is fetched until the first `db_next`, so the В5 trap ("the first batch is
  already there") cannot be written.
- `getMore` uses the namespace the server returned.
- A cursor not exhausted at the end of the request or task is killed by the
  request-end hook. For ClickHouse, its connection is closed instead of pooled.
- Batches: MongoDB 1000 documents by default (`batch`). ClickHouse 65 536 rows or
  16 MiB.
- Decoded batches stay in the request arena until the request ends. A cursor bounds
  the network buffering and allows an early `break`; it is not constant memory.
  DATABASES.md says so.
- For ClickHouse, the row type of `ch_cursor` is the `T` of its `db_next` calls. The
  compiler links them through the local variable (§8.2), and the startup check uses it.

### 2.4 Options

The options are literals so the compiler can check, per call, which fields apply.
Khrip has no named arguments; a struct literal is the named-argument form, and it
removes the Н2 traps (`mongo_find(..., 20)` meaning batch size).

```khrip
type MongoOpts {
    sort: MongoDoc?           // {"created": -1, "_id": 1}; key order is kept
    limit: int? = none        // none: no limit; 0: no documents; negative → 400
    skip: int = 0
    upsert: bool = false      // update, replace
    ordered: bool = true      // list insert: stop at the first error
    unique: bool = false      // index
    name: str = ""            // index name
    batch: int = 0            // cursor batch size (0: 1000)
    timeout_ms: int = 0       // 0: MONGODB_TIMEOUT
    server: str = ""          // literal; "" default, "audit" → MONGODB_URI_AUDIT
}
type ChOpts {
    settings: map[str, str] = {}   // per-query settings; names checked as identifiers
    query_id: str = ""
    async: bool = false            // insert: server-side batching, waits for the flush
    dedup: str = ""                // insert: insert_deduplication_token
    timeout_ms: int = 0
    server: str = ""
}
```

| Call | Accepted fields |
|---|---|
| `mongo_find`, `mongo_cursor` | `sort limit skip batch timeout_ms server` (`batch` only for the cursor) |
| `mongo_count` | `limit skip timeout_ms server` |
| `mongo_update`, `mongo_replace` | `upsert sort timeout_ms server` (`sort` only into `T`/`T?`) |
| `mongo_delete` | `sort timeout_ms server` (`sort` only into `T`/`T?`) |
| `mongo_insert` | `ordered timeout_ms server` |
| `mongo_aggregate`, `mongo_distinct`, `mongo_command` | `timeout_ms server` |
| `mongo_index` | `unique name server` |
| `ch_query`, `ch_cursor` | `settings query_id timeout_ms server` |
| `ch_insert` | `settings query_id async dedup timeout_ms server` |

A field outside this list is a compile error (§8.3, E13).

`limit` is `int?` on purpose. With an `int` default of 0, a client-supplied
`?limit=0` would silently mean "everything", which is MongoDB's meaning but not
SQL's.

---

## 3. Parameters and injection

### 3.1 MongoDB: values are typed data, keys are source text

**Rule D1: a document position.** These are document positions:
- the `filter`, `update`, `doc`, `keys` and `cmd` arguments;
- each element of a `pipeline` literal;
- `MongoOpts.sort`;
- a `let x: MongoDoc = ...`.

A `{...}` there is a **document literal**:
- every key is a string literal (or a `const` str);
- every value is any expression;
- a value that is itself `{...}` or `[...]` is again a document or array literal;
- each value is encoded by its own static type (§4.1);
- key order is kept.

This is the one typing rule that makes `{"status": "paid", "created": {"$gte": since}}`
legal without a builder. It is the same idea as `{x}` in `sql`, where each
parameter keeps its own type. It removes P2's 25 builder calls.

**Rule D2: values never become operators.**
- Operators can only be written as literal keys in the source.
- A `str` value is always a BSON string.
- A `map[str, T]` whose keys come from run time is checked at encode time. A key
  that starts with `$`, contains `.` or contains NUL fails the request with 400
  `field name may not start with $: <key>`. This blocks `{"$where": ...}` and
  `{"$ne": ...}` from a JSON body.
- `$where`, `$function` and `$accumulator` as literal keys are compile errors
  (server-side JavaScript).

**Rule D3: expression context.** These are expression positions:
- pipeline stages other than `$match`, `$sort`, `$limit`, `$skip`, `$count`,
  `$unset`, `$out` and `$merge`;
- anything under `$expr`.

There, a string beginning with `$` is a field path. So **every `str` that is not a
literal in the source is sent as `{"$literal": s}`**. This includes strings inside
structs, maps and lists embedded there. String literals in the source are sent as
written (`"$category"`).

The prototype first wrapped only direct values. This probe, with a runtime map in a
stage:

```khrip
let fields = {"label": name}
return mongo_aggregate("sem_notes", [{"$addFields": fields}, {"$project": {"label": 1}}])
```

with `?name=%24secret` returned `[{"label":"s1"},{"label":"s2"}]`: the `secret` field
of every document leaked. After the fix (recursive wrapping) it returns
`[{"label":"$secret"}, ...]`. Unknown future stages default to expression context,
which is the safe side.

**Rule D4: filters and `none`.** In a **read filter** (`mongo_find`, `mongo_count`,
`mongo_distinct`, `mongo_cursor`, and `$match` in a pipeline):
- a `none` value drops its key;
- a sub-document literal that becomes empty is dropped too.

So `{"tags": tag, "views": {"$gte": min}}` with both values none is `{}`, which
matches all. This is the Go `if tag != "" { filter["tags"] = tag }` idiom in one
literal; the prototype confirmed it (§10.3).

In an **update, replace or delete filter**, a `T?` value is a compile error (E6).
Without it, a missing value would widen the write to every document. The same holds
for a struct used as such a filter if any field is optional.

**Rule D5: updates use operators.** A literal update whose first key does not start
with `$` is a compile error (E7). Without operators MongoDB replaces the whole
document; the probe in §10.3 shows `update` with `{}` wiping `a` and `b`. A struct
passed as `update` is the same error. Replacement is `mongo_replace`.

**Rule D6: names are literals.** Collection names are literals, so a collection
cannot be chosen by input. Choosing between collections means `if`/`match` over
whole calls, as `sql` requires for table names.

### 3.2 ClickHouse: the query is a `sql` literal in a ClickHouse dialect

**Lexing.** When the lexer sees the identifier `ch_query` or `ch_cursor`, then `(`,
then (after spaces or newlines) `"` or a backtick, it lexes that string with `lex_sql`
in ClickHouse mode:
- quote states `'...'` and `"ident"`;
- comments `--`, `#`, `/* */`;
- `{}`, `{3}` and `{1,2}` stay text.

It produces a `T_SQL` token marked with the dialect. In any other form, the first
argument is a compile error (E21):
- `ch_query(q)`;
- `ch_query("SELECT " + x)`;
- a `const` built by concatenation.

This is the "literal-only" stopgap made permanent, and it is why injection cannot be
written. Backtick-quoted ClickHouse identifiers cannot appear inside a Khrip backtick
string; DATABASES.md says to use `"ident"`.

**Rewriting.** This reuses `parse_sql`, with the dialect switches marked:

| Source | Sent | Note |
|---|---|---|
| `{x}` | `{pN:Type}` with `param_pN` in the URL | Type from §3.3. Values are escaped as the existing `__ch_param` does; NULL is `\N` (fixes Н9). |
| `{x} IS NULL`, `{x} IS NOT NULL` | a `Bool` parameter | Same as `sql`. |
| `col = {x}` with `x: T?` and no `IS NULL` guard | compile error E22 | The `sql` message. |
| `IN ({xs})` or `IN {xs}` | `IN {pN:Array(T)}` | Checked on 25.8: both forms work; an empty array matches nothing. |
| `'%{q}%'` after `LIKE`/`ILIKE` | `concat('%', {pN:String}, '%')` | The value's `%`, `_` and `\` are escaped with `\`. Checked: for `q = "50%"` the pattern matches `/50%_off` and `/50%Xoff` but not `/50x_off`; unescaped, all three match. |
| `'...{x}...'` elsewhere | `concat('...', {pN:String}, '...')` | |
| `ORDER BY {o}` | one query variant per string literal | Same as `sql` (`lit_set`). |
| `{x}` after `FROM`, `JOIN`, `INTO`, `TABLE` | compile error E23 | |
| `{name:Type}` (ClickHouse habit) | compile error E20 | The type comes from Khrip. |
| `?`, `$1` | compile error E27 | |
| `FORMAT ...` | compile error E25 | The driver sets RowBinaryWithNamesAndTypes. |
| `;` with more after it | compile error E26 | One statement. |
| `SETTINGS ...` | allowed | Not a value position. |

What does not carry over from `sql`:
- PostgreSQL catalog markers (`%%T`, `%%D`);
- the "write after another statement outside tx" rule, because ClickHouse has no
  transactions;
- `INSERT INTO t {rows}`. Inserts are `ch_insert`, which is shorter (7 tokens against
  9) and needs no SQL rewriting.

### 3.3 ClickHouse parameter types from Khrip types

| Khrip | Parameter type |
|---|---|
| `int` | `Int64` |
| `float` | `Float64` |
| `bool` | `Bool` |
| `str`, `ObjectId`, enum (label) | `String` |
| `Base64` | `String` (raw bytes after decoding) |
| `[T]` | `Array(T')` |
| `T?` | `Nullable(T')` |
| `[T]?` | compile error E28: arrays are never NULL in ClickHouse; use `[]` |
| struct, map | compile error: "use ch_insert for rows" |

**Checked against 25.8:**

| Comparison | Result |
|---|---|
| `Int64` with `DateTime`, `UInt32`, `UInt64`, `Decimal`, `DateTime64`, and as `LIMIT` | works |
| `String` with `Date`, `Enum8`, `LowCardinality(String)` | works |
| `Int64` with `Date` | error 43 |
| ISO `"2025-10-24T00:00:00Z"` `String` with `DateTime` | error 53, even with `date_time_input_format=best_effort` |

Both errors are caught at startup (§6.2), with hints:
- `toDate({x})`;
- pass an `int`, or write `parseDateTimeBestEffort({x})`.

---

## 4. Types and mapping

### 4.1 Khrip and BSON

| Khrip | Written as | Read from |
|---|---|---|
| `int` | Int64 | Int32, Int64, integral Double in range (other team's widening) |
| `float` | Double | Double, Int32, Int64, Decimal128 (rounded) |
| `bool` | Boolean | Boolean |
| `str` | String. Invalid UTF-8 (only from headers, files or fetch bodies) → 400 `field body: invalid UTF-8`. | String: invalid UTF-8 → 500 with the field path (other team). Decimal128 → exact decimal text. Date → `time_iso` with milliseconds when non-zero. |
| `ObjectId` | ObjectId | ObjectId only. A String is an error: no silent string/ObjectId mix. |
| `Base64` | Binary, subtype 0 | Binary (subtype 0, 4 or 5) |
| enum | String (label) | String; an unknown label → 500 |
| variant with fields | Document with `"type"` (as JSON) | same |
| struct | Document; `none` fields omitted | Document. A missing field → default, or none for `T?`, else 500. Extra fields are ignored. |
| `map[str, T]` | Document (runtime keys checked, D2) | Document |
| `[T]` | Array; `none` elements → null | Array |
| `T?` | omitted when none; written as null only if the client sent an explicit JSON `null` | null or missing → none |
| `MongoDoc` | embedded as is | — |

**`none` and the PATCH idiom.** `mongo_update("notes", {"_id": id}, {"$set": patch})`
with `patch: NotePatch { title: str?, body: str?, tags: [str]? }` sets only the fields
the client sent. The prototype run is in §10.3: PATCH `{"title": "t1 new"}` keeps
`body` and `tags`, and an empty PATCH is a no-op that returns the document.

An explicit JSON `null` is written as BSON null, like `sql`'s `SET {patch}`. It uses
the same request-local marks (`__json_null_sent`).

**Not-null guard.** A field may be written as null only if every type known for the
collection (§6.4) declares that field optional. Otherwise the request fails with 400
`missing value: notes.title`, as a NOT NULL column does in PostgreSQL. Without the
guard, `$set: {title: null}` would succeed, and every later read into `Note` would
fail with 500.

**`_id`.**
- The document key is the field named `_id`, in types and filters alike. There is no
  renaming, because renaming would make `{"id": ...}` filters silently match nothing.
- JSON shows `_id`.
- On insert, a document with no `_id` field, or with `_id: ObjectId?` = none, gets
  an ObjectId generated client side (as the Go driver does). `mongo_insert` into `T`
  returns it.
- An `_id` of type `str?` or `int?` is a compile error: give every document an id.

**`ObjectId`** is a branded `str`: kind `K_STR`, brand 1. Its runtime value is the
24-character lowercase hex text.
- It is accepted where `str` is expected: interpolation, `+`, `len`, function
  arguments.
- A `str` is not accepted where `ObjectId` is expected; convert with
  `s.to_object_id()`.
- In JSON it is the hex string. JSON input, and path and query parameters, are
  validated and lowercased. A bad value → 400 `parameter 'id' must be an ObjectId
  (24 hex digits), found 'not-an-id'` (prototype output).
- In BSON it is the 12-byte ObjectId.
- `object_id()` gives 4 bytes of big-endian seconds and 8 random bytes. The prototype
  uses 8 random bytes. The final version uses the standard layout: 5 random bytes
  per process and a 3-byte counter.
- It cannot be a map key type (`K` is `int` or `str`); `id.to_str()` is the key.

**Dates.**
- BSON Date reads into `int` (unix seconds, floor) or `str` (ISO time).
- Khrip `int` times are written as Int64 and stay sortable and filterable.
- Writing BSON Date is **not in v1**, so there are no TTL indexes. Expiry is
  `every 1 h { mongo_delete("sessions", {"expires": {"$lt": now()}}) }`.
- A branded `int` time type would serve BSON Date, ClickHouse DateTime and PostgreSQL
  timestamptz together. That is a language decision (§8.4).

**Decimals.**
- Decimal128 reads into `float` (rounded, chosen by the type) or `str` (exact).
- Writing Decimal128 is not in v1. KHRIP.md already says to keep money in int cents.

### 4.2 Khrip and ClickHouse

**Insert (`ch_insert`).** Rows are encoded into the real column types. The other
team's layer does this with a cached `DESCRIBE TABLE`, and §6.2 checks it at start.

| Khrip field | Accepted columns |
|---|---|
| `int` | `Int8`–`Int64`, `UInt8`–`UInt64` (range-checked); `DateTime` (unix seconds, range-checked); `DateTime64(p)` (seconds × 10^p); `Date`/`Date32` (seconds → UTC day); `Decimal(P, 0)` |
| `float` | `Float32`, `Float64`; `Decimal(P, S)` (rounded to S) |
| `bool` | `Bool`, `UInt8` |
| `str` | `String`; `FixedString(n)` (more than n bytes → 400); `LowCardinality(String)`; `Enum8/16` (label must exist → 400); `UUID`; `IPv4`/`IPv6`; `Date`/`Date32` (`YYYY-MM-DD`); `DateTime`/`DateTime64` (ISO 8601 via `parse_time`; no zone = UTC); `Decimal` (exact text) |
| `ObjectId` | `String`, `FixedString(24)` |
| `Base64` | `String`, `FixedString(n)` (raw bytes) |
| enum | `Enum8/16` (every Khrip variant must be a label: checked at start), `String`, `LowCardinality(String)` |
| `[T]` | `Array(T')` |
| `map[str, T]` | `Map(String, T')` |
| `T?` | `Nullable(T')`: none → NULL. For a non-Nullable column: none → the column default (`input_format_null_as_default=1`, checked on 25.8). |
| struct | not supported; startup error: use separate columns |

A value that does not fit fails the request with 400:
`events.level: 300 does not fit UInt8`.

**Explicitly rejected at start:**
- `int` into `Decimal(P, S > 0)`. The AI keeps cents in `int`, so this would store
  100× the amount. The hint is to write a `str` or `float`, or to use an `Int64`
  cents column.
- A column that is not in the struct and has no `DEFAULT`, `MATERIALIZED`, `ALIAS`
  or `EPHEMERAL` expression and is not `Nullable`. It would silently get `0`, `''` or
  `1970-01-01`.
- A struct field with no column.

**Read (`ch_query`, `db_next`).** Checked at start against `DESCRIBE (query)`, and at
run time against the RowBinaryWithNamesAndTypes header of each response.

| ClickHouse | Khrip |
|---|---|
| `Int*`, `UInt*` | `int` (a `UInt64` above 2^63−1 → 500), `float` |
| `Float32/64` | `float` |
| `Decimal(P, S)` | `float`, `str` (exact), `int` only if S = 0 |
| `Bool` | `bool` |
| `String`, `FixedString`, `LowCardinality(String)` | `str` (raw bytes, as fetch bodies), `Base64` |
| `UUID`, `IPv4`, `IPv6` | `str` |
| `Enum8/16` | `str`, Khrip enum (labels checked at start) |
| `Date`, `Date32` | `str` `"YYYY-MM-DD"`, `int` (unix seconds at 00:00 UTC) |
| `DateTime` | `int` (unix seconds), `str` (`time_iso`, always UTC) |
| `DateTime64(p)` | `str` (ISO with fraction), `float` (seconds); `int` only if p = 0, otherwise a startup error naming `toUnixTimestamp64Milli(ts) AS ts_ms` |
| `Nullable(T)` | `T?`. A non-optional field is a startup error, as in `sql`: "a nullable column needs T?". |
| `Array(T)` | `[T]` |
| `Map(String, T)` | `map[str, T]` |
| `Tuple`, `JSON`, `Variant`, `Dynamic`, `Nested`, `AggregateFunction` | startup error with a hint: select the elements, `toString`, `JSONExtract`, `-Merge` |

Columns are matched to fields by name. Extra columns are ignored. A missing field
with a default or `T?` is allowed; otherwise it is an error, exactly as in
`__db_check`.

### 4.3 Binary data and UTF-8 (С11, v0.13-utf8.md D9)

**There is no `bytes` type.** Binary data reaches user code only as `Base64`: a
branded `str` (brand 2) holding standard base64 text.
- It is valid ASCII, so store, JSON, KHRIP_DATA snapshots and the strict boundaries
  of UTF-8 steps E/F keep it exactly.
- JSON carries it as a string, which is how JSON APIs carry binary anyway.
- Route bodies and parameters validate it: invalid base64 → 400.
- The driver converts at the wire: BSON Binary and ClickHouse bytes.

Reading BSON Binary into a plain `str` is a decode error: "field avatar is Binary:
declare it Base64".

Wire bytes stay inside the library:
- `MongoDoc` holds BSON;
- `DbCursor` is a handle.

The compiler forbids both in `store`, globals, `to_json`, route parameters and route
results (E18). So no binary `str` can reach a snapshot. This is the "ban in store and
JSON" option of the review, applied to the only types that need it, plus the "base64"
option for user data.

**Rows to add to the D9 boundaries table:**

| Source or sink | v0.13 rule |
|---|---|
| MongoDB String → `str` | Strict. Invalid UTF-8 → the request fails 500. The log names the collection, `_id` and field path. Other values in the reply are unaffected (other team: UTF-8 checked at `str` conversion). |
| `str` → MongoDB String | Must be valid (BSON requires it). Invalid → 400 `field <path>: invalid UTF-8`. |
| ClickHouse `String`/`FixedString` → `str` | Raw bytes, like fetch bodies and bytea. `to_json` replaces invalid bytes. |
| `str` → ClickHouse parameter or column | Raw. |
| Binary (BSON Binary, any ClickHouse string declared `Base64`) ↔ `Base64` | base64 ASCII. |
| `MongoDoc`, `DbCursor` | Library-only. Cannot be stored, sent as JSON or returned. |

---

## 5. Errors

### 5.1 Fail-closed: one table for MongoDB, ClickHouse and `sql`

All failures go through one function, `__drv_fail(status, body, log)`. It reuses
`__db_answer`:
- inside a request it calls `fail(status, body)` and adds `Retry-After: 1` for 503;
- outside a request (`every`, `on_start`) it panics with the log text;
- in `on_start` the program exits with code 1.

The response body never contains values from the data, only names. Values go to the
log, as `__db_classify` does for PostgreSQL.

| Situation | MongoDB | ClickHouse | Status | Body |
|---|---|---|---|---|
| Duplicate key | 11000, 11001, 12582 (also inside `writeErrors`) | — (no unique keys) | 409 | `already exists: notes.email_1` |
| Bad value from the client | 121 DocumentValidationFailure; 10334 too large; runtime `$` key (D2); invalid UTF-8; not-null guard | 6, 27, 38, 41, 53, 69, 70, 72, 321, 376; client-side encode errors (range, enum label, FixedString length, unparseable date) | 400 | ClickHouse: first line of the exception without `(version …)`. MongoDB: `invalid document: notes` / `field name may not start with $: …` / `missing value: notes.title`. |
| No match into `T` | — | — | 404 | `not found` |
| Server down, busy or timed out (the request was **not** sent, or it was a read) | connect, pool wait, TLS, auth (18) failures; 6, 7, 50, 89, 91, 189, 262, 9001, 10107, 10058, 11600, 11602, 13435, 13436 | connect or pool failure; 159, 160, 202, 203, 209, 210, 241, 242, 252, 285, 394, 425, 516, 999; client deadline on a SELECT | 503 + `Retry-After: 1` | `database unavailable, try again` |
| Write sent, outcome unknown | lost connection after sending; `writeConcernError`; 64, 100 | lost connection or deadline after sending an INSERT; 319 UNKNOWN_STATUS_OF_INSERT | 500 | `outcome unknown` |
| Program error (should have been caught at start) | 2, 9, 14, 40, 52–57, other `ok: 0`; 13 Unauthorized | 43, 46, 47, 60, 62, 386, 164, 497 | 500 | `internal error` (the log has the command and the server message) |
| Document or row does not match the type | decode error with path | header type mismatch, `UInt64` overflow, unknown enum label | 500 | `internal error`. Log: `mongodb notes: document 6adb… does not match Strict: missing BSON field: views` (prototype output). |
| Result too large | over `MONGODB_MAX_RESULT` (64 MiB of BSON) | over `CLICKHOUSE_MAX_RESULT` (64 MiB); 396 | 500 | `internal error`. Log hint: add a limit or use a cursor. |
| More than one into `T`/`T?` | 2 found with `limit 2` | 2 rows | 500 | `internal error`. Log: `one document expected, more matched`. |

Unknown outcome is 500, not 503, on purpose. 503 invites a blind retry; PostgreSQL
`08007` already answers 500 for the same reason.

An authentication failure at run time is 503, because the credentials were checked
at start and a run-time failure is a rotation. It is logged loudly.

**List inserts are not atomic** (MongoDB `insert` of a list, ClickHouse with
`async`). On failure, the documents before the failing one stay. The fail-closed
answer is 409 or 400 for the whole request. DATABASES.md says this. Code that must
know which documents failed uses `DbResult` with `MongoOpts { ordered: false }`.

### 5.2 Explicit form: `DbResult`

```khrip
type DbResult {
    ok: bool                // status == 200
    status: int             // 200, or what the request would have ended with: 400, 404, 409, 500, 503
    error: str              // the body the request would have sent
    code: int               // MongoDB error code / ClickHouse exception code; 0 for client-side errors
    unknown_outcome: bool   // the write may have been applied: do not retry blindly
    n: int                  // matched / inserted / deleted documents; written rows
    modified: int           // MongoDB update: documents actually changed
    upserted: bool          // MongoDB update or replace inserted a document
    failed: [int]           // list insert with ordered: false: indexes of the documents that failed
}
```

- **Writes only.** It works with `mongo_insert`, `mongo_update`, `mongo_replace`,
  `mongo_delete`, `ch_insert`, and `ch_query` without rows. A read into `DbResult` is
  a compile error (E16). As with `sql`, a failed read ends the request; there is no
  read fallback in v1.
- **Must be checked.** A local of type `DbResult` must be read in at least one of
  `.ok`, `.status`, `.code`, `.error` or `.unknown_outcome`. Otherwise it is a
  compile error (E15). Reading only `.n` does not count: on failure `n` is 0, which
  looks like "nothing matched".
- **The common cases need no `DbResult`:**
  - duplicate allowed: `let n: Note? = mongo_insert(...)`;
  - not found: the count is 0, or `T?` is none;
  - everything else ends the request.

  An expression statement (`mongo_update(...)` with its count dropped) is fine,
  because a failure cannot be silent.
- **One convention.** There is no shared error slot (`bson_error()`, `ch_error()`,
  `json_error()` for drivers), no `Bson.error` and no sticky builder errors (Н5). Both
  drivers and both result kinds use the same fields.

---

## 6. Configuration, startup and schema

### 6.1 Configuration (environment, parsed once at start)

| Variable | Default | Meaning |
|---|---|---|
| `MONGODB_URI` | required when `mongo_*` is used | `mongodb://user:password@host:27017/app?authSource=admin&tls=true`.<br>• The **database comes from the path**; a missing database is a startup error.<br>• Options come from the other team's layer: `authSource`, `authMechanism`, `tls`, `tlsCAFile`, `directConnection`, `appName`, `maxPoolSize`, `w`, `wtimeoutMS`, `journal`, `replicaSet`.<br>• `retryWrites` is accepted and the driver still never retries.<br>• `readPreference` other than `primary` → startup error. |
| `MONGODB_URI_<NAME>` | — | A server for `MongoOpts { server: "name" }`. |
| `CLICKHOUSE_URL` | required when `ch_*` is used | `http(s)://user:password@host:8123/database`. The database comes from the path (default `default`). `CLICKHOUSE_USER` / `CLICKHOUSE_PASSWORD` apply if the URL has none. |
| `CLICKHOUSE_URL_<NAME>` | — | A server for `ChOpts { server: "name" }`. |
| `MONGODB_TIMEOUT`, `CLICKHOUSE_TIMEOUT` | `DATABASE_TIMEOUT` (10 000 ms) | Per call: pool wait plus exchange. `maxTimeMS` and `max_execution_time` are set to the remaining budget. |
| `MONGODB_MAX_RESULT`, `CLICKHOUSE_MAX_RESULT` | 64 MiB | Bytes per `[T]` result, and per cursor batch. |
| `MONGODB_POOL`, `CLICKHOUSE_INFLIGHT` | 4 per thread, at most 32 / 32 per process | Connections, and FIFO admission (other team). |
| `KHRIP_TEST_MONGODB_URI`, `KHRIP_TEST_CLICKHOUSE_URL` | — | Used by `khc test` (§6.5). |

**Configuration is never a program value.** It is parsed once into permanent memory,
before worker threads start, with `__perm_alloc`:
- URI parsing is not repeated per call (it used to be, at mongo.kh:739);
- nothing configurable lives in `store`;
- store-lock windows read no store object (§7.3).

Tuning lives in the environment and in `MongoOpts`/`ChOpts` (`timeout_ms`,
`settings`). DATABASES.md documents the rest.

**Multiple databases.**
- Another database on the same server: a dotted collection or table name.
- Another server: `server: "audit"` in the options, which must be a literal. That
  lets startup connect to and check every named server.
- Several MongoDB or ClickHouse servers can coexist with PostgreSQL.

### 6.2 Startup sequence (servers and `khc test`)

1. **Configuration.** Parse `DATABASE_URL`, `MONGODB_URI*` and `CLICKHOUSE_URL*`.
   On error, exit 1. Exact messages:
   - `khrip: MONGODB_URI is not set (mongodb://user:password@host:27017/database)`
   - `khrip: MONGODB_URI names no database: put it in the path, mongodb://host:27017/app`
2. **PostgreSQL** (unchanged): connect, run migrations, verify `sql` sites.
3. **Connect.**
   - MongoDB: `hello` and SCRAM authentication. Wire version 17 or later (MongoDB 6)
     is required. For a write program on a secondary: `MongoDB at h:27019 is not a
     writable primary`.
   - ClickHouse: `SELECT version()`, then `SELECT getSetting('readonly')`. If the
     program writes and the user is readonly: `khrip: ClickHouse user khrip is
     read-only, but the program inserts (app.kh:14:12)`.
   - Failure: `khrip: MongoDB at 127.0.0.1:27019: <reason>`, exit 1.
4. **`on_start()`**, if the user defined it (§6.3). Any failure, `fail` or panic
   exits with code 1 and the message.
5. **Verify.**
   - **ClickHouse insert sites:** `DESCRIBE TABLE t` (cached for the encoder), then
     the §4.2 rules. For example: `app.kh:20:5: ch_insert into events: Event.amount
     is int, but column amount is Decimal(12, 2): int would be read as whole units;
     send a str ("12.34") or a float, or make the column Int64 cents`.
   - **ClickHouse query sites:** `DESCRIBE (<query>)` with typed sample parameters:
     `0`, `0.0`, `false`, `[]`, `\N`, and for `str` the Khrip time text
     `1970-01-01T00:00:00Z`. Then `__db_check`-style matching of names and types
     against `T`. Typos fail here, as in the 25.8 probes:
     - `Code: 60 … Unknown table expression identifier 'event'`;
     - `Code: 47 … Unknown expression identifier 'pgae'. Maybe you meant: ['page']`.
   - **Value-dependent errors.** ClickHouse folds constants, so `''` or `0` samples
     can fail where real values would not:
     - `parseDateTimeBestEffort('')` → 41;
     - `intDiv(10, 0)` → 153;
     - `toUUID('')` → 376.

     For codes 6, 27, 38, 41, 53, 69, 70, 72, 153, 321 and 376, verification retries
     with `''` and `00000000-0000-0000-0000-000000000000` as the `str` samples and 1 as
     the numbers.
     - If a "cannot convert string … to DateTime/Date" error remains, startup fails
       with the hint: pass an `int`, or write `parseDateTimeBestEffort({x})`.
     - Otherwise the site is marked "checked at first use": the response header is
       checked anyway, and startup prints one line.
     - `materialize()` wrapping was tried and rejected: it changes typing (`Date >=
       materialize('')` → NO_COMMON_TYPE) and breaks `LIMIT`.
   - **MongoDB collections.** A collection that is read (find, count, aggregate,
     distinct, cursor) but never written by the program must exist: `app.kh:44:12:
     mongo_find reads collection app.note, which does not exist, and this program
     never writes it (did you mean notes?)`. This catches name typos at read sites.
     Collections the program writes may legitimately be empty or new.
   - **MongoDB, optional:** `MONGODB_CHECK=sample` decodes one document per collection
     into each read type and prints mismatches as warnings, without failing. Data may
     legitimately be heterogeneous.
6. Serve.

### 6.3 `on_start`, indexes and DDL

`fn on_start()`:
- takes no parameters and returns nothing (E31);
- runs on one thread after migrations, before serving, and in `khc test` before the
  first test;
- may write `store`, for seeding;
- may call any driver, `fetch` and `sql`.

The name `on_start` was chosen over `setup`. `setup` is a common test-helper name,
and a helper silently auto-run in production is exactly the silent change this design
avoids.

**MongoDB indexes:** `mongo_index` in `on_start`.

| Situation | Behaviour |
|---|---|
| Identical index exists | no-op |
| Same name, other options | `app.kh:5:5: mongo_index on notes: index b_1 exists with other options; drop it or give this one another name` (code 86, observed) |
| Unique index over existing duplicates | `app.kh:5:5: mongo_index on users: unique index email_1 cannot be built: duplicate values exist` (code 11000 at createIndexes, observed) |

Index keys must be fields of the collection's schema (§6.4, E9).

**ClickHouse DDL:** `ch_query` in `on_start`. The contract is "idempotent DDL":
- `CREATE TABLE IF NOT EXISTS`;
- `ALTER TABLE … ADD COLUMN IF NOT EXISTS`;
- `DROP … IF EXISTS`.

That is enough for both systems:
- MongoDB has no schema;
- ClickHouse schema changes are idempotent DDL.

So **no versioned migration syntax is added**. A one-time data backfill (`INSERT …
SELECT`) does not fit. It is rare in these services and belongs in an explicit admin
route or a later `migration ch N` (deferred; §8.4).

**`DATABASE_MIGRATE=check`** (least privilege at run time). This reuses the
PostgreSQL mode.
- `on_start` runs with DDL statements skipped.
- `mongo_index` only verifies with `listIndexes`. A missing index is an exit:
  `index notes.tags_1 is missing (DATABASE_MIGRATE=check): run ./app migrate`.
- Missing tables are caught by the step-5 `DESCRIBE`.
- `./app migrate` runs migrations and the full `on_start`, then exits.

### 6.4 Collection schema inference (compile time)

There is no declaration syntax. For each collection literal (with its server), the
compiler collects the **document types**:
- the types inserted (or their elements);
- replacement types;
- the `T` of `mongo_find`/`mongo_update`/`mongo_delete`/`mongo_replace` into
  `T`/`T?`/`[T]`;
- the `T` of `db_next` over `mongo_cursor`;
- the struct types used as `$set` values (partial).

Aggregate and command results are not document types.

**Checks, when a collection has at least one document type:**

| Check | Error |
|---|---|
| The same field name with incompatible types across them. Compatible: `int`~`float`, `T`~`T?`. Not compatible: `ObjectId`~`str`, `[T]`~`T`. | E11 `notes.created is int in Note but str in NoteView` |
| A literal filter key, `$set`/`$inc`/`$unset` key, `sort` key, index key or `distinct` field whose first path segment is not a known field. Dotted paths are checked through struct fields. | E9 `notes has no field 'tittle' (Note has _id, title, body, tags, created)`, hint `did you mean 'title'?` |
| The value type of an equality, `$eq/$ne/$gt/$gte/$lt/$lte/$in/$nin` or `$set` against the field's type | E10 `notes._id is ObjectId in Note, but id is str: the filter would match nothing`, hint `declare it as ObjectId: (id: ObjectId)` |
| `$inc` on a non-numeric field | E12 |
| Not-null flags for the guard of §4.1 | — |

This catches the most likely MongoDB silent bug: an `_id` declared `str` in the route
and ObjectId in the type, giving 404 forever. It also catches typos in field names,
without a schema DSL.

**Aggregate output.** If the last shaping stage (`$group`, `$project`, `$addFields`,
followed only by `$sort`/`$limit`/`$skip`) is a literal, its keys must cover the
non-optional fields of `T`:
`CategoryStat.total has no source: the last $group outputs _id, sum, orders`.
Fields with defaults are not filled silently for aggregate results.

### 6.5 Tests

- `khc test` uses `KHRIP_TEST_MONGODB_URI` and `KHRIP_TEST_CLICKHOUSE_URL`.
- It creates a temporary database `khrip_test_<pid>_<rand>` in each, makes it the
  default for unqualified names, runs `on_start` in it, and drops it at the end. This
  mirrors the temporary PostgreSQL schema.
- A dotted name such as `"analytics.events"` would leave the temporary database, so
  it is a test-start error.
- Tests share the databases, as they share `store` and PostgreSQL.

---

## 7. Concurrency and the runtime

### 7.1 `tx` blocks

Driver network calls inside PostgreSQL `tx` stay forbidden: the existing `driver_io`
check, extended to every typed call. The message becomes driver-specific:
`mongo_update inside tx is not part of the PostgreSQL transaction and would run again
on every retry`, hint `call it before or after the tx block`.

Building documents and literals inside `tx` is allowed; they are pure.

### 7.2 MongoDB transactions: not in v1 (argued)

Multi-document transactions need:
- a replica set;
- sessions (`lsid`, `txnNumber`);
- a retry loop over `TransientTransactionError` and `UnknownTransactionCommitResult`.

The retry loop re-runs user code. That is exactly what `tx` does for PostgreSQL, and
a library without closures cannot express "re-run this block". So transactions
**require syntax**. If they are ever added, the least syntax is to reuse `tx` with the
database inferred from the calls inside; mixing PostgreSQL and MongoDB in one block
would be a compile error.

**v1 idiom.** Single-document operations are atomic in MongoDB:
- conditional update: `{"_id": id, "status": "new"}`;
- `$inc` counters;
- `findAndModify` into `T?` to claim one job;
- unique indexes plus `let n: T? = mongo_insert(...)` for idempotency.

KHRIP.md teaches the conditional filter in one line.

**Remaining risk:** two writes in one route are not atomic (§10.4, R3).

### 7.3 Store-lock windows (GC design §6.5/§6.6)

Driver calls release the store lock while they wait, like `fetch`. Each driver has
**exactly one window function**, built on the other team's split between
`__mongo_prepare` (before) and `__mongo_run` (inside):

| Site | Before `__store_release_keep` | Inside the window | After `__store_lock` |
|---|---|---|---|
| `__mongo_window(call)` (mongo.kh) | Encode the command from user values (they may be `store` objects, read under the lock); choose server and pool key; compute the deadline and limits from the permanent configuration and options; frame the bytes. | Pool take, connect/TLS/SCRAM (credentials from permanent memory, `__co_yield` waits with `HELD == 0`), exchange, pool put. The reply buffer is allocated above `hi`. | Classify; decode into fresh arena values; fail if needed. |
| `__ch_window(call)` (db_http.kh) | Query text, URL with parameters, RowBinary payload, auth header, deadline and limits. | Admission (FIFO), exchange. | Classify; decode. |

W1 holds: the window writes only above `hi` and into pool memory. W2 holds: the
window dereferences no `store` object, because the configuration is permanent memory
and user values were encoded before the release. W3 is unchanged: request-end hooks
run before the final release.

GC design updates:
- §6.5 gets these two sites, so five audited sites in all;
- the lint list grows by two;
- the review's two raw `__store_unlock` sites disappear.

`db_next` uses the same windows.

**Lock classification (С10).** Typed driver calls neither read nor write `store`.
They go into `rw.kh`'s store-neutral list. A route that only reads `store` and calls
MongoDB or ClickHouse keeps the shared lock and runs in parallel.

### 7.4 Library writes and cursor lifetime (К1, GC §4.3)

**The library never writes into a user-reachable object.**
- **Results** are fresh arena values.
- **`MongoDoc`** is immutable after it is built.
- **`DbCursor`** is an opaque handle, an index into the coroutine's cursor table:
  - the table is in ctx-local mmap, the other team's `__mongo_cursors()`;
  - it holds the server cursor id, the namespace, the batch size, the budget, and for
    ClickHouse the connection and reader;
  - `db_next(c)` updates the table, never a user struct;
  - the table holds no store pointers, so the GC's eager ctx scan finds nothing in it.

**Compile rules for `DbCursor` (E17):**
- only a `let` local initialised directly by `mongo_cursor` or `ch_cursor`;
- not in `store`, globals, struct fields, lists or maps;
- not a function parameter or result, a route result, or a lambda capture;
- passed only to `db_next`.

So a cursor lives within one function call of one request or task. The request-end
hook kills open MongoDB cursors and closes unfinished ClickHouse streams (other team:
killCursors at request end).

`MongoDoc` is likewise not storable (E18). That removes the К1 class: library-owned
state reachable from `store`.

### 7.5 Cancellation and deadlines

Every call has a deadline: `timeout_ms`, or the `*_TIMEOUT` environment variable.
Server-side limits get the remaining budget (Н12).

On a client-side timeout:
- a read → 503;
- a ClickHouse SELECT also gets a best-effort `KILL QUERY … ASYNC`;
- a write that was sent → 500 `outcome unknown`, never retried.

Khrip does not detect an HTTP client that disconnects; the call finishes within its
deadline. That limitation is the same as for `sql` and `fetch`.

### 7.6 GC compatibility, summarised

| GC concern | How it holds |
|---|---|
| Configuration | Never in `store`. |
| Driver values in `store` | None are storable (`MongoDoc`, `DbCursor`); `DbResult` is plain data. |
| Library writes | Only into fresh values. |
| Windows | Two audited windows. |
| New pointers into arena or store from the ctx table | None. |
| Typed descriptors | `ObjectId` and `Base64` are `str` at run time (brand only in the descriptor), so the GC copier and ptrbits are unaffected. |

---

## 8. Compiler work

### 8.1 What is new

| Piece | Where | Prototype |
|---|---|---|
| Typed library calls: about 16 names; argument kinds; shape from the expected type (`w`) with the `else`/`??` follow-up (as `parse_sql`); descriptors passed; `sql_note_404` for `T` | `src/drivers.kh` `parse_mongo_builtin` (and `parse_ch_builtin`), hook in `atom.kh:parse_builtin` for user files only | done for find, insert, update, delete, aggregate, count |
| Document literal context (D1–D5): `parse_doc_lit` / `parse_doc_arr` / `parse_doc_value`; contexts plain, read filter, write filter, stages, expression | `src/drivers.kh`, hook in `atom.kh:parse_map_lit` when the expected type is `MongoDoc` | done |
| Branded strings `ObjectId` (brand 1) and `Base64` (brand 2): `ty_make(K_STR, brand, 0)`, `ty_name`, `assignable` (brand → `str`), 2-word `str` descriptors `[D_STR, brand]`, JSON decode validation, route path and query parameters (`__param_oid`) | `types.kh`, `decl.kh`, `api.kh`, `lib/api.kh` | ObjectId done (about 30 compiler lines, 12 library lines) |
| ClickHouse query literal: lexer trigger, `lex_sql` dialect flag, `parse_sql` dialect paths (§3.2), sites with `{pN:Type}`, no catalog markers | `lex.kh`, `sql.kh` | not prototyped; server behaviour verified (§3) |
| Option literal check: the argument must be a `MongoOpts`/`ChOpts` literal; per-call field table (§2.4) | `drivers.kh` | type only (literal and field check not done) |
| Collection schema inference and checks (§6.4) | `drivers.kh`; deferred checks at the end of the compile (declaration order does not matter) | no |
| `DbResult` must be checked; `DbCursor` locality; `MongoDoc`/`DbCursor` not in store, JSON or routes; `db_next` linking | `drivers.kh`, `api.kh` (store and global type checks, like `Buf`), `stmt.kh` (local read marks) | no |
| `on_start` hook: signature check; call after `__db_init`, before serving and before tests | `api.kh` generated code | no |
| `driver_io` list extended; driver-specific `tx` message; `rw.kh` store-neutral list | `drivers.kh`, `atom.kh`, `rw.kh` | partly (list exists) |
| Reserved names: user definitions of the about 24 public names → `'mongo_find' is a library function` at the user's declaration, not in lib (С8) | `decl.kh` | no |

### 8.2 Type-inference rules (exact)

1. **R1 (result shape).** For a typed call with expected type `w`:

   | `w` | Shape | Result type |
   |---|---|---|
   | `[T]` | list | `[T]` |
   | `T?` | optional | `T?` |
   | followed by `else` or `??` | optional | `T?` |
   | `DbResult` | explicit | `DbResult` |
   | `int` for a write | count | `int` |
   | `ty_err` / void / none | count for writes; an error for reads (E1) | `int` |
   | anything else | one | `T` |

   For a read, an expected `int` means one scalar row: `let n: int = ch_query("SELECT count() …")`.
   The left operand of `==` has no expected type, so `mongo_delete(…) == 0` is the
   count. The prototype confirms it.
2. **R2 (documents).** In a document position, `{` starts `parse_doc_lit(ctx)`:
   - the context comes from the parameter: filter of a read, filter of a write,
     update, document, keys, pipeline stage;
   - the child context comes from the key: `$match` → read filter, `$expr` → expression,
     stage keys → expression;
   - a non-literal value of type `MongoDoc` is embedded;
   - a struct or `map[str, T]` argument is converted by `__doc_of` (none omitted);
   - any other type is E-doc ("is a {...} document, a struct or a map[str, T]").
3. **R3 (query literal).** The first argument of `ch_query`/`ch_cursor` must be the
   `T_SQL` token in the ClickHouse dialect (E21).
4. **R4 (cursor row type).** `let c = ch_cursor(…)` records the site. Each
   `db_next(c)` with expected type `[T]` sets the site's row type. Two different `T`
   are an error (E19). `db_next` without an expected `[T]` is E1.
5. **R5 (names).** The collection or table argument is a `T_STR` (or `const`) token
   followed by `,` or `)`.

### 8.3 Diagnostics (exact messages; hint on the second line)

Messages marked ✓ are produced verbatim by the prototype (§10.3).

| # | Situation | Message / hint |
|---|---|---|
| E1 ✓ | read without a type | `mongo_find needs to know the result type` / `let note: Note? = mongo_find(...) (one or none), [Note] (all), Note (one, 404 if none)` (likewise `mongo_aggregate`, `ch_query`, `db_next`) |
| E2 | `T` into a route without 404 | `mongo_find into Note answers 404 when no document matches, but route GET "/x" does not list 404` / `add | 404 to the route, or answer yourself: let n: Note = mongo_find(...) else { return 401 }` (the prototype still prints the `sql` wording) |
| E4 ✓ | non-literal collection | `mongo_find takes the collection name as a string literal` / `mongo_find("notes", ...)` (the final version adds `; choose between collections with if/match`) |
| E5 ✓ | non-literal key | `a key of a MongoDB document is a string literal` / `write "name": value` (final: `; for keys known only at run time use a map[str, T]`) |
| E6 ✓ | optional in a write filter | `this value may be none, and in an update or delete filter none would drop the condition and match more documents` / `unwrap it first: let v = x else { return 400 }` |
| E7 ✓ | update without operators | `an update without operators would replace the whole document` / `write {"$set": value}, or use mongo_replace` |
| E8 ✓ | server JavaScript | `$where runs JavaScript on the server and is not allowed` / `use query operators or $expr` |
| E9 | unknown field | `notes has no field 'tittle' (Note has _id, title, body, tags, created)` / `did you mean 'title'?` |
| E10 | value type against field type | `notes._id is ObjectId in Note, but id is str: the filter would match nothing` / `declare it as ObjectId: (id: ObjectId)` |
| E11 | field type conflict | `notes.created is int in Note but str in NoteView` / `a field has one type in a collection` |
| E12 | `$inc` on a non-number | `$inc needs a number, but notes.title is str` |
| E13 | option not applicable | `upsert does not apply to mongo_find` / `mongo_find takes sort, limit, skip, timeout_ms, server` |
| E14 | options not a literal | `options are written in place: MongoOpts { ... }` / `the compiler checks which fields apply to this call` |
| E15 | unchecked `DbResult` | `r holds the outcome of a write and is never checked` / `read r.ok (or r.status) — or drop ": DbResult" to end the request on failure` |
| E16 | `DbResult` on a read | `a failed read ends the request; DbResult is for writes` / `let rows: [T] = ...` |
| E17 | cursor escapes | `a cursor lives in one function: read it here with db_next` |
| E18 | wire value stored or sent | `store 'cache' holds MongoDoc, a MongoDB document in binary form` / `decode it into a type: let n: Note = mongo_find(...)` (also `to_json`, route parameter and result) |
| E19 | two row types | `c is read as [Hit] here and as [Visit] at app.kh:30:16` |
| E20 | ClickHouse habit | `{from:Int64}: the ClickHouse type comes from the Khrip type` / `write {from}; int is sent as Int64` |
| E21 | non-literal query | `ch_query takes the SQL text itself: write the string literal here; {x} inside it is a parameter` / `choose between whole queries with if/match` |
| E22 | NULL comparison | (the `sql` message) `{x} may be none, and a comparison with NULL is never true: rows would silently not match` / `write ({x} IS NULL OR column = {x}), or unwrap it first` |
| E23 | parameter as a name | (the `sql` message) `{t} cannot name a table: values are sent as parameters, never as SQL text` |
| E24 | `ORDER BY {o}` | (the `sql` message) |
| E25 | `FORMAT` | `FORMAT in ch_query: the driver reads the rows itself` / `drop FORMAT ...; the expected type picks the result` |
| E26 | `;` | `ch_query runs one statement` |
| E27 | `?`, `$1` | `? and $1 are not parameters in ch_query` / `write {value}` |
| E28 | optional list parameter | `[str]? cannot be a ClickHouse parameter: arrays are never NULL` / `use [] for none` |
| E29 | bad `ch_insert` rows | `ch_insert takes a list of structs (or one struct), not [int]` |
| E30 | non-literal table | `ch_insert takes the table name as a string literal` |
| E31 | `on_start` signature | `on_start runs once before the server starts: it takes no parameters and returns nothing` |
| E32 ✓ | network inside `tx` | (the prototype prints the existing `driver_io` message) final: `mongo_update inside tx is not part of the PostgreSQL transaction and would run again on every retry` / `call it before or after the tx block` |
| E33 | optional `_id` | `Note._id is str?: a document needs an id` / `use ObjectId? (generated when none) or a non-optional id` |
| E34 | `T?` for a list insert | `a list insert cannot be optional: use DbResult with MongoOpts { ordered: false }` |

### 8.4 What stays library code, and where syntax would be needed

**Library code** (on top of the other team's layer):
- command building, auto-projection, `limit 2` checks, cursor draining;
- `findAndModify` forms;
- BSON encoding with omission, `$literal` and not-null guards;
- decoding with paths;
- error classification;
- environment configuration and named servers;
- the startup sequence, `DESCRIBE` checks, sample retries;
- index creation;
- test databases;
- ClickHouse site execution, parameter encoding, the cursor reader;
- `object_id`, `Base64` conversion.

**Where the library cannot go further, and what it would take:**

| Need | Why a library is not enough | Proposal |
|---|---|---|
| Injection-proof ClickHouse text | `{x}` in a string is interpolation before any library sees it | Lexer trigger on `ch_query(`/`ch_cursor(` plus a string. Equivalent to a keyword. Measured: the keyword `ch \`…\`` saves 1 o200k / 3 Claude tokens per query on P3 (237/246 against 238/249). Not worth a keyword. |
| MongoDB transactions | Re-running user code after a transient error needs a block | Deferred; reuse `tx` if needed (§7.2). |
| Typed streaming `for e in cursor` | `for` has no element annotation; the type would have to come from somewhere | `db_next` loops. A typed `for` (`for e: Event in …`) would be a language-wide change. |
| Named options | Khrip has no named arguments | Option literals with per-call field checks. Named arguments would also make every other function easier; that is a language decision. |
| A time type | BSON Date and TTL, ClickHouse `DateTime64` precision, PostgreSQL timestamptz all want "a time" | A branded `int` (unix ms or s) with ISO JSON, decided once for all three databases. Out of scope here. |
| Versioned ClickHouse data migrations | Idempotent DDL in `on_start` covers schema | `migration ch N` if one-off backfills prove common. |

### 8.5 Cost estimate and risks

**Measured.** The prototype has 396 compiler lines and 581 library lines. It covers
about 60 % of the MongoDB half:
- calls, documents, contexts, `$literal`, the write-filter rule, update operators,
  `$where`;
- ObjectId in types, routes, JSON and BSON;
- fail-closed answers, `T?` duplicates, `RETURNING` inserts, projection.

In the prototype worktree, all 9 `tests/api` and 26 of 28 `tests/run` cases gave the
same output as before. The other 2 differ only because the ad-hoc run compared stderr
together with stdout; main's own compiler shows the same difference.

**Estimate for the whole design:**

| Area | Compiler lines | Library lines |
|---|---|---|
| MongoDB calls not prototyped: replace, distinct, index, command, cursor; option checks; explicit nulls and not-null guard | 350 | 450 |
| Schema inference and aggregate-output check | 400 | — |
| `Base64` | 60 | 120 |
| ClickHouse dialect in `lex.kh`/`sql.kh` | 450 | — |
| ClickHouse site executor | — | 400 |
| `DESCRIBE` verification with sample retries | — | 350 |
| Cursor reader | — | 150 |
| `DbResult`, `DbCursor`, `MongoDoc` rules; `on_start`; reserved names; `rw.kh` | 250 | 100 |
| Startup, environment, named servers, test databases | — | 350 |
| **Total, including the prototype** | **≈ 1 900** | **≈ 2 500** |

`sql.kh` plus `db.kh` are 3 968 lines for PostgreSQL, for comparison.

**Tests:** about 150 cases:
- 35 compile-error fixtures, one per message above;
- 60 runtime cases against real servers: statuses, PATCH, duplicates, `$literal`,
  type mapping per column type, cursors, unknown outcome;
- 25 startup cases: DESCRIBE mismatches, readonly user, index conflicts, missing
  read-only collection;
- 30 codec property cases.

**Sizing.** This is comparable to the v0.12 language work (lang steps A–E).

**Risks:**

| # | Risk | Mitigation |
|---|---|---|
| 1 | The lexer trigger is by name. | Reserved names (E-reserved) make a user `fn ch_query` an error at the user's line. |
| 2 | `DESCRIBE` with sample values can fail for value-dependent reasons. | Retry samples, then a run-time header check, so it is never a false startup failure. A query valid only for some values remains possible but rare. |
| 3 | Schema inference can give false positives on collections shared with other applications. | The fix is to add the field to a type of that collection. Escape hatch: a filter from a `map[str, T]` or `MongoDoc` value is not checked. |
| 4 | The branded `str` touches type checking in many places. | The prototype passed all API tests. Comparisons between `ObjectId` and `str` need a decision (proposed: allowed, compares text). |
| 5 | Hiding the PR's low-level API breaks the PR's tests. | They move to `__` names or are rewritten on the typed surface. |
| 6 | No read fallback. | A service cannot serve a stale cache when MongoDB is down without a new form. Same as `sql` today. |
| 7 | Expression-context detection depends on stage names. | Unknown stages default to expression context, the safe side. |
| 8 | Documents are encoded at run time on every call. | Constant sub-documents can be precomputed at compile time later (optimisation). |

---

## 9. KHRIP.md

This section replaces the current "MongoDB and ClickHouse" paragraph (124 o200k /
138 Claude tokens, no function names, points to the Russian DATABASES.md).

**Measured with `spec_tokens.mjs`:**
- this section: **561 o200k / 567 Claude**, so +437 / +429 net;
- the habits line: +32 / +39;
- KHRIP.md goes from 4 078 to about 4 547 o200k.

For comparison, the PostgreSQL section is 853 o200k. DATABASES.md (rewritten in
English) keeps:
- the full surface of §2;
- `MongoOpts`/`ChOpts` fields;
- the type tables of §4;
- `DbResult` fields;
- cursors, `Base64`, named servers, environment variables;
- the explicit statement that list inserts are not atomic.

The section:

````markdown
## MongoDB and ClickHouse

```khrip
type Note { _id: ObjectId, title: str, tags: [str], views: int = 0 }
fn on_start() {                                // runs once before serving
    mongo_index("notes", {"tags": 1})
}
route GET "/notes/{id}" (id: ObjectId) -> Note | 404 {
    return mongo_find("notes", {"_id": id})     // none → 404
}
let n = mongo_insert("notes", Note { _id: object_id(), title, tags: [] })
let some: [Note] = mongo_find("notes", {"tags": tag, "views": {"$gt": min}},
    MongoOpts { sort: {"views": -1}, limit: 20 })
let total = mongo_count("notes", {"tags": tag})
let changed = mongo_update("notes", {"_id": id}, {"$set": patch, "$inc": {"views": 1}})
let stats: [TagStat] = mongo_aggregate("notes", [{"$unwind": "$tags"},
    {"$group": {"_id": "$tags", "n": {"$sum": 1}}}])
ch_insert("hits", rows)                        // fields → columns
let top: [Hits] = ch_query("SELECT page, count() AS n FROM hits WHERE ts >= {t} GROUP BY page")
```

- `MONGODB_URI` (database in the path) and `CLICKHOUSE_URL` name the servers.
- `{...}` here may mix value types. `none` leaves the field out: `$set` changes
  only the fields sent, a find filter drops the condition (update and delete
  filters may not hold `T?`).
- As with `sql`, the expected type picks the result (`T`: none → 404) and a
  failure ends the request (duplicate 409, server down 503); no type: the count.
  Into `T`/`T?`, `mongo_update`/`mongo_delete` change one document and return
  it, else all matches. `mongo_insert` returns what it stored (into `T?`: none
  on a duplicate). `let r: DbResult = ...` returns `r.ok`, `r.status`, `r.error`.
- `ch_query` is `sql` for ClickHouse; queries and inserts are checked at start.
- `ObjectId` is 24 hex digits in JSON and routes. Not inside `tx`; MongoDB has
  no transactions: put the check into the filter (`{"_id": id, "status": "new"}`).
````

Added to "Habits from other languages":

```markdown
`bson.M{}`, `primitive.NewObjectID()` → `{...}`, `object_id()`; ClickHouse `{x:Int64}` → `{x}`;
```

Also, in the PostgreSQL `tx` bullet, "MongoDB or ClickHouse network operations"
becomes "MongoDB or ClickHouse calls" (a change of about 0 tokens).

---

## 10. Evidence

### 10.1 The programs in this design

All files are in `evidence/`. P1 and P2 compile with the prototype exactly as shown
and were run against MongoDB 8.0 (§10.3). P3 uses the ClickHouse half, which is not
prototyped. Its exact query was run by hand as the compiler would send it
(`{p1:Int64}` …), against a `DateTime`/`UInt64`/`LowCardinality`/`Float32` table on
25.8. `DESCRIBE` gave `LowCardinality(String)`, `UInt64`, `UInt64`, `Float64`, which
match `PageStat` (`str`, `int`, `int`, `float`) under §4.2.

**P1 (`p1_notes.kh`), notes CRUD on MongoDB:**

```khrip
type NoteIn { title: str, body: str, tags: [str] = [] }
type Note { _id: ObjectId, title: str, body: str, tags: [str], created: int }

route POST "/notes" (body: NoteIn) -> 201 Note {
    return 201 mongo_insert("notes", Note { _id: object_id(), created: now(), ...body })
}

route GET "/notes/{id}" (id: ObjectId) -> Note | 404 {
    return mongo_find("notes", {"_id": id})
}

route GET "/notes" (tag: str?, limit: int = 20) -> [Note] {
    return mongo_find("notes", {"tags": tag}, MongoOpts { sort: {"created": -1}, limit })
}

route PUT "/notes/{id}" (id: ObjectId, body: NoteIn) -> Note | 404 {
    return mongo_update("notes", {"_id": id}, {"$set": body})
}

route DELETE "/notes/{id}" (id: ObjectId) -> 204 | 404 {
    if mongo_delete("notes", {"_id": id}) == 0 {
        return 404
    }
    return 204
}
```

**P2 (`p2_orders.kh`), insert, conditional update and aggregation:**

```khrip
type NewOrder { customer: str, category: str, amount: int }
type Order { _id: ObjectId, customer: str, category: str, amount: int, status: str, created: int }
type CategoryStat { _id: str, total: int, orders: int }

route POST "/orders" (body: NewOrder) -> 201 Order | 400 str {
    if body.amount <= 0 {
        return 400 "amount must be positive"
    }
    return 201 mongo_insert("orders", Order { _id: object_id(), status: "new", created: now(), ...body })
}

route POST "/orders/{id}/pay" (id: ObjectId) -> 204 | 404 {
    if mongo_update("orders", {"_id": id, "status": "new"}, {"$set": {"status": "paid"}}) == 0 {
        return 404
    }
    return 204
}

route GET "/stats/categories" (since: int = 0) -> [CategoryStat] {
    return mongo_aggregate("orders", [
        {"$match": {"status": "paid", "created": {"$gte": since}}},
        {"$group": {"_id": "$category", "total": {"$sum": "$amount"}, "orders": {"$sum": 1}}},
        {"$sort": {"total": -1}}
    ])
}
```

**P3 (`p3_events.kh`), ClickHouse batch insert and parameterised aggregation.** The
leading CREATE TABLE comment is the PR program's and is not counted:

```khrip
// CREATE TABLE events (ts Int64, user_id Int64, page String, ms Float64)
//     ENGINE = MergeTree ORDER BY (page, ts)
type EventIn { user_id: int, page: str, ms: float }
type Event { ts: int, user_id: int, page: str, ms: float }
type PageStat { page: str, views: int, users: int, avg_ms: float }
type Inserted { inserted: int }

route POST "/events" (body: [EventIn]) -> 202 Inserted | 400 str {
    if body.len() == 0 || body.len() > 10000 {
        return 400 "send 1..10000 events"
    }
    let t = now()
    return 202 Inserted { inserted: ch_insert("events", body.map(e => Event { ts: t, ...e })) }
}

route GET "/stats/pages" (from: int, to: int, limit: int = 10) -> [PageStat] {
    return ch_query(`SELECT page, count() AS views, uniq(user_id) AS users, avg(ms) AS avg_ms
        FROM events WHERE ts >= {from} AND ts < {to}
        GROUP BY page ORDER BY views DESC LIMIT {limit}`)
}
```

The same program works unchanged on the realistic schema `(ts DateTime, user_id
UInt64, page LowCardinality(String), ms Float32)`:
- the inserts are encoded to those column types;
- `Int64` parameters compare with `DateTime`;
- verified on 25.8.

The PR's `ch_insert` could not write to that schema (В6).

### 10.2 Tokens

Counted with `bench/tokens/count.mjs`, comments removed, as in the review. The PR
API, Go and PostgreSQL counts were recounted from the review's files and match the
review.

| Program | PR API | Go (official drivers) | Khrip + PostgreSQL | **This design** | Go / this | PR / this |
|---|---|---|---|---|---|---|
| P1 notes CRUD | 742 / 775 | 1184 / 1443 | 318 / 324 (with migration); 278 / 282 (without) | **262 / 262** | **4.52 / 5.51** | 2.83 / 2.96 |
| P2 orders | 703 / 772 | 990 / 1188 | — | **296 / 288** | **3.34 / 4.12** | 2.38 / 2.68 |
| P3 events | 424 / 456 | 889 / 1067 | — | **238 / 249** | **3.74 / 4.29** | 1.78 / 1.83 |

**Variants** (same directory):

| Variant | Tokens | Note |
|---|---|---|
| P1 with an index in `on_start` (`p1_notes_index.kh`) | 286 / 289 | Fair against PostgreSQL with its migration: 318 / 324. The prototype has no `mongo_index`, so this file is counted only. |
| P1 in the `RETURNING` style (`p1_notes_returning.kh`): `type Note { _id: ObjectId, ...NewNote }`, `mongo_insert("notes", NewNote {...})` returns a `Note` with the generated `_id` | 256 / 256 | Compiles and runs with the prototype. |
| P3 with `CREATE TABLE IF NOT EXISTS` in `on_start` (`p3_events_setup.kh`) | 287 / 304 | |
| P3 with a `ch` keyword instead of `ch_query(...)` (`p3_events_kwvariant.kh`) | 237 / 246 | The keyword saves 1 / 3. |
| The review's sketches | P1 356 / 352, P3 248 / 257 | |

**Reading the table:**
- Go/Khrip is 3.3–4.5 (o200k) and 4.1–5.5 (Claude) on these programs. The
  PostgreSQL eval tasks give 2.31, and the PR API gave 1.41–2.10.
- MongoDB in this design is at parity with `sql`: 286 against 318 for P1 with
  schema, 262 against 278 without.

**Where the PR API's tokens went, and what replaced them:**

| PR API | This design |
|---|---|
| 6 manual error checks in P1 | fail-closed |
| the cursor drain loop | `[T]` |
| `bson_get_int(r.document, "n")` | the count is the result |
| find after update | `findAndModify` into `T` |
| 25 builder calls in P2 | document literals |
| `fn db()`/`fn ch()` configuration | environment |
| `{"from": from.to_str(), …}` map and `{from:Int64}` | `{from}` |

### 10.3 Prototype runs (real MongoDB 8.0, `THREADS=2`)

**P1:**

| Request | Result |
|---|---|
| POST ×3 | 201 with generated ObjectIds, e.g. `{"_id":"6adb9cfa4f42bff72cfbef00",…}` |
| `GET /notes` | all three |
| `GET /notes?tag=x` | one (the none-dropping filter otherwise) |
| `GET /notes/<id>` | 200 |
| `GET /notes/6adb…efff` | 404 `not found` |
| `GET /notes/not-an-id` | 400 `parameter 'id' must be an ObjectId (24 hex digits), found 'not-an-id'` |
| PUT existing | 200 with the new document (`findAndModify`) |
| PUT missing | 404 |
| DELETE | 204, then 404 |

**P2:**

| Request | Result |
|---|---|
| 4 orders | 201 |
| amount 0 | 400 |
| pay | 204, then 404 (already paid) |
| stats | `[{"_id":"games","total":5000,"orders":1},{"_id":"books","total":2000,"orders":2}]` |
| `since=9999999999` | `[]` |

`$sum: 1` comes back as Int32 and decodes into `int`.

**Semantics (`probe/sem.kh`):**

| Probe | Result |
|---|---|
| Duplicate `_id` | 409 `already exists: sem_notes._id_`; the value only in the log |
| Same insert into `Note?` | none, so the route answered 200 `duplicate, ignored` |
| Body with `"_id":"zz"` | 400 `invalid JSON body: _id: expected an ObjectId (24 hex digits)` |
| Uppercase hex | stored lowercase |
| PATCH `{"title":"t1 new"}` | only `title` changed |
| PATCH `{}` | unchanged document returned |
| `GET /notes` with no `owner` | 2 |
| `owner=bob` | 1 |
| `mongo_count` | 2, then 1 |
| `$literal` probe | leak before the fix (§3.1), `"$secret"` text after |
| Read into a type with a field missing in the data | 500 `internal error`; log `mongodb sem_notes: document 6adb00000000000000000001 does not match Strict: missing BSON field: views` |
| ObjectId field in a body, and a filter by it | round trip correct |
| MongoDB port closed | 503 with `Retry-After: 1`, `database unavailable, try again` |
| Wrong password | 503; log `Authentication failed.` |
| `update` with `{}` (control, PR API) | replaced the whole document (`has a=false has b=false`), which justifies E7 |
| Unique index over two documents without the field | E11000 at `createIndexes` |
| Same index name, other options | code 86 |

**Compile errors (`probe/mistakes.kh`):** E1, E4, E5 (`probe/mistakes2.kh`), E6, E7, E8, E32 and the
404 rule fire with the messages marked ✓ in §8.3.

### 10.4 Where an AI can still make a silent mistake

Silent means: compiles, passes a happy-path test, and is wrong.

| # | Trap | Status |
|---|---|---|
| R1 | **An optional value from a non-request source in a read filter**, e.g. `let u = header("X-User")` and then `{"owner": u}`. A missing header drops the condition and returns everyone's documents. `sql` forces `({x} IS NULL OR …)` for the same mistake. | Open. Mitigation that can be added: an optional value in a read filter must be a route parameter or a field of the route body. A direct call or index expression (`header(…)`, `m[k]`) is an error. It cannot be fully closed without flow analysis. |
| R2 | **`mongo_update`/`mongo_delete` without a type change all matches** (SQL semantics). An AI with `updateOne` habits and a non-unique filter changes many. | Open. Stated in KHRIP.md; uniqueness is not known at compile time. |
| R3 | **Two writes in one route are not atomic** (insert an order, decrement stock). A failure between them leaves partial state. `sql` would demand `tx`. | Open: no MongoDB transactions in v1. The conditional-filter idiom covers state transitions, not multi-document invariants. |
| R4 | **Defaults hide renamed fields.** A field with a Khrip default is filled silently when the stored document lacks it. That is right for schema evolution, wrong if another program renamed the field. | Open. `MONGODB_CHECK=sample` warns at start. Aggregate results are protected (§6.4). |
| R5 | **ClickHouse binary in `str`.** A binary column read into `str` is sent as JSON with U+FFFD replacements. | Open. Declare it `Base64`. |
| R6 | **Lossy declared conversions:** Decimal128 or `Decimal` into `float` rounds; BSON Date into `int` truncates milliseconds; a `Float32` column loses precision. | Open. These are chosen by the declared type, but an AI may not notice. |
| R7 | **Status strings.** `"paid"` and `"payed"` in different routes match nothing. | Avoidable. With `type Status = New \| Paid`, schema inference (E10) turns the typo into a compile error; the enum is stored as its label. Plain `str` remains a trap. |
| R8 | **Case and collation.** `{"email": e}` is case-sensitive, and there is no collation option in v1. | Open, as with `sql`. |
| R9 | **Eventual visibility in ClickHouse.** `ReplacingMergeTree` duplicates until merge; reads right after an `async` insert see the data only after the flush. | Open. These are semantics, not API. |
| R10 | **Time strings without a zone** are taken as UTC by the driver. ClickHouse itself would use the server time zone. | Open. Documented. |

**Closed by this design** (they were silent in the PR API):
- nested `Bson` (В1);
- `none` → null (В2);
- ClickHouse injection (В3);
- ignored write results (В4);
- the first cursor batch lost (В5);
- `ch_insert` type mismatches (В6, now startup errors);
- `batch_size` taken for `limit` and bare booleans (Н2);
- `_id: str` against ObjectId data (E10);
- field-name typos in filters (E9);
- read-only collection name typos (§6.2);
- `$set` with an explicit null on a non-optional field (not-null guard);
- field-path injection in pipelines (D3);
- operator injection from JSON maps (D2);
- `int` cents into `Decimal` (startup error);
- `?limit=0` meaning "all" (`limit: int?`);
- an unchecked `DbResult` (E15).

---

## Appendix: files

All paths are under
`/tmp/claude-0/-home-user-khrip/c69287a0-5c25-565c-bc10-daebb195400d/scratchpad/drvdesign/library-first/`:

| Path | Contents |
|---|---|
| `design.md` | This document. |
| `prototype.diff` | Compiler and library diff against `361c8e9`: `src/types.kh`, `src/decl.kh`, `src/api.kh`, `src/atom.kh`, `src/drivers.kh`, `lib/api.kh`, `lib/bson.kh`. |
| `prototype_mongo_typed.kh` | The prototype library. |
| `evidence/` | `p1_notes.kh`, `p1_notes_returning.kh`, `p1_notes_index.kh`, `p1_pg_no_migration.kh`, `p2_orders.kh`, `p3_events.kh`, `p3_events_setup.kh`, `p3_events_kwvariant.kh`, `khrip_section.md`, `habits_line.md`, `khrip_section_pr.md` |
| `probe/` | `m1.kh` (MongoDB protocol probes), `sem.kh` (semantics), `leak.kh` (`$literal`), `mistakes.kh` and `mistakes2.kh` (diagnostics), `dropdbs.kh` and `listdbs.kh` (cleanup), `run_srv.sh` |

The worktree `drvdesign/wt-libfirst` was removed. The temporary MongoDB databases
(`lf_*`) and ClickHouse databases (`lf_db`, `lf_p3`) were dropped.
