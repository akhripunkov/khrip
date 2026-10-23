# MongoDB and ClickHouse as language forms: design

Label: `language-forms`. Angle: treat both databases the way Khrip treats PostgreSQL. The query language stays the database's own; values are always typed Khrip expressions; results are typed by the expected type; failures end the request with a status; the server checks everything against the real database before it serves.

Scratch and evidence: `/tmp/claude-0/-home-user-khrip/c69287a0-5c25-565c-bc10-daebb195400d/scratchpad/drvdesign/language-forms/` (programs in `ev/`, server probes `chq.sh`, `mprobe.py`, `compiled_mongo.py`, `compiled_ch.py`, `compiled_p4.py`, prompt draft `section.md`, `KHRIP.new.md`, `KHRIP.diff`). Nothing in `/home/user/khrip` was modified. The worktree `wt-lf` was used only to build `khc` for probes and is removed.

This design sits on top of the low-level layer that another team is fixing now (BSON validated once, numeric widening, UTF-8 at `str` conversion, `object_id`, killCursors at request end, URI options, cached DESCRIBE and ClickHouse column plans, FIFO admission, literal-only `ch_query`, TLS, drivers linked only when used). §8.4 lists exactly what it needs from that layer.

---

## 0. Decisions

| # | Decision |
|---|---|
| D1 | **ClickHouse is `ch "..."` / `` ch `...` ``**, lexed and compiled by the `sql` machinery with a ClickHouse dialect. `{expr}` is always a server-side parameter `{pN:Type}` whose type comes from the Khrip type. The expected type picks the result (`[T]`, `T?`, `T` with 404). `INSERT INTO t {rows}` encodes the rows to the table's real column types. Every `ch` is checked at start (`DESCRIBE` / `EXPLAIN AST`). `migration ch N` runs DDL once. |
| D2 | **MongoDB is `db.<collection>.<method>(...)` over declared collections.** `collection notes: Note` declares a collection holding `Note` documents (plus its indexes and storage hints). The methods, operators and `{key: value}` documents are MongoDB's own (mongosh spelling: `findOne`, `$set`, `"$field"`), written directly in Khrip code, not in a string. Values in documents are Khrip expressions encoded as typed BSON. |
| D3 | **Mongo documents are typed at compile time against the collection type**: field names, dotted paths, `"$field"` references, operators and value types. `{_id: id}` with `id: str` against `_id: ObjectId` is a compile error, not a silent "no match". |
| D4 | **none.** A none value is never stored: inserted documents leave it out, `$set` keeps the old value (a JSON `null` in the request body, or the literal `none`, removes the field). In a filter an optional value is a compile error; `x?` skips the condition when x is none, and is allowed only in read-many operations (`find`, `countDocuments`, `distinct`, `aggregate`). |
| D5 | **Results follow `sql`.** `find`/`aggregate` give `[T]`, `T?` (more than one is an error) or `T` (none → 404); `findOne`/`findOneAnd*` give `T?` or `T`; `insertOne` gives the stored document with its `_id` (into `T?`: none on a duplicate key, like `ON CONFLICT DO NOTHING`); updates and deletes give a count. The projection is derived from the result type. `findOneAndUpdate` returns the new version unless `{returnDocument: "before"}`. |
| D6 | **Fail-closed, one convention for all three forms** (`sql`, `ch`, `db`): duplicate key 409, rejected value 400, database unavailable 503 (`Retry-After: 1`), write whose outcome is unknown 500, anything else 500. `<form> else e { ... }` handles a failure explicitly with `e: DbError { status, code, message, unknown_outcome, written }`. No result struct can be ignored, because the forms do not return one. |
| D7 | **`ObjectId`** is a builtin nominal type represented as a 24-character lowercase hex `str`. It is a hex string in JSON, paths, store and KHRIP_DATA; BSON ObjectId on the wire. `object_id()` makes one, `parse_object_id(s) -> ObjectId?` checks one. `_id` is an ordinary field name: no `id`↔`_id` renaming. |
| D8 | **Configuration is environment only**: `MONGODB_URI` (must name the database), `CLICKHOUSE_URL`, the existing `DATABASE_TIMEOUT`, `DATABASE_MIGRATE`, plus a few documented knobs. No client values in code. |
| D9 | **Startup verification**: ClickHouse migrations, then `DESCRIBE` of every `ch` result and `INSERT` target against the Khrip types; MongoDB authentication, declared indexes (created, or checked with `DATABASE_MIGRATE=check`), and a `$sample` of each collection's BSON types against the declared Khrip types. Any mismatch stops the server with a precise message, like `sql`. |
| D10 | **No MongoDB or ClickHouse operation inside `tx`** (direct or through functions). MongoDB transactions are not offered in this version; single-document atomic operations, `findOneAndUpdate` with conditions, unique indexes and `T?` cover the API patterns. |
| D11 | **Binary data (С11)**: BSON Binary is a base64 `str` in Khrip, both ways. No raw binary reaches user strings through the forms. ClickHouse `String` stays raw bytes, like PostgreSQL `bytea` and fetch bodies (v0.13-utf8 D9). |
| D12 | **Runtime**: no cursor values in user code (`for x in db.c.find(...)` streams batches with a hidden cursor); the store lock is released only inside one audited exchange per driver, with the request bytes built before the release; forms never write into user objects; startup data lives in permanent memory. |
| D13 | **Prompt**: one section "MongoDB and ClickHouse" of **613 o200k / 627 Claude tokens** replaces the PR paragraph. KHRIP.md goes from 4,078 to 4,610 o200k (+532) and from 4,265 to 4,800 Claude (+535). |
| D14 | **Evidence**: P1/P2/P3 are 241/268/235 o200k tokens (PR API: 742/703/424; Go: 1,184/990/889; PostgreSQL P1: 318). Go/Khrip is 4.1 over the three (o200k), 4.8 (Claude). Every compiled command was run against MongoDB 8.0.34 and ClickHouse 25.8.33. |

---

## 1. Surface

### 1.1 What the AI sees

| Kind | Name | Signature / form |
|---|---|---|
| declaration | `collection` | `collection NAME: T [in "database"] [{ ITEM* }]` |
| collection item | `index` | `index {key: 1 \| -1 \| "text" \| "2dsphere", ...} [{option: value, ...}]` |
| collection item | storage hints | `date f, g` · `binary f` · `uuid f` · `decimal f` (paths of T) |
| expression | `db` form | `db.NAME.METHOD(args)[.CHAIN(arg)]*` (§1.2) |
| expression | `ch` form | `ch "..."`, `` ch `...` `` (§1.3) |
| declaration | `migration ch` | `migration ch N "..."` / `` migration ch N `...` `` |
| statement suffix | `else e` | `let x = FORM else e { ... }`, `FORM else e { ... }` (§1.4) |
| type | `ObjectId` | nominal; `==`, `<`, interpolation, `to_str()`, map key, route parameter |
| type | `DbError` | `{ status: int, code: str, message: str, unknown_outcome: bool, written: int }` |
| function | `object_id` | `object_id() -> ObjectId` |
| function | `parse_object_id` | `parse_object_id(s: str) -> ObjectId?` |

Everything else (`Mongo`, `MongoResult`, `mongo_*`, `Bson`, `bson_*`, `ChConfig`, `ChResult`, `ch_query`, `ch_insert`, `ch_cancel`, ...) stays library code for advanced use, documented only in DATABASES.md, and is linked only when a program names it.

### 1.2 MongoDB

#### Declarations

```khrip
type Link { _id: ObjectId, slug: str, url: str, clicks: int = 0, created: int, expires: int? }

collection links: Link {
    date created, expires                        // BSON Date; Khrip int seconds (or ISO str)
    index {slug: 1} {unique: true}
    index {expires: 1} {expireAfterSeconds: 0}   // TTL needs a date field
}
collection audit: AuditEntry in "audit"           // same cluster, another database
```

- `T` must be a struct. Fields may be scalars, `ObjectId`, lists, structs, `map[str, V]`, enums and sum types (encoded as today: an enum is its name as a string; a variant with fields is `{type: "Circle", r: 2}`).
- The collection name is the Khrip name. The database is the path of `MONGODB_URI` unless `in "db"` is given.
- `index KEYS [OPTIONS]`: `KEYS` and `OPTIONS` are document literals with MongoDB's spelling. Keys are checked against T. Options are checked against the `createIndexes` option table (`unique`, `sparse`, `expireAfterSeconds`, `partialFilterExpression` (a typed filter), `name`, `collation`, `hidden`, `weights`, `default_language`). An index without `name` gets MongoDB's default name (`slug_1`, `customer_1_created_-1`).
- Storage hints change the BSON type of a field everywhere: in writes, in filters, in sorts and in reads.
  - `date f`: `int` (unix seconds) or `str` (ISO 8601) ↔ BSON Date.
  - `binary f`: `str` (standard base64) ↔ BSON Binary subtype 0.
  - `uuid f`: `str` (canonical 8-4-4-4-12 text) ↔ BSON Binary subtype 4.
  - `decimal f`: `str` (exact decimal text) or `float` ↔ Decimal128.
- A `T` may be used by several collections. A collection is never a value: it cannot be passed, stored or returned.

#### Methods

`T` is the collection's type. `R` is the expected type (annotation, route result for the status, function result, struct field, `else`/`??` follow-up), defaulting as shown. For every read except `aggregate`, `R` must be a struct whose fields are fields of `T` with compatible types; the projection sent to the server is exactly `R`'s fields (`_id: 0` when R has no `_id`).

| Method | Arguments | Value |
|---|---|---|
| `find(filter)` | chains: `.sort(doc)`, `.skip(int)`, `.limit(int)`, `.maxTimeMS(int)`, `.hint(doc)`, `.collation(doc)`, `.allowDiskUse(bool)` | `[R]` (default `[T]`), `R?` (more than one document: 500), `R` (none: 404) |
| `findOne(filter)` | chains as `find` except `.limit` | `R?` (default `T?`), `R` (none: 404) |
| `countDocuments(filter[, {limit, skip, hint, maxTimeMS}])` | | `int` |
| `estimatedDocumentCount()` | | `int` |
| `distinct("path"[, filter])` | | `[F]`, F = the field's type (element type for a list); null and missing are left out |
| `aggregate([stage, ...][, {allowDiskUse, maxTimeMS, hint, collation}])` | | `[R]`, `R?`, `R`; R required (no default); a scalar R reads the only non-`_id` field |
| `insertOne(doc)` | doc: document literal or a value whose type fits T | `R` (default `T`): the stored document with its `_id`; `R?`: none on a duplicate key |
| `insertMany([doc, ...][, {ordered: bool}])` | | `[R]` (default `[T]`); `[R?]`: none at duplicates (needs `ordered: false`) |
| `updateOne(filter, update[, {upsert, arrayFilters, hint, collation}])` | update: operators or a pipeline | `int`: matched, plus 1 when an upsert inserted |
| `updateMany(filter, update[, same])` | | `int` |
| `replaceOne(filter, doc[, {upsert, hint, collation}])` | | `int` |
| `deleteOne(filter[, {hint, collation}])`, `deleteMany(...)` | | `int`: deleted |
| `findOneAndUpdate(filter, update[, {returnDocument, upsert, sort, arrayFilters, maxTimeMS}])` | | `R?` (default `T?`), `R` (none: 404); the new version unless `returnDocument: "before"` |
| `findOneAndReplace(filter, doc[, same])` | | as above |
| `findOneAndDelete(filter[, {sort, maxTimeMS}])` | | the deleted document: `R?`, `R` |
| `for x in db.c.find(...) { }` | | iterates batch by batch (§7.3) |

Not offered as forms: `createIndex` (declare it), `bulkWrite`, `watch`, `drop`, GridFS, sessions. They stay in the library.

#### Document literals

```
doc     = "{" [ entry { "," entry } [ "," ] ] "}"            newlines allowed
entry   = key ":" value
        | IDENT                                               shorthand: {slug} is {slug: slug}
        | "..." expr                                          spread of a struct (writes only)
key     = IDENT | DOLLAR_IDENT | STRING | IDENT { "." IDENT }   "a.b" and a.b are both a path
value   = doc | array | expr [ "?" ] | if/match whose branches are docs
array   = "[" [ value { "," value } [ "," ] ] "]"
DOLLAR_IDENT = "$" ident-chars                                new token; today "$" is a lexer error
```

- Inside `db` arguments a `{` always starts a document, and a bare key is a field name. Outside them Khrip is unchanged: `{name: 1}` is still a map whose key is the variable `name`.
- Values are Khrip expressions. A struct value is a subdocument, a list an array, a map a document, an enum its name.
- String values are strings. `"$amount"` is a field reference only in aggregation-expression positions (§1.2 typing).
- `if`/`match` whose every branch is a document literal compiles to variants, like `ORDER BY {o}` (at most 16).

#### Typing rules

**Paths.** A key path is resolved in T: through struct fields, through lists (implicitly, as MongoDB does), through `map[str, V]` (any segment), and `$`, `$[]`, `$[id]` segments in updates (list elements).

**Filters** (`find`, `findOne`, `countDocuments`, `distinct`, `$match`, `update*`/`replace*`/`delete*`/`findOneAnd*`, `partialFilterExpression`):

- Top-level keys are paths, `$and`/`$or`/`$nor` (arrays of filters), `$expr` (aggregation expression), `$text` (`{$search: str, ...}`) or `$comment`. `$where` is an error (D-M15).
- `path: value`, where the path has type F (and element type E if F is a list):
  - an expression of type F, of type E (array contains), or `[E]` (exact array);
  - `none` (matches null or missing; F must be optional);
  - `x?` where x is `F?` or `E?`: the key is dropped when x is none (read-many operations only);
  - an operator document. All keys must be operators: `$eq $ne` (F/E), `$gt $gte $lt $lte` (F/E; ordered types), `$in $nin` (`[F]`/`[E]`), `$exists` (bool), `$type` (str), `$regex` (F is str; §2.3), `$options` (string literal; dropped with its `$regex`), `$size` (int, F a list), `$all` (`[E]`), `$elemMatch` (a filter on E), `$not` (an operator document), `$mod` (`[int]`). Geo operators are accepted with unchecked values.
  - A document literal without operators for a struct field is an error (D-M31): MongoDB would compare the whole subdocument, field order included. Write `"address.city": c`, or pass a struct value to compare whole documents.
- `int` and `float` compare with each other. `ObjectId` compares only with `ObjectId`. An enum field takes values of that enum.
- An optional value without `?` is an error (D-M5), and so is `?` in `findOne`, update, replace, delete and `findOneAnd*` filters (D-M6).
- When dropping leaves an operator document empty, its key is dropped too, recursively. An `$and`/`$or`/`$nor` element that becomes `{}` is removed; an emptied `$or` makes the whole `$or` true.

**Updates** (`updateOne`, `updateMany`, `findOneAndUpdate`):

- Every top-level key must be an update operator: `$set $setOnInsert $unset $inc $mul $min $max $push $addToSet $pull $pullAll $pop $currentDate`. A plain document is an error (D-M8), because MongoDB would replace the whole document. An array argument is an update pipeline (`$set $unset $addFields $project $replaceWith $replaceRoot` stages, field references checked).
- `$set`, `$setOnInsert`: a document of `path: value` (value of F) or a struct value whose fields are fields of T. `_id` cannot be set (D-M13).
- `$unset`: `{path: 1 | "" | true}`; the path must be optional or have a default in T (D-M10).
- `$inc`, `$mul`: int or float fields. `$min`, `$max`: F. `$push`, `$addToSet`: list fields, value E or `{$each: [E], $sort, $slice, $position}`. `$pull`: E or a filter on E. `$pullAll`: `[E]`. `$pop`: `1` or `-1`. `$currentDate`: `date` fields only. `$rename` is an error (it changes the schema; D-M32).
- Upsert (`{upsert: true}`): the inserted document is the filter's equality fields plus `$set` plus `$setOnInsert`; every required field of T must be among them (D-M18).

**Inserted and replaced documents**: the fields must be fields of T with compatible types. Every required field of T (not optional, no default) must be present, except `_id: ObjectId`, which is generated. A missing `_id` of any other type is an error (D-M17).

**Sort**: keys are paths; values are the literals `1` or `-1`, or `{$meta: "textScore"}`.

**Aggregation**: stage names are checked against the MongoDB 8.0 list. String values starting with one `$` in expression positions (`$group`, `$project`, `$addFields`/`$set`, `$unwind`, `$sortByCount`, `$bucket` `groupBy`, `$expr`, `$lookup` `localField`) are checked against the current shape. The shape starts as T. `$match`, `$sort`, `$limit`, `$skip`, `$sample` and `$unwind` keep it (`$unwind` makes the path its element type). `$addFields`/`$set` and `$lookup` add fields of unknown type. `$group`, `$project`, `$replaceRoot`, `$replaceWith`, `$count`, `$bucket`, `$facet` and `$sortByCount` end checking for later stages. `$lookup` `from` must name a declared collection (D-M30). `$out` and `$merge` mark the operation as a write. Expression operator names (`$sum`, `$cond`, ...) are checked against the 8.0 list; their arguments are not typed.

**Options documents** are checked per method (the tables above); an unknown option is an error with "did you mean". `writeConcern` with `w: 0` is an error.

### 1.3 ClickHouse

```khrip
migration ch 1 `CREATE TABLE events (ts DateTime, user_id UInt64, page LowCardinality(String),
    ms Float32) ENGINE = MergeTree ORDER BY (page, ts)`

let top: [PageStat] = ch `SELECT page, count() AS views, uniq(user_id) AS users
    FROM events WHERE ts >= {from} AND page IN ({pages}) GROUP BY page
    ORDER BY views DESC LIMIT {n}`
let total: int = ch "SELECT count() FROM events WHERE user_id = {uid}"
let written = ch "INSERT INTO events {rows}"                      // rows: [Event] or Event
ch "INSERT INTO events {rows} SETTINGS async_insert = 1"           // server-side batching, waits
ch "ALTER TABLE events DELETE WHERE ts < {cutoff}"                 // waits for the mutation
```

| Form | Value |
|---|---|
| a SELECT-like statement (`SELECT`, `WITH`, `SHOW`, `DESCRIBE`, `EXPLAIN`) | expected `[T]`, `T?` (more than one row: 500) or `T` (none: 404); no expected type is an error (D-C2). T is a struct (columns by name) or one column's type. |
| `INSERT INTO t {rows}` | `int`, rows written (`X-ClickHouse-Summary` `written_rows`) |
| any other statement (DDL, `ALTER`, `DELETE FROM`, `OPTIMIZE`, `INSERT ... SELECT`, `TRUNCATE`) | `int`, `written_rows` (0 when nothing is written) |

- `{expr}` follows every `sql` rule: always a parameter; `IN ({list})` takes a list (ClickHouse accepts `x IN ({p:Array(T)})` as it is, so there is no rewrite); `'%{q}%'` matches q literally (escaped for `LIKE`); `{x} IS NULL` becomes a Bool parameter; a comparison with an optional value without the `IS NULL` guard is an error; `ORDER BY {o}` takes values made of string literals; a parameter in a table-name position is an error.
- `INSERT INTO t {rows}`: the fields of the struct are the columns, by name. The statement becomes `INSERT INTO t (c1, ..., cn) [SETTINGS ...] FORMAT RowBinary` with the rows encoded to the real column types by the startup plan (§3.3). `none` is NULL for a `Nullable` column and the column's DEFAULT otherwise. An empty list sends nothing and gives 0.
- `SETTINGS` written in the text is how per-statement tuning is done (`max_execution_time`, `async_insert`, `max_threads`). `wait_for_async_insert = 0` is an error (D-C4). For `ALTER TABLE ... UPDATE|DELETE` the runtime adds `mutations_sync = 1`, so a following read sees the change.
- `FORMAT ...` in a SELECT is an error (D-C7): the runtime reads `RowBinaryWithNamesAndTypes` itself.
- `migration ch N`: run once, in order, at start (or by `./app migrate`), recorded in `khrip_migrations` in the ClickHouse database with the text's sha256. An edited migration that already ran stops the server. ClickHouse runs one statement per HTTP request, so a migration's statements are split by the `ch` lexer (aware of quotes and comments) and sent in order. If statement k of n fails, the error says which ones ran; write `IF NOT EXISTS`.
- Query ids are `khrip-<random>`. The runtime sends `log_comment = "file.kh:line:col"`, so `system.query_log` shows where a query comes from. On a client-side timeout it sends `KILL QUERY WHERE query_id = ... ASYNC` once, without waiting. User-level cancellation is library code (`ch_cancel`).

### 1.4 Explicit failure handling (all three forms)

```khrip
ch "INSERT INTO clicks {click}" else e {
    eprint("click not logged: {e.message}")      // a statement form may fall through
}
let link: Link = db.links.insertOne(doc) else e {
    if e.status == 409 {
        return 409 "slug is taken"
    }
    fail(e.status, e.message)
}
let t = tx { ... } else e { ... }                 // the whole transaction, after its retries
```

- `else NAME { ... }` after a `sql`, `ch` or `db` form, or a `tx` block, runs when the operation fails. It also runs on "no row/document" for a `T` shape, with `status == 404`.
- After `let`, the block must leave the scope, like today's `else`. After a statement form it may fall through.
- `e: DbError`:
  - `status`: what the request would have answered;
  - `code`: the database's code as text (`"23505"`, `"11000"`, `"241"`; `""` for transport failures);
  - `message`: the text the response would have carried;
  - `unknown_outcome`: a write may have been applied;
  - `written`: documents or rows known to be written before the failure (`insertMany`; otherwise 0).
- Plain `else { }` (without a name) keeps today's meaning: no row/document only. For `insertOne` that means a duplicate key, as for `INSERT ... ON CONFLICT DO NOTHING`.
- `else e` is not allowed inside `tx` on a `sql` statement: there a failed statement rolls the block back (D-E2).

---

## 2. Parameters and injection

### 2.1 Where values can go

| Form | Values enter as | Query text from values | Injection expressible? |
|---|---|---|---|
| `sql` | PG parameters `$n` (unchanged) | never | no |
| `ch` | ClickHouse parameters `{pN:Type}`, sent as `param_pN=` in the URL, escaped by the low-level `__ch_param`; INSERT rows as a RowBinary body | never (`ORDER BY {o}` picks one of the compiled literal texts) | no |
| `db` | BSON values inside a document whose keys and operators are compile-time constants | never: keys, `$operators` and field references come only from source literals | no |
| library `ch_query`/`ch_query_params` | the query must be a literal without interpolation or a `const` (low-level stopgap, В3) | no | no |

- In a `db` document, a value can never become an operator. A user string `"$gt"` is a BSON string; a Khrip `map[str, V]` can only be a value of a `map` field (D-M33). Keys are never computed.
- `$where`, `$function` and `$accumulator` (server-side JavaScript) are compile errors.
- MongoDB has no SQL-style text; the remaining "injection" surface is regular expressions. §2.3 closes it.
- The `ch` text is the source literal; the compiler adds only parameter placeholders, column lists and settings it generates itself.

### 2.2 ClickHouse parameter types from Khrip types

| Khrip type of `{expr}` | Parameter type | Notes |
|---|---|---|
| `int` | `Int64` | compares with every integer column, `DateTime` and `DateTime64` (as unix seconds); **not** with `Date`: that is a startup error (`Illegal types of arguments (Date, Int64)`) whose hint says `toDate({x})` or a `str` |
| `float` | `Float64` | compares with `Float32`/`Decimal` |
| `bool` | `Bool` | |
| `str` | `String` | compares with `String`, `LowCardinality`, `FixedString`, `Enum` (by name), `UUID` and `Date` (`'2026-10-19'`). Against `DateTime` ClickHouse parses only `'YYYY-MM-DD hh:mm:ss'`, not `time_iso`; the startup check prints a hint when it sees this (§6.2) |
| enum `type K = A \| B` | `String` (the name) | compares with `Enum8/16` and `String` |
| `ObjectId` | `String` (hex) | |
| `T?` | `Nullable(T')` | only behind `{x} IS NULL OR ...`; otherwise an error, as in `sql` |
| `[T]` | `Array(T')` | `x IN ({xs})`, `has({xs}, x)` |
| struct, `[struct]` | — | only in `INSERT INTO t {rows}` |
| map | `Map(String, V')` | |

Measured on ClickHouse 25.8:
- `ts >= {p:Int64}` against `DateTime` and `DateTime64(3)` works;
- `uid IN {p:Array(Int64)}` and `IN ({p:Array(Int64)})` work;
- `LIMIT {p:Int64}` works, and a negative value gives `INVALID_LIMIT_EXPRESSION`, mapped to 400;
- `kind = {p:String}` against `Enum8` works;
- `'%' || {p:String} || '%'` works with LIKE;
- the injection string `x' OR 1=1 OR page='` as a parameter matched 0 rows.

### 2.3 Regular expressions (`$regex`)

- The pattern is the **source literal**. Values interpolated in it, and a value given as a plain variable, match **literally**: the runtime escapes regex metacharacters, like `'%{q}%'` in `sql`.
  - `{title: {$regex: "^{q}", $options: "i"}}`: titles starting with q, case-insensitive.
  - `{slug: {$regex: q}}` and `{slug: {$regex: q?}}`: slugs containing q.
- Any other expression (`"^" + q`, a function call) is an error (D-M24). This removes the silent `"^" + q` → `\^...` trap.
- User-supplied patterns therefore cannot be expressed, and ReDoS from user input is impossible. Measured: with `q = "."` the escaped regex matched only `c.d`, the raw one both slugs; `(a+)+$` escaped matched nothing at once.

---

## 3. Types and mapping

### 3.1 MongoDB (BSON)

| Khrip | Written as | Read from (widening, otherwise a decode error) |
|---|---|---|
| `int` | Int64 | Int32, Int64; Double if integral and in range; Decimal128 if integral |
| `float` | Double | Double, Int32, Int64, Decimal128 (rounded) |
| `bool` | Boolean | Boolean |
| `str` | String (valid UTF-8, else 400) | String (UTF-8 checked, field path in the error) |
| `str` with `binary f` | Binary 0 from base64 (bad base64: 400) | Binary (any subtype) → base64 |
| `str` with `uuid f` | Binary 4 from canonical text | Binary 4 → canonical text |
| `int` / `str` with `date f` | Date (seconds × 1000) / Date from ISO 8601 (`parse_time`) | Date → seconds (floor) / ISO `2026-10-19T15:04:05Z` (with `.123` when the ms are not zero) |
| `int` / `str` without `date` | Int64 / String | **also** Date (lenient read, so aggregate results with dates decode); the startup sample reports a Date in a collection field without `date` (§6.1) |
| `str` / `float` with `decimal f` | Decimal128 (exact text / nearest) | Decimal128 |
| `ObjectId` | ObjectId | ObjectId only (a String `_id` is a decode error, so a filter can never silently miss) |
| `T?` | left out when none (§3.4) | missing or null → none |
| `[T]` | Array | Array |
| struct | Document (field order = declaration order) | Document; unknown fields ignored; missing field → default if declared, none if optional, else decode error |
| `map[str, V]` | Document | Document |
| enum | String (name) | String (unknown name: decode error) |
| variant with fields | `{type: "Name", ...}` | same |

- Decimal values are read-only without `decimal f`: money stays `int` cents, as KHRIP.md says.
- A decode error is a 500 (a program or data error). The log names the collection, the `_id`, the field path and the BSON type found; the response body says only `internal error`.

### 3.2 ClickHouse reads (result columns → Khrip, checked at start)

| ClickHouse | Khrip |
|---|---|
| Int8–Int64, UInt8–UInt32 | `int` |
| UInt64 | `int` (a value ≥ 2^63 at run time: 500; `count()`, `uniq()` are UInt64) |
| Int128/256, UInt128/256 | `str` (decimal text) |
| Float32, Float64 | `float` |
| Decimal(P, S) | `float`, `str` (exact text), `int` if S = 0 |
| Bool | `bool` |
| String, FixedString(N), LowCardinality(String) | `str` (raw bytes; FixedString keeps its trailing NULs) |
| Enum8/16 | `str`, or a Khrip enum whose variant names cover the enum's names (checked at start) |
| UUID, IPv4, IPv6 | `str` |
| Date, Date32 | `int` (unix seconds at 00:00 UTC) or `str` (`2026-10-19`) |
| DateTime | `int` (unix seconds) or `str` (`time_iso` format) |
| DateTime64(p) | `str` (ISO with p digits); `int` only when p = 0, otherwise a startup error (D-S6) |
| Nullable(T) | `T?`; into a non-optional field: startup error, as in `sql` |
| Array(T) | `[T]` |
| Map(String, T) | `map[str, T]` |
| named Tuple | struct |
| JSON, Dynamic, Variant, Object, AggregateFunction | startup error; hint: convert in SQL (`toString(x)`, `finalizeAggregation`) |

Columns are matched to fields by name, exactly first, then ignoring case, as in `__db_check`. Extra columns are ignored. A field without a column must be optional or have a default.

### 3.3 ClickHouse writes (`INSERT INTO t {rows}`, plan from `DESCRIBE TABLE` at start)

| Khrip field | Column types it may fill | Run-time check (failure: 400 `bad value: t.c ...`) |
|---|---|---|
| `int` | every integer type; DateTime (seconds); DateTime64(p) (× 10^p); Date/Date32 (seconds → days, floor); Decimal(P, S) (× 10^S); Bool (0/1) | range of the column type |
| `float` | Float32, Float64, Decimal (rounded half-even to S) | finite for Decimal, precision P |
| `bool` | Bool, UInt8 | — |
| `str` | String, LowCardinality(String), FixedString(N), Enum (name), UUID, IPv4/IPv6, Date (`YYYY-MM-DD`), DateTime/DateTime64 (ISO 8601 via `parse_time`), Decimal (exact text) | length ≤ N, known enum name, valid UUID/IP/date/time/decimal |
| enum | Enum8/16 (names checked at start), String | — |
| `ObjectId` | String, FixedString(24) | — |
| `T?` | Nullable(T') (none → NULL); a non-Nullable column with a DEFAULT (none → DEFAULT) | a non-Nullable column without DEFAULT: startup error (D-S4) |
| `[T]` | Array(T') | elementwise |
| `map[str, V]` | Map(String, V') | — |

- A column not in the struct must be Nullable or have `DEFAULT`, `MATERIALIZED`, `ALIAS` or `EPHEMERAL`. Otherwise the server does not start (D-S3): ClickHouse would silently write 0, `''` or 1970-01-01.
- A struct field that is a `MATERIALIZED` or `ALIAS` column is a startup error.
- The encoding is the low-level team's column plan. This design fixes only the rules above.
- Measured: `INSERT ... VALUES` with `-1` into `UInt32` stored 4,294,967,295 silently. The plan's range check turns that into a 400.

### 3.4 none and null

| Where | none from an expression (`T?`) | literal `none` | explicit JSON `null` in the request body |
|---|---|---|---|
| `insertOne`/`insertMany`/`replaceOne` document | field left out | field left out | field left out |
| `$set` / `$setOnInsert` | field unchanged | field removed (`$unset`) | field removed (`$unset`); a non-optional target field: 400 `title cannot be null` |
| filter value | compile error unless `x?` (key dropped) | matches null or missing | — (a body field in a filter is an ordinary `T?`) |
| `ch` / `sql` parameter | NULL (behind the `IS NULL` guard) | NULL | — |
| ClickHouse insert | NULL (Nullable) or DEFAULT | same | — |
| PostgreSQL `SET {patch}` (today, unchanged) | field not sent: column unchanged | — | NULL |

- Khrip never writes BSON null. Reads treat null and missing alike (none, or the default).
- This keeps the KHRIP.md PATCH idiom: `{$set: patch}` changes only the fields the client sent, exactly like `UPDATE ... SET {patch}` and `{...old, ...patch}`.
- The JSON-null tracking is the existing `CTX_JNULLS`/`PK_GIVEN` mechanism for the top-level fields of a route body.
- Measured: with `none` written as null (the PR's rule), `$set: patch` erased the fields the client did not send (review В2). A filter that dropped a none condition would turn `deleteMany({customer: c})` into "delete all": `count {}` gave 3 of 3. That is why `?` is explicit and limited to read-many operations.

### 3.5 ObjectId

- **Representation.** At run time an `ObjectId` is a `str`: 24 lowercase hex digits. The JSON encoder, store, KHRIP_DATA, `__deep_copy`, the GC copier and interpolation all treat it as a string. The type checker keeps it distinct: `str` and `ObjectId` do not convert implicitly.
- **Boundaries.**
  - JSON input and route/query parameters accept 24 hex digits in either case and normalise them to lowercase. Anything else gives 400 `parameter 'id' is not an ObjectId` or `body.owner: not an ObjectId`.
  - BSON type 0x07 is 12 bytes ↔ hex.
  - ClickHouse and PostgreSQL see a `String`/`text` parameter. Reading a text column into `ObjectId` validates it (500 on bad data).
- **`object_id()`.** 4-byte big-endian seconds, 5 random bytes chosen once per process, and a 3-byte counter shared by all threads (`lock xadd`, random start). This is the BSON spec, so the ids sort by creation time.
- **`parse_object_id(s)`.** `ObjectId?`: none unless s is 24 hex digits.
- **Operations.** `==`, `!=`, `<` (time order), `to_str()`, interpolation, map key (`map[ObjectId, V]`), `sort_by` key.
- **`_id`.** An ordinary field. A collection type without `_id` reads and writes without it (documents still get a server-side id), but `{_id: ...}` filters are then an error (D-M3). No `id`↔`_id` renaming: one name in Khrip, JSON and MongoDB.

### 3.6 Dates and time

- Khrip time stays `int` unix seconds (`now()`) or ISO `str`, as for PostgreSQL `timestamptz`.
- In MongoDB, `date f` makes the field a BSON Date in writes, filters (`{expires: {$lt: now()}}` sends a Date) and sorts. This removes the "number vs Date never compares" trap.
- In ClickHouse the column type decides (§3.2, §3.3).

### 3.7 Binary data and UTF-8 (v0.13-utf8 D9)

| Boundary | Rule | D9 row to add |
|---|---|---|
| BSON String → `str` | strict UTF-8 at the conversion. Invalid: decode error with the field path → 500 (data error, logged); the low-level layer checks only structure | `db` reads: strict, like route JSON |
| `str` → BSON String | invalid UTF-8 → 400 `invalid UTF-8 in field f` (like PG 22021) | `db` writes: strict |
| BSON Binary ↔ `str` | base64 text (ASCII), so `to_json`, store and KHRIP_DATA are lossless | resolves С11 for MongoDB |
| ClickHouse String/FixedString → `str` | raw bytes, like fetch bodies and `bytea`; `to_json` sanitises with U+FFFD | `ch` reads: raw |
| `str` → ClickHouse String | raw bytes | `ch` writes: raw |

- `Bson`, `Buf` and RowBinary bodies never reach user values through the forms. The library's `Bson`/`ChResult` keep raw bytes and stay banned from store and `to_json` (low-level team).
- Recommendation for consistency (not required by this design): map PostgreSQL `bytea` to base64 `str` too, before UTF-8 step E.

---

## 4. Errors

### 4.1 Status mapping (fail-closed)

The same table drives `sql` (existing), `ch` and `db`. 5xx failures are logged as `file.kh:line:col: <form> failed [code Name] message (query_id / comment)`. Response bodies never contain stored values.

| Condition | MongoDB | ClickHouse | Status, body |
|---|---|---|---|
| duplicate key | 11000, 11001, 12582; `writeErrors[].code == 11000` | — (no unique keys) | 409 `already exists: <index name>` |
| no document/row for a `T` shape | | | 404 `not found` |
| rejected value | 121 DocumentValidationFailure; Khrip encode errors (invalid UTF-8, bad base64/ISO/UUID, out of range) | 6, 27, 38, 41, 53, 69, 70, 72, 117, 321, 376, 395, 440, 457, 691 (parse, range, enum, LIMIT, `throwIf`); Khrip encode errors | 400 with the server message (version suffix and SQL text cut off) |
| negative `skip`/`limit` | Khrip check before sending | 440 | 400 `limit must not be negative` |
| unavailable | connect, TLS or auth failure; pool wait timeout; HostUnreachable 6, HostNotFound 7, MaxTimeMSExpired 50, NetworkTimeout 89, ShutdownInProgress 91, PrimarySteppedDown 189, ExceededTimeLimit 262, SocketException 9001, NotWritablePrimary 10107, NotPrimaryNoSecondaryOk 13435, NotPrimaryOrSecondary 13436, InterruptedAtShutdown 11600, InterruptedDueToReplStateChange 11602; a read whose response was lost | connect, TLS or auth failure (516); admission timeout; 159, 202, 203, 209, 210, 236, 241, 242, 252, 394, 999; a read whose response was lost | 503 `database unavailable, try again` + `Retry-After: 1` |
| write outcome unknown | write sent and response lost; `writeConcernError` (64, 100) | INSERT/ALTER sent and response lost | 500 `write outcome unknown`; `e.unknown_outcome = true` |
| result too large | drained find/aggregate over `DATABASE_MAX_RESULT` | 396, or body over `DATABASE_MAX_RESULT` | 500; log: `add a limit, or iterate with for` |
| decode error | §3.1 | §3.2 (run-time range) | 500 |
| anything else | BadValue 2, etc. | 62 and others | 500 |

- **Retries.** Reads are retried once within the deadline after a network error on a reused pooled connection or after NotWritablePrimary-class errors (idempotent). Writes are never retried: there are no sessions or `txnNumber`, hence no retryable writes, so a lost write is "unknown".
- **Partial `insertMany`** (ordered): the documents before the failing one stay; the request gets 409 (`e.written` says how many).

### 4.2 One convention

- The three forms share the status table, `DbError`, `else e`, `DATABASE_TIMEOUT` and the startup check.
- There is no result struct to forget: a form either has its value or has already ended the request. `else e` is the only way to see a failure, and its block must use `e` (D-E3).
- **Unused results.** The value of an update, delete or insert may be discarded: failures cannot be lost, because they end the request. "Matched 0" is not a failure (same as `sql`); §10.5 lists it as a remaining trap.
- **Library recommendation** (for the low-level team; not in KHRIP.md): `MongoResult` and `ChResult` get the same fields `ok`, `code: str`, `message`, `unknown_outcome`. The compiler rejects a library call whose result is unused (statement position), as the review proposed for В4.

---

## 5. Configuration

| Variable | Default | Meaning |
|---|---|---|
| `MONGODB_URI` | — (required when a collection is declared) | `mongodb://user:pass@host:27017/app?authSource=admin&tls=true&tlsCAFile=...&maxPoolSize=32&appName=...`. The path must name the database (D-S10); options as accepted by the low-level layer (`retryWrites`, `w`, `appName`, `maxPoolSize`, `directConnection`, ...) |
| `CLICKHOUSE_URL` | — (required when `ch` is used) | `http(s)://user:pass@host:8123/database`. `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`, `CLICKHOUSE_DATABASE` override the URL parts (official clients' names). Database default `default` |
| `DATABASE_TIMEOUT` | 10000 ms | Existing PG budget, now for every statement of every form: pool wait, exchange, reads' one retry. `MONGODB_TIMEOUT` and `CLICKHOUSE_TIMEOUT` override it per database |
| `DATABASE_MAX_RESULT` | 64 MiB | wire bytes of one statement's result (drained `find`/`aggregate`, ClickHouse body) |
| `DATABASE_MIGRATE` | `apply` | `apply`: PG migrations, `migration ch`, MongoDB indexes at start. `check`: verify only; `./app migrate` applies |
| `CLICKHOUSE_MAX_INFLIGHT` | 32 | per worker thread (FIFO admission, low-level) |
| `MONGODB_SAMPLE` | 20 | documents sampled per collection at start; 0 disables |
| `KHRIP_TEST_MONGODB_URI`, `KHRIP_TEST_CLICKHOUSE_URL` | — | `khc test`: a temporary database per run (`khrip_test_<pid>_<rand>`), created and dropped like the PG test schema. A program that uses a form fails `khc test` with `needs KHRIP_TEST_MONGODB_URI` instead of skipping |

- **Where tuning lives.**
  - Per statement: ClickHouse `SETTINGS` in the text; MongoDB option documents and chains (`.maxTimeMS(500)`, `{allowDiskUse: true}`, `.hint({...})`).
  - Per database: environment and URI options. KHRIP.md names only the two URIs.
- **Several databases.**
  - MongoDB: `collection x: T in "otherdb"` on the same cluster.
  - ClickHouse: qualified names (`analytics.events`) in the text.
  - Another cluster: the library (`Mongo{...}`, `ChConfig{...}`), DATABASES.md.
- **Each server's deadline.** The statement starts with `deadline = now + timeout`. MongoDB gets `maxTimeMS = remaining`; ClickHouse gets `max_execution_time = max(1, remaining s)`.

---

## 6. Startup and schema

Order:
1. PostgreSQL (unchanged).
2. ClickHouse: connect, `SELECT version()`, migrations, site checks.
3. MongoDB: `hello` and authentication; per collection: indexes, then the sample.

All errors are printed, then the process exits 1 with `khrip: N database statement(s) do not match`, as for `sql`. Startup allocations use the existing `__db_start` trick (fresh mmap, not the request arena); plans and templates are immutable afterwards.

### 6.1 MongoDB

- **Indexes.** `apply`: one `createIndexes` per collection with all declared indexes. MongoDB answers "all indexes already exist" when nothing changed (measured).
  - IndexOptionsConflict (85) and IndexKeySpecsConflict (86) → D-S1.
  - DuplicateKey while building a unique index → D-S2.
  - `check`: `listIndexes` and compare keys and options; a missing index → D-S9.
  - Indexes that exist but are not declared are left alone.
- **Sample.** `aggregate [{$sample: {size: MONGODB_SAMPLE}}, {$project: {f: {$type: "$f"}, ...}}]` over T's top-level fields (measured: it returns `objectId`, `string`, `int`, `date`, `missing` per field without decoding). Each type is compared with §3.1:
  - Date in an `int`/`str` field without `date` → D-S5;
  - String in an `ObjectId` field (or the reverse) → D-S7;
  - `missing`/`null` in a required field → D-S8;
  - any other incompatible type → D-S11.
  - An empty collection passes. The sample cannot see documents written later; those fail at decode with a precise 500.
- **Authentication and database.** No database in the URI → D-S10. Authentication failure → `khrip: MongoDB authentication failed for user u on database app` with the hint `users created in admin need ?authSource=admin`.

### 6.2 ClickHouse

- **Migrations** first (§1.3).
- **SELECT-like sites.** `DESCRIBE TABLE (<text with {pN:Type}>)` with dummy parameters, then the result columns against R (§3.2). Measured: without values ClickHouse answers `Substitution p0 is not set`; with them it reports unknown columns (`Maybe you meant: ['page']`) and type errors.
  - Dummies: int `1` (0 breaks `toIntervalSecond`, measured), float `1`, bool `false`, str `''`, list `[]`, optional `\N`, enum its first variant, ObjectId 24 zeros.
  - Constant folding makes some dummies fail: `''` against `DateTime` gives 41 and against `UUID` gives 376 (measured). On a value-parse code (6, 27, 38, 41, 53, 69, 70, 72, 376, 457, 691), the check retries with the `str` dummies `'1970-01-01 00:00:00'`, `'00000000-0000-0000-0000-000000000000'`, `'1970-01-01'` and `'0'`, then gives up on structure checking for that site with a printed note (not an error).
  - When the message shows that a `str` parameter met a `DateTime` (`converting '' to DateTime`), it prints the hint `parameter {from} is str and meets a DateTime: send int seconds, or parseDateTimeBestEffort({from})`.
  - Error messages replace `pN` with the `{expr}` source text.
- **`INSERT INTO t {rows}` sites.** `DESCRIBE TABLE t` (also the low-level DESCRIBE cache) builds the column plan (§3.3). Messages D-S3 and D-S4.
- **Other statements.** `EXPLAIN AST <text>` with dummies: syntax only (measured: works for `INSERT ... FORMAT` and `ALTER ... DELETE` with parameters).
- Enum names against Khrip enums, Nullable against optional fields, DateTime64 precision → D-S6.

### 6.3 khc test

Same checks against the temporary databases, after the migrations and indexes have been applied to them.

---

## 7. Concurrency and the runtime

### 7.1 `tx`

- `db` and `ch` forms are forbidden inside `tx`, directly or through functions. The existing `fn_effect`/`driver_io` analysis gets the forms as effects. Message D-M28.
- Rationale: `tx` re-runs its block on a serialization conflict, and neither database takes part in the PG transaction.
- MongoDB multi-document transactions need a replica set, sessions and their own retry loop (TransientTransactionError). They are left for a later version: a `tx` whose body has only `db` forms would map well onto Khrip's retry model.
- Until then, KHRIP.md's guidance is: one atomic document operation (`$inc`, `findOneAndUpdate` with the expected state in the filter), unique indexes, and `T?` for duplicates.

### 7.2 Store lock windows (v0.13-store-gc §6.5/§6.6)

- Each form evaluates its parameter values under the lock (they may come from store). It then builds the complete request bytes: BSON command from the templates, or the URL plus RowBinary body. Only then does it release.
- **One audited window per driver:** `__mongo_exchange_unlocked(pool, bytes, deadline)` and `__ch_exchange_unlocked(url, head, body, deadline)`. Each does `__store_release_keep()` → pool take, write, read → `__store_lock()`. These become sites 4 and 5 of the §6.5 list and of the lint.
- **W1.** Inside the window only pool memory (mmap) and freshly allocated response buffers above `hi` are written.
- **W2.** Configuration is read from the immutable startup copies (`__perm_alloc`), never from store, so nothing mutable in store is dereferenced.
- **W3.** Panics in the window go through the existing catch paths.
- **Decoding** happens after `__store_lock()`. Decoding inside the window would also satisfy W1 (allocations above `hi`), but keeping it outside keeps the audit trivial.
- **`rw` analysis.** The forms neither read nor write store, so they join the safe list. A route that only reads store and calls `db`/`ch` takes the shared lock (С10).

### 7.3 Cursors

- No cursor value exists in user code; a `MongoCursor` in store (К1) cannot be written.
- `find`/`aggregate` into a list drain the cursor inside the runtime, with `DATABASE_MAX_RESULT` as the bound.
- `for x in db.c.find(...)` / `aggregate(...)`:
  - the hidden cursor id lives in the loop frame and in the request's cursor list (low-level killCursors at request end);
  - each batch is decoded and iterated, then `getMore` is sent;
  - `break`, `return`, `fail` or a panic kill the cursor at request end;
  - there is no total-size limit.
- Memory: decoded documents are arena values, so a loop over a million documents still grows the arena by what it decodes. The gains are a raw-batch buffer that is reused, early termination, and no list budget. Constant-memory streaming would need per-iteration arena marks and escape analysis: out of scope.
- `for row in ch "..."` streams RowBinary rows from the HTTP body in the same way (later step; the semantics are identical to the list).

### 7.4 Cancellation and timeouts

- The deadline is per statement (§5).
- On a client-side timeout:
  - MongoDB: the connection is discarded, and the server stops by itself through `maxTimeMS`;
  - ClickHouse: one asynchronous `KILL QUERY ... ASYNC` on another pooled connection, never awaited (Н12).
- A client that disconnects is not observed, as with `fetch` and `sql`.

### 7.5 GC compatibility (§4.3 of the review)

- Forms return fresh arena values and never write into objects reachable from user code. The library-write rule needs no barrier table entries for them.
- Sites, templates, plans, parsed URIs and pools live in permanent memory or mmap, outside STORE; they are not roots, and the collector ignores them.
- `ObjectId` and `DbError` are ordinary str/struct values with ordinary descriptors.
- No new ctx words: the cursor list and the held-connection words are the low-level team's (MONGOHELD, CHHELD).

---

## 8. Compiler work

### 8.1 New syntax and builtins

| Item | Where | Notes |
|---|---|---|
| `DOLLAR_IDENT` token | `src/lex.kh` | `$` + ident chars outside strings. `$` is a lexer error today (checked: `unexpected character '$'`), so no program changes meaning |
| `ch "..."` / `` ch `...` `` | `src/lex.kh` (`lex_sql` with a dialect flag) | quotes `'...'` with backslash escapes, identifiers `"..."` (backticks only inside `"..."`), comments `--`, `#`, `/* */`, `$h$...$h$` heredocs (all measured on 25.8); `{` is always a parameter except `\{`; `{ident:Type}` is D-C1 |
| `migration ch N` | `src/sql.kh` (`prescan_migration`) | own list, own runner |
| `collection` declaration | `src/decl.kh` | soft keyword at top level (lib uses `collection` as a parameter name) |
| `db.C.M(...)` form | `src/atom.kh` → new `src/mongo.kh` | soft: `db` followed by `.` and a declared collection, unless a local or global named `db` shadows it (lib has locals named `db`; user `fn db()` stays legal) |
| document literals, `x?`, shorthand, spread | `src/mongo.kh` | only in `db` argument positions and `collection` blocks |
| `else NAME { }` | `src/stmt.kh` | after `sql`, `ch`, `db` and `tx` |
| `ObjectId` | `src/types.kh` (new kind, runtime str), `src/api.kh` (route params, JSON descriptors), `lib/api.kh` (validation) | |
| `object_id()`, `parse_object_id()` | `src/atom.kh` builtins, `lib/rt.kh` | |
| `DbError` | lib type, always declared when a form is used | |

### 8.2 Type inference rules

1. The expected type `w` reaches a form exactly as it reaches `sql` today: `let x: T =`, `return` (the route's type for that status, the function's result), struct field values, arguments with a declared parameter type, and `else`/`??` follow-ups (which make the shape optional, `optional_follow`).
2. Shapes: §1.2 and §1.3 tables. A `T` shape in a route requires the route to list `404` (`sql_note_404`) unless an `else` follows.
3. Defaults without `w`:
   - `find` → `[T]`; `findOne`/`findOneAnd*` → `T?`;
   - `insertOne` → `T`; `insertMany` → `[T]`;
   - `update*`/`replace*`/`delete*`/`countDocuments`/`estimatedDocumentCount` → `int`; `distinct` → `[F]`;
   - `aggregate` → error D-M19;
   - `ch` SELECT → error D-C2; other `ch` statements → `int`.
4. R for non-aggregate reads: every field of R must be a field of T with a compatible type (D-M21); the projection is R's fields.
5. Document values are checked against the path type by §1.2's rules, with expected type F, so literals like `[]`, `{}` and `none` take their type from the field.
6. `x?` requires x of type `U?` and yields the inner type U for checking.
7. Shorthand `{slug}` resolves `slug` as an expression (local, parameter, `const`).
8. `if`/`match` whose branches are all document literals: each branch is checked, and the variants are compiled like `ORDER BY` variants.

### 8.3 Diagnostics (exact messages)

Format as today: `file:line:col: error: MESSAGE` and `hint: HINT`.

**MongoDB**

| Id | Message | Hint |
|---|---|---|
| D-M1 | `unknown collection notes` | `declare it: collection notes: Note` |
| D-M2 | `a collection holds documents: notes needs a struct type, not [Note]` | |
| D-M3 | `Note has no field titel` | `did you mean title?` (else `fields: _id, title, body, tags, created`) |
| D-M4 | `{_id: id}: Note._id is ObjectId, but id is str` | `declare the parameter as id: ObjectId, or convert it: let oid = parse_object_id(id) else { return 404 }` |
| D-M5 | `{tags: tag}: tag is str? and may be none; in a filter none matches only documents without tags` | `write tag? to skip the condition when tag is none, or unwrap it first: let t = tag else { return 400 }` |
| D-M6 | `owner? in a deleteMany filter: when owner is none the filter matches every document` | `unwrap it first: let o = owner else { return 400 }; x? is allowed only in find, countDocuments, distinct and aggregate` |
| D-M7 | `x? skips a filter condition; written documents already leave none values out` | `drop the ?` |
| D-M8 | `updateOne needs update operators: a plain document would replace the whole Note` | `write {$set: {...}}; to replace the document use replaceOne` |
| D-M9 | `replaceOne takes a whole Note, not update operators` | `use updateOne(filter, {$set: ...})` |
| D-M10 | `$unset created: Note.created is int, not optional, so the document could no longer be read as Note` | `make it created: int? (or give it a default), or $set a value` |
| D-M11 | `$set views: Note.views is int, but "x" is str` | |
| D-M12 | `$inc needs an int or float field; Note.title is str` | |
| D-M13 | `_id cannot change after insert` | |
| D-M14 | `unknown operator $gtee` | `did you mean $gte?` |
| D-M15 | `$where runs JavaScript on the server and is not allowed` | `use query operators or {$expr: ...}` |
| D-M16 | `insertOne: Note.created has no value` | `give it in the document, or a default in Note: created: int = 0` |
| D-M17 | `insertOne: Note._id is str and is not generated` | `give _id a value, or declare it _id: ObjectId to have one generated` |
| D-M18 | `upsert may insert a Note without created` | `add it to $setOnInsert: {created: now()}` |
| D-M19 | `aggregate needs the result type` | `let rows: [Row] = db.orders.aggregate(...) (or the route's type), with type Row { _id: ..., ... }` |
| D-M20 | `"$categry": Order has no field categry` | `did you mean "$category"?` |
| D-M21 | `NoteView.score is not a field of Note: find returns stored fields only` | `compute it with aggregate ($project or $addFields)` |
| D-M22 | `findOne returns one document: limit does not apply` | `use find(...).limit(n) for a list` |
| D-M23 | `sort takes 1 or -1 for each field` | |
| D-M24 | `$regex takes a pattern literal` | `write "{q}" to match q literally, "^{q}" for a prefix` |
| D-M25 | `indexes are declared on the collection` | `collection notes: Note { index {email: 1} {unique: true} }` |
| D-M26 | `insertOne gives the stored Note: it has no field insertedId` | `use ._id` |
| D-M27 | `expireAfterSeconds needs a BSON Date field: Session.seen is int` | `add "date seen" to the collection block` |
| D-M28 | `db.notes.insertOne cannot run inside tx: the block re-runs on a conflict and MongoDB is not part of it` | `do it after the tx` |
| D-M29 | `ObjectId("...") is a mongosh helper` / `new Date() is a mongosh helper` / `regular expression literals are mongosh syntax` | `use parse_object_id("...")` / `use now()` / `use {$regex: "re", $options: "i"}` |
| D-M30 | `$lookup from "users": unknown collection users` | `declare it: collection users: User` |
| D-M31 | `{address: {city: c}} compares the whole subdocument, field order included` | `match one field: "address.city": c` |
| D-M32 | `$rename changes the schema of Note` | `migrate the data in a one-off program` |
| D-M33 | `a map's keys are not known at compile time` | `use a struct or a document literal` |
| D-M34 | `projection comes from the result type` (second argument of `find`/`findOne`) | `declare the fields you need: let xs: [NoteTitle] = db.notes.find(...)` |
| D-M35 | `$set is a MongoDB operator: it is a key inside a db document` (a `$` token elsewhere) | |

**ClickHouse**

| Id | Message | Hint |
|---|---|---|
| D-C1 | `ch takes {expr}: the parameter type comes from the Khrip value` | `write {from} instead of {from:Int64}` |
| D-C2 | `ch needs to know the result type of this query` | as `sql` |
| D-C3 | (the `sql` messages for optional comparisons, table-name parameters and `ORDER BY {o}`, unchanged) | |
| D-C4 | `with wait_for_async_insert = 0 a failed insert is lost silently` | `drop the setting: async_insert = 1 waits for the flush` |
| D-C5 | `INSERT INTO t {rows} takes a struct or a list of structs, not int` | |
| D-C6 | (a parse error right after a backtick inside `` ch `...` ``) | `inside ch \`...\` quote identifiers with "..."` |
| D-C7 | `ch reads rows itself: drop FORMAT JSONEachRow` | |
| D-C8 | `ch cannot run inside tx: ...` | as D-M28 |

**`else e`**

| Id | Message | Hint |
|---|---|---|
| D-E1 | `else e handles database failures, and x is not a sql, ch or db operation` | `use else { } to unwrap an optional` |
| D-E2 | `inside tx a failed statement rolls the whole block back` | `handle it around the block: let t = tx { ... } else e { ... }` |
| D-E3 | `e is never read: every failure, database down included, would get the same answer` | `read e.status, or drop else e to let failures answer themselves` |

**Startup** (printed as `file.kh:line:col: error: ...` with the site location, or `khrip: ...`)

| Id | Message |
|---|---|
| D-S1 | `index title_1 on notes exists with other options` → fix: `drop it, or give this one a name: index {title: 1} {unique: true, name: "title_unique"}` |
| D-S2 | `cannot create unique index title_1 on notes: duplicates exist` |
| D-S3 | `events.ts (DateTime) is not a field of Event and has no DEFAULT: rows would get 1970-01-01 00:00:00` → fix: `add ts to Event, or DEFAULT now() to the column` |
| D-S4 | `Event.note is str? but column note is String without DEFAULT: none would be written as ''` → fix: `make the column Nullable(String) or give it a DEFAULT, or make the field str` |
| D-S5 | `notes.seen holds Date in the database, but Note.seen is int without "date seen"` |
| D-S6 | `column ts is DateTime64(3), but PageRow.ts is int` → fix: `make it str, or select toUnixTimestamp64Milli(ts) AS ts_ms` |
| D-S7 | `notes._id holds string values, but Note._id is ObjectId` (or the reverse) |
| D-S8 | `some notes documents have no created, but Note.created is not optional` → fix: `make it created: int? or give it a default` |
| D-S9 | `index title_1 on notes is missing (DATABASE_MIGRATE=check)` → fix: `run ./app migrate` |
| D-S10 | `MONGODB_URI has no database name` → fix: `mongodb://host:27017/app` |
| D-S11 | `notes.price holds string values, but Note.price is int` |

### 8.4 What stays library code (contract with the low-level layer)

The compiler and two new runtime files (`lib/mongo_site.kh`, `lib/ch_site.kh`) depend only on these:

1. **MongoDB.**
   - `__mongo_exchange_unlocked` (send a prebuilt OP_MSG, receive one reply; errors classified as "before send", "after send (unknown)", server code, `writeErrors`, `writeConcernError`).
   - `getMore`/`killCursors`; the request-end cursor registry.
   - Pools keyed by URI; parsed URI options.
   - BSON: validate-once reply views, no-alloc accessors, descriptor decode with widening and field-path errors, UTF-8 at `str` conversion, Date/Binary/Decimal conversions.
   - `object_id` generation.
2. **ClickHouse.**
   - `__ch_exchange_unlocked` with `query_id`, parameters, settings, payload and deadline; results: exception code, `X-ClickHouse-Summary`, unknown outcome.
   - DESCRIBE cache and column plans with range checks; FIFO admission; `KILL QUERY`.
3. **Linking.** Drivers are linked only when used: a program with a `collection` or `ch` links its driver and site runtime, and nothing else.
4. **The library API** (`mongo_*`, `ch_*`, `Bson`, ...) remains for raw commands, other clusters and explicit cursors. It is documented in DATABASES.md (in English), not in KHRIP.md.

### 8.5 Templates and sites (code generation)

- **MongoDB.** Each `db` form becomes a site in DATA: collection index, method, shape, R descriptor, projection bytes (built at compile time), option values and up to four templates (filter, update/document, sort, options/pipeline).
  - A template is a BSON skeleton with pre-encoded keys and a hole table: (value slot, type descriptor, flags `DROP_IF_NONE`, `REGEX_LITERAL`, `DATE`, `BINARY`, `UUID`, `DECIMAL`, `UNSET_ON_NULL`, `SPREAD`).
  - Values are pushed like `sql` parameters. `__mdb_run(site, vals)` copies static bytes, encodes holes and back-patches document lengths.
  - No builder objects and no repeated validation (В8).
- **ClickHouse.** Each `ch` form is a `sql`-style site with a dialect word, the CH parameter type names, an INSERT plan pointer (filled at start) and the location. It runs as `__ch_site_run(site, vals)`.
- **`else e`.** The site call gets a flag. On failure the runtime returns a sentinel after filling a fresh `DbError` instead of calling `fail`; the generated code branches to the block.

### 8.6 Implementation steps, cost, risks

| Step | Content | Lines (estimate) |
|---|---|---|
| A | `ch` lexer dialect, `parse_sql` dialect switch (`{pN:Type}`, INSERT → RowBinary site, habits), `migration ch`, `lib/ch_site.kh` (params, startup DESCRIBE with retries, plans, errors, shapes, migrations), tests | src +550, lib +700, tests +500 |
| B | `ObjectId` type and builtins; `DbError`, `else e` for `sql`/`ch`/`tx`; tests | src +450, lib +200, tests +250 |
| C | `collection` declarations, `$` token, document literals, typing (§1.2), shapes, diagnostics; `khc check` only | src/mongo.kh +1,900, tests (≈60 negative fixtures) +600 |
| D | Mongo sites, templates, `lib/mongo_site.kh` (ops, cursor drain, `for`, decode, errors, startup indexes and sample) | src +300, lib +1,000, tests +500 |
| E | `khc test` databases, KHRIP.md, DATABASES.md in English, tutorial lesson 8, eval tasks on MongoDB and ClickHouse in 4 languages | docs +500 |
| | **Total** | **≈ 7,450** (code ≈ 5,100, tests ≈ 1,850, docs ≈ 500) |

- **Cost.** About the size of the v0.12 language work (`src/sql.kh` 2,335 + `src/sqlcheck.kh` 1,613 + `lib/db.kh` 1,633 = 5,581 lines). Step A is the cheapest and closes В3 and В6 for good. It can ship before the MongoDB steps.
- **Risks.**
  1. **Breadth of MongoDB typing.** Too strict rejects valid queries; too loose misses traps. Mitigation: full checks for query and update operators (≈ 40) and first-shape aggregation; names-only checks for ≈ 150 expression operators; geo and `$expr` arguments unchecked. Every rejection must name a working rewrite.
  2. **Parser interplay.** `{` in argument positions, `no_struct`, `?` after an expression, shorthand. All are confined to `db` arguments. `$` is new (no conflict), and `db`/`collection` are soft. Needs fixtures for `if db.x.countDocuments({...}) == 0 {` and `for x in db.c.find({}) {`.
  3. **Divergences from MongoDB defaults.** `findOneAndUpdate` returns "after"; none is never stored; `$regex` values are literal; null and missing read alike. These must be in KHRIP.md (they are) and tested.
  4. **The ClickHouse startup check depends on dummy values.** The retry list and the "give up structure checking with a note" rule bound it; real failures stay errors.
  5. **The startup sample** can miss heterogeneous data (runtime 500 instead), or slow startup on collections with expensive views (`MONGODB_SAMPLE=0`).
  6. **ObjectId touches core paths** (types, JSON, routes). It must be coordinated with UTF-8 steps E/F (boundaries) and GC step 3 (descriptors: it is a str).
  7. **Prompt growth** (+532 o200k). The eval must confirm that the section is enough (§10.6).

---

## 9. KHRIP.md

The section replaces "## MongoDB and ClickHouse" (KHRIP.md:283-291). Three small edits go with it:
- the `tx` sentence loses "MongoDB or ClickHouse network operations," (the new section says it);
- "`fetch`, `sql` and `sleep` are plain calls" becomes "`fetch`, `sql`, `ch`, `db` and `sleep` are plain calls";
- the habits paragraph gets one line.

The full file is `KHRIP.new.md`; the diff is `KHRIP.diff` (55 lines).

````markdown
## MongoDB and ClickHouse

```khrip
type Note { _id: ObjectId, title: str, tags: [str], views: int = 0, created: int }
collection notes: Note {                       // MONGODB_URI=mongodb://host/app
    index {title: 1} {unique: true}            // created at start
}
let n: Note = db.notes.findOne({_id: id})       // none: 404
let recent = db.notes.find({tags: tag?, views: {$gte: 10}}).sort({created: -1}).limit(20)
let added = db.notes.insertOne({title: t, tags: [], created: now()})  // with new _id
let matched = db.notes.updateOne({_id: id}, {$set: patch, $inc: {views: 1}})
let after: Note? = db.notes.findOneAndUpdate({_id: id}, {$set: body}) // new version
let stats: [PageStat] = ch `SELECT page, count() AS views FROM events
    WHERE ts >= {from} GROUP BY page ORDER BY views DESC LIMIT {n}`
let written = ch "INSERT INTO events {rows}"   // [Event]: fields → columns
```

- `collection name: T` declares a MongoDB collection; `db.name.method(...)` takes
  MongoDB's methods, operators and documents, checked against T. Values are typed
  BSON, never query text (`$regex: "^{q}"` matches q literally).
- Results as with `sql`: `find` and `aggregate` give `[T]`, `T?` or `T` (none →
  404), `findOne...` `T?` or `T`, `insertOne` the stored document (`T?`: none on a
  duplicate key), updates and deletes a count.
- none is never stored: documents leave it out, `$set` keeps the old value
  (`$set: patch` sets only fields sent; a JSON null or `none` removes the field).
  In a filter an optional value needs `x?` (skipped when none), allowed only in
  `find`, `countDocuments` and `aggregate`.
- `ObjectId` is 24 hex digits in JSON and paths; `object_id()`,
  `parse_object_id(s) -> ObjectId?`.
- `ch` (`CLICKHOUSE_URL`, `migration ch N`) follows the `sql` rules. DateTime and
  Date are `int` (unix seconds) or `str`.
- A failure ends the request: duplicate key 409, bad value 400, database down 503,
  unknown write outcome 500. `let r = <operation> else e { ... }` handles it:
  `e.status`, `e.message`, `e.unknown_outcome`. Not allowed in `tx`.
````

Habits line added after "catching a duplicate key → ...":

```
`ObjectId("...")` → `parse_object_id("...")`; `insertedId` → `._id`;
`.toArray()` → not needed; `{x:Int64}` in ClickHouse → `{x}`.
```

**Token counts** (bench/tokens/spec_tokens.mjs):

| Text | o200k | Claude |
|---|---:|---:|
| the section above | 613 | 627 |
| KHRIP.md today (with the PR paragraph) | 4,078 | 4,265 |
| KHRIP.md before PR #1 | 3,945 | 4,118 |
| KHRIP.md with this design | 4,610 | 4,800 |
| change vs today | +532 | +535 |
| PR draft section (review, for the PR API) | 634 | 706 |
| PostgreSQL section (one database) | 853 | 841 |
| DATABASES.md of the PR (what the PR asked the model to read) | 3,047 | 4,795 |

- Left to DATABASES.md:
  - storage hints (`date`, `binary`, `uuid`, `decimal`);
  - the method table and option names (MongoDB's own; the model knows them);
  - `insertMany` into `[T?]`;
  - `for` streaming;
  - `DbError.code`/`written`;
  - environment knobs;
  - typing details;
  - the library API.
- The compile errors teach the rest; each names the rewrite.

---

## 10. Evidence

### 10.1 Programs

Files in `ev/`: `p1_notes.kh`, `p2_orders.kh`, `p3_events.kh`, and the variants `p1_notes_with_index.kh`, `p1_pg_no_migration.kh`, `p3_events_with_migration.kh`, plus the tour `p4_links_tour.kh`. These are sketches: nothing compiles them yet. Each operation's compiled form was run on the real servers (§10.3).

**P1** — notes CRUD on MongoDB (PR: 76 lines, this design: 21):

```khrip
type NoteIn { title: str, body: str, tags: [str] = [] }
type Note { _id: ObjectId, ...NoteIn, created: int }

collection notes: Note

route POST "/notes" (body: NoteIn) -> 201 Note {
    return 201 db.notes.insertOne({...body, created: now()})
}

route GET "/notes/{id}" (id: ObjectId) -> Note | 404 {
    return db.notes.findOne({_id: id})
}

route GET "/notes" (tag: str?, limit: int = 20) -> [Note] {
    return db.notes.find({tags: tag?}).sort({created: -1}).limit(limit)
}

route PUT "/notes/{id}" (id: ObjectId, body: NoteIn) -> Note | 404 {
    return db.notes.findOneAndUpdate({_id: id}, {$set: body})
}

route DELETE "/notes/{id}" (id: ObjectId) -> 204 | 404 {
    if db.notes.deleteOne({_id: id}) == 0 {
        return 404
    }
    return 204
}
```

**P2** — insert, conditional update, aggregation (PR: 70 lines with 25 builder calls, this design: 23):

```khrip
type NewOrder { customer: str, category: str, amount: int }
type Order { _id: ObjectId, ...NewOrder, status: str, created: int }
type CategoryStat { _id: str, total: int, orders: int }

collection orders: Order

route POST "/orders" (body: NewOrder) -> 201 Order | 400 str {
    if body.amount <= 0 {
        return 400 "amount must be positive"
    }
    return 201 db.orders.insertOne({...body, status: "new", created: now()})
}

route POST "/orders/{id}/pay" (id: ObjectId) -> 204 | 404 {
    if db.orders.updateOne({_id: id, status: "new"}, {$set: {status: "paid"}}) == 0 {
        return 404
    }
    return 204
}

route GET "/stats/categories" (since: int = 0) -> [CategoryStat] {
    return db.orders.aggregate([
        {$match: {status: "paid", created: {$gte: since}}},
        {$group: {_id: "$category", total: {$sum: "$amount"}, orders: {$sum: 1}}},
        {$sort: {total: -1}}
    ])
}
```

**P3** — ClickHouse batch insert and parameterised stats (PR: 37 lines, this design: 17; the DDL comment is the same as in the PR's program):

```khrip
// CREATE TABLE events (ts Int64, user_id Int64, page String, ms Float64)
//     ENGINE = MergeTree ORDER BY (page, ts)
type EventIn { user_id: int, page: str, ms: float }
type Event { ts: int, ...EventIn }
type PageStat { page: str, views: int, users: int, avg_ms: float }
type Inserted { inserted: int }

route POST "/events" (body: [EventIn]) -> 202 Inserted | 400 str {
    if body.len() == 0 || body.len() > 10000 {
        return 400 "send 1..10000 events"
    }
    let t = now()
    let rows = body.map(e => Event { ts: t, ...e })
    return 202 Inserted { inserted: ch "INSERT INTO events {rows}" }
}

route GET "/stats/pages" (from: int, to: int, limit: int = 10) -> [PageStat] {
    return ch `SELECT page, count() AS views, uniq(user_id) AS users, avg(ms) AS avg_ms
        FROM events WHERE ts >= {from} AND ts < {to}
        GROUP BY page ORDER BY views DESC LIMIT {limit}`
}
```

With this design the same P3 also writes into the realistic schema (`DateTime`, `UInt64`, `LowCardinality(String)`, `Float32`) that the PR's `ch_insert` rejected (review В6).

### 10.2 Tokens

bench/tokens/count.mjs, comments and blank lines removed, as in the review. The PR and Go programs are the review's (`pr1-evidence/1`); the Go versions use the official drivers and were not compiled.

| Program | This design | PR API | Go | Go / this | PR / this | Other |
|---|---:|---:|---:|---:|---:|---|
| P1 notes (MongoDB) | **241** (251) | 742 (775) | 1,184 (1,443) | 4.91 (5.75) | 3.08 (3.09) | PostgreSQL 318 (324), without its migration 278 (282); review's typed sketch 356 (352); this design with an index declared 255 (266) |
| P2 orders (MongoDB) | **268** (279) | 703 (772) | 990 (1,188) | 3.69 (4.26) | 2.62 (2.77) | — |
| P3 events (ClickHouse) | **235** (242) | 424 (456) | 889 (1,067) | 3.78 (4.41) | 1.80 (1.88) | review's `ch` sketch 248 (257); this design with `migration ch` 275 (284) |
| **P1+P2+P3** | **744** (772) | 1,869 (2,003) | 3,063 (3,698) | **4.12** (4.79) | 2.51 (2.59) | |

o200k first, Claude (public tokenizer) in parentheses. For reference, the Go/Khrip ratio on the PostgreSQL eval tasks is 2.31.

- P1 is shorter than the PostgreSQL version because MongoDB needs no DDL and `findOneAndUpdate` replaces `UPDATE ... RETURNING *`; without the migration, the PG version is 278.
- The tour program `p4_links_tour.kh` (MongoDB with storage hints and a TTL index, `insertOne` into `else`, best-effort ClickHouse logging with `else e`, ClickHouse daily stats, regex search, delete) is 561 (560). It has no Go counterpart.

### 10.3 Server checks of the compiled forms

`compiled_mongo.py`, `compiled_ch.py` and `compiled_p4.py` send exactly the commands the forms compile to. They ran against MongoDB 8.0.34 (127.0.0.1:27019) and ClickHouse 25.8.33 (127.0.0.1:8125) in `lf_*` databases, all dropped afterwards.

| Form | Wire command | Result |
|---|---|---|
| `db.notes.insertOne({...body, created: now()})` | `{insert: "notes", documents: [{_id: ObjectId(gen), title, body, tags, created}], ordered: true}` | `n: 1`; the value is the encoded document decoded as `Note` |
| `db.notes.findOne({_id: id})` | `{find, filter: {_id}, projection: {_id:1,title:1,body:1,tags:1,created:1}, limit: 1, singleBatch: true}` | the document; an empty batch gives 404 |
| `find({tags: tag?}).sort(...).limit(20)` | filter `{}` when tag is none, `{tags: "x"}` otherwise | 3 notes / 2 notes, newest first |
| `findOneAndUpdate({_id: id}, {$set: body})` | `{findAndModify, query, update: {$set: {title, body, tags}}, new: true, fields: projection}` | new version; missing id → `value: null` → 404 |
| `deleteOne({_id: id})` | `{delete, deletes: [{q, limit: 1}]}` | `n: 1`, then `n: 0` → 404 |
| P2 pay | `{update, updates: [{q: {_id, status: "new"}, u: {$set: {status: "paid"}}}]}` | `n: 1`, again `n: 0` → 404 |
| P2 stats | the pipeline with `cursor: {}` | `[{_id: "books", total: 1200, orders: 2}]`; `$sum` results are BSON `int` (Int32), so widening is required |
| typo `"$categry"` (rejected by D-M20) | | MongoDB silently groups all 3 orders under `_id: null` |
| `{_id: "<hex string>"}` against ObjectId ids (rejected by D-M4) | | silently 0 documents |
| dropped condition (why D-M6 exists) | `count {}` | 3 of 3: a `deleteMany` would delete everything |
| startup sample | `$sample` + `$project {$type}` | `objectId`, `string`, `int` per field, no decoding |
| declared index, second start, changed options | `createIndexes` | created; `all indexes already exist`; error 86 IndexKeySpecsConflict → D-S1 |
| `insertOne` duplicate (P4) | | `writeErrors[0].code == 11000` with `ok: 1` → none / `else` / 409 |
| `date created, expires` (P4) | Date values; none left out | `$type`: `date` / `missing` |
| `$regex: q` with q = `.` / `(a+)+$` | escaped | literal match / no match |
| updateOne without operators (rejected by D-M8) | `{u: {}}` | MongoDB replaced the document and erased its fields (`nModified: 1`) |
| `ch "INSERT INTO events {rows}"` (P3, realistic schema) | `DESCRIBE TABLE events`; `INSERT INTO events (ts, user_id, page, ms) FORMAT RowBinary` + body encoded as UInt32/UInt64/String/Float32 | `written_rows: 4`; user_id −1 refused by the plan → 400 |
| P3 SELECT startup check | `DESCRIBE TABLE (SELECT ... {p0:Int64} ... LIMIT {p2:Int64})` with dummies 1 | `page LowCardinality(String), views UInt64, users UInt64, avg_ms Float64`: all fit PageStat |
| P3 SELECT | parameters `param_p0..p2` | `/a` 3 views, `/b` 1 view |
| injection string as a `str` parameter | `page = {p0:String}` | 0 rows |

### 10.4 Where the review's error-prone places went

| Review (§5.1) | This design |
|---|---|
| P1: 6 manual error checks | 0: fail-closed |
| P1: cursor drain loop (В5 trap) | none: `find` returns the list |
| P1: 2 reads of `n` via `bson_get_int` | `deleteOne(...) == 0` |
| P1: second find after update | `findOneAndUpdate` (atomic, returns the new version) |
| P2: 25 builder calls, `cursor: {}`, collection named twice | 0 builder calls: documents are literals; collection once |
| P3: 2 checks, `map[str,str]` with `.to_str()`, `\{`/backticks, Int64-only DDL | 0 checks, `{from}` parameters, any column types |
| Silent traps В1, В2, В3, В4, В5, Н2, `_id: BsonObjectId?` | none can be written: no `Bson` values, none never stored, no interpolated query text, no ignorable results, no cursors, no positional options, generated ObjectId |

### 10.5 Remaining places where an AI can still make a silent mistake

1. **Discarded "matched 0".** A route that ignores the count of `updateOne`/`deleteOne` answers 204 for a missing id (same as `sql "UPDATE ..."`). A possible later lint: a discarded single-document count in a route that lists 404.
2. **`x?` used by reflex in a read-many filter on an authorisation field.** `find({owner: owner?})` lists everyone's documents when the owner is none. Mitigated: `?` is forbidden in `findOne`, update and delete filters, and the error for a plain optional suggests unwrapping first. It remains possible in `find`/`countDocuments`/`aggregate`.
3. **Read-modify-write without atomicity.** `findOne` then `updateOne` with a computed `$set` (lost update), or check-then-insert without a unique index (duplicates). MongoDB forms have no `tx`, and the positional `sql` rule ("a write after another statement outside tx") would reject legitimate multi-collection code. Proposed later lint: same collection, same `_id`/unique-key filter, `$set` value derived from the earlier read.
4. **`findOneAndUpdate` returns the new version by default** (MongoDB returns the old one). Code that relies on MongoDB's default without writing `returnDocument: "before"` silently gets the new version. Rare, and documented in KHRIP.md ("new version").
5. **`$regex` with a variable matches literally.** If user-supplied patterns were intended, results differ (by design; it is the safe direction).
6. **Ordered `insertMany` partial writes.** The documents before a duplicate stay while the request answers 409 (`e.written` tells).
7. **Data written by other applications after start** with other BSON types fails loudly (500). Dates written into a field not declared `date` after start are not matched by Khrip's Int64 filters: silent until the next restart's sample.
8. **ClickHouse table semantics.** ReplacingMergeTree/CollapsingMergeTree read without `FINAL` show duplicates until merges. Optional later startup note when a `ch` SELECT reads such a table without `FINAL` (the engine is in `system.tables`).
9. **ClickHouse `str` parameters against DateTime** fail at run time (400) for ISO strings. The startup check prints a hint but does not stop the server.
10. **Float32/Decimal columns round Khrip floats** on insert (the schema's choice; not reported).
11. **`else e` that answers one status for everything.** Partly caught by D-E3 (`e` must be read), but `if e.status == 409 { ... } return 401` still turns an outage into 401.
12. **Timeouts on analytics queries.** The 10 s default ends long ClickHouse queries with 503; the fix is `CLICKHOUSE_TIMEOUT` or `SETTINGS max_execution_time` (loud, not silent).

### 10.6 What is not yet proven

- Nothing compiles these forms yet. Token counts and server semantics are measured; compiler feasibility is argued in §8, not prototyped.
- The prompt section has not been tried blind. The next step is the review's protocol: eval tasks on MongoDB and ClickHouse written by a model from KHRIP.md alone, measuring first-try errors and tokens against Go, C# and Python.

---

## 11. Rejected alternatives

| Alternative | Why not |
|---|---|
| Keep the PR library API in KHRIP.md (with the review's draft, 634 tokens) | 742/703/424 tokens for P1–P3; 6–25 manual checks or builder calls per program; the silent traps stay possible |
| Typed library functions with Khrip maps (`mongo_one("notes", {"_id": id})`, the review's sketch, 356 tokens for P1) | Khrip maps are homogeneous, so `{"status": "paid", "created": {"$gte": since}}` does not type-check and P2 still needs builders. Collection names are strings, and nothing is checked against a schema |
| A string form `mongo "notes.find({tags: {tag}})"` | `{}` would mean both "document" and "parameter"; mongosh writes values as bare variables, so the natural `{tags: tag}` would be an error; quotes inside quotes; and the compiler parses the string anyway, so it gains nothing over native syntax |
| A Khrip-native query DSL (`from n in notes where ...`) | New language for the model to learn; aggregation coverage would be poor; MongoDB knowledge in the model is wasted |
| `id` ↔ `_id` renaming | Magic that breaks when both exist; MongoDB-backed APIs commonly expose `_id`; one name everywhere is simpler |
| none written as null (PR) | Breaks the PATCH idiom (В2); null vs missing differs for sparse/unique indexes |
| none silently dropping filter conditions (review sketch) | Turns `deleteMany({owner: o})` into "delete all" when o is none (measured) |
| MongoDB's `returnDocument: "before"` default | PUT/PATCH code wants the new version almost always; the old default silently returns stale data |
| `try` prefix for the explicit form | `else e` reuses Khrip's `else` and keeps `try/catch` in the habits list as "not Khrip" |
| Date as a new Khrip type | Khrip time is `int` seconds; a storage hint on the collection gives the BSON Date without touching `now()` or PostgreSQL |
| Raw bytes for BSON Binary | v0.13 makes `to_json` and KHRIP_DATA replace invalid bytes; base64 is lossless and is what JSON APIs send |

---

## 12. Review findings resolved by the forms

| Finding | Resolution |
|---|---|
| К1 cursor in store | No cursor values in user code (§7.3); the library type stays banned from store (low-level) |
| В1 nested `Bson` | No `Bson` values in the forms; documents are literals |
| В2 none → null | §3.4: none never stored; `$set` keeps old values; JSON null removes |
| В3 ClickHouse injection | `ch` form: `{expr}` is always a parameter; library queries literal-only (low-level stopgap) |
| В4 ignorable errors | Fail-closed; `else e` with a mandatory read of `e`; no result structs in the forms |
| В5 cursor protocol | `find` drains; `for` iterates batches correctly |
| В6 insert types | INSERT plan from DESCRIBE with range checks; startup errors for missing columns and nullability (§3.3) |
| С2 strict numbers | Widening table §3.1 (low-level) |
| С3/Н6 UTF-8 | Strict at `str` conversion with field path (§3.7) |
| С8 names in every program | Only `collection`/`db`/`ch` forms and two builtins; drivers linked on use |
| С9 leaked cursors | Request-end killCursors (low-level) plus `for` break handling |
| С10 exclusive lock | Forms are store-neutral in `rw` analysis |
| С11 binary in str | Binary ↔ base64; D9 rows (§3.7) |
| С12 lock windows | One audited exchange per driver, request built before release (§7.2) |
| С13 ObjectId, JSON of wrappers | `ObjectId` type, hex in JSON and paths, `object_id()` |
| С14 options, indexes | URI options (low-level), method options and chains, declared indexes |
| С15/С16 prompt and tokens | 613-token section; P1–P3 744 tokens vs PR 1,869 and Go 3,063 |
| Н2 positional traps | Options are named (`{upsert: true}`, `.limit(n)`) |
| Н5 naming, shared error slot | One `DbError` value scoped to its block; no `bson_error()`/`ch_error()` in user code |
| Н9 NULL parameters | `{x} IS NULL` Bool rewrite; Nullable parameters `\N` (measured to work on 25.8) |
| Н11 DateTime64 units | DateTime64(p > 0) into `int` is a startup error |
| Н12 abandoned server work | `max_execution_time` from the remaining budget, async `KILL QUERY` on timeout |

---

## 13. Questions for the owner

1. Is `db.` acceptable as the MongoDB root (mongosh habit), or should it be `mongo.`? The token cost is the same.
2. The divergences in §8.6 risk 3: are they acceptable? (`findOneAndUpdate` returns the new version; none never stored; `$regex` values literal.)
3. Should step A (`ch` form) ship first and alone? It closes В3/В6 with ≈ 1,750 lines, independently of MongoDB.
4. Should `else e` extend to `sql` and `tx` now (§1.4)? It is the one convention for all three forms, but it is a PostgreSQL change too.
5. Should PostgreSQL `bytea` move to base64 `str` with UTF-8 step E (§3.7), for one binary rule across databases?
