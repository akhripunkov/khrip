# Khrip: schema-first MongoDB and ClickHouse

**Angle.** Schema-first: the Khrip type of a top-level declaration is the schema of the stored data. Routes get typed operations on declared collections and tables; they never see a client, a cursor, a `Bson` value or a result struct with an error field.

**Status.** Design for review. Nothing here is implemented. It sits on top of the low-level layer that another team is fixing now (BSON validated once, `to_bson` embeds `Bson` and omits none, numeric widening, UTF-8 checked at `str` conversion, `object_id()`, killCursors at request end, URI options, find options, `mongo_create_indexes`, ClickHouse inserts encoded for the real column types through a cached DESCRIBE, column plans, FIFO admission, TLS fix, drivers linked only when used). §11 lists what this design needs from that layer.

**Base.** main at 361c8e9 plus the uncommitted low-level work visible in /home/user/khrip (read only). The server behaviour quoted below was probed on MongoDB 8.0.34 (standalone) and ClickHouse 25.8.33; the probes are in Appendix A. Token counts use bench/tokens/count.mjs (code without comments) and spec_tokens.mjs (whole file), o200k first, the public Claude tokenizer in parentheses.

---

## 0. Summary

| Question | Decision |
|---|---|
| Binding | `collection notes: Note` and `table events: Event` are top-level declarations, like `store`. The connection comes from `MONGODB_URI` / `CLICKHOUSE_URL` (the database is in the URL). More connections: `mongodb archive = expr`, `clickhouse metrics = expr`, then `in archive`. A collection or table is not a value: it cannot be stored, passed or assigned. |
| Mongo reads | `notes.find(filter, Find {...})` gives `[T]`; `notes.one(filter)` gives `T?`, or `T` (none → 404) when `T` is expected; `count`, `distinct`, `aggregate(filter, [stages])`. A smaller struct as the expected type is a projection. |
| Filters | A lambda with the meaning of `list.filter`, translated at compile time into a MongoDB query. Sub-expressions that do not mention the lambda parameter are evaluated in Khrip and sent as typed BSON values. |
| Mongo writes | `insert(v)` gives `v` back; `update(filter, change)` gives the matched count, or the document after the change (findAndModify) when a struct is expected; `upsert`, `replace`, `delete`. A struct change has `SET {patch}` semantics; `{...}` holds update operators. |
| One document | Every operation that returns one document (`one`, `update`/`upsert`/`delete` into a struct) needs a filter that is unique by the declarations (`id`, a `unique` index) or a `Find { sort }`. Checked at compile time. |
| Document literals | `{"$inc": {"views": 1}}` and pipeline stages are target-typed literals: keys come only from string literals, update keys and value types are checked against `T`, runtime strings in expression stages are wrapped in `$literal`. Injection of operators or field paths cannot be expressed. |
| ClickHouse | `ch "..."` is `sql` for ClickHouse: the same lexer, `{expr}` is a typed server parameter (`{p1:Int64}`), the result type comes from the annotation or the route. `events.insert(rows)` is encoded for the real column types. DDL lives in `migration ch N`. |
| Errors | Fail-closed, as `sql`: duplicate 409, bad value 400, `T` without a document 404, database down 503 (Retry-After), unknown write outcome or program bug 500. `let n: T? = C.insert(v)` gives none on a duplicate. `DbResult` as the expected type is the explicit form, one type for both databases. |
| Types | No new Khrip types. int, float, bool, str, lists, structs, `map[str, V]`, enums map directly; a `T?` field with none is not stored. Storage overrides in the declaration block: `date`, `objectid`, `int32`, `binary` (base64 str), `uuid`; `decimal` in phase 2. |
| `_id` | The Khrip field `id` is stored as `_id`. `object_id()` returns a new 24-digit hex str, time-ordered. It is stored as a BSON string unless the block says `id: objectid`. |
| Startup | MongoDB: connect, create (or, in check mode, verify) declared indexes, compare a collection validator with `T`, decode one stored document (warning on mismatch). ClickHouse: connect, migrations, DESCRIBE every declared table and every `ch` query (sample parameters), build the encode/decode plans once. |
| Tests | `khc test` uses `KHRIP_TEST_MONGODB_URI` / `KHRIP_TEST_CLICKHOUSE_URL` (falling back to the production variables), in temporary databases dropped at the end. |
| Transactions | No MongoDB or ClickHouse transactions. Both stay forbidden inside PostgreSQL `tx`. The documented idiom is a conditional update plus the count. |
| Runtime | No user-visible cursors (K1, В5 disappear). Typed operations never write into user-reachable objects. Values are encoded before the store-lock window; inside it only the exchange and decoding into fresh arena memory above `hi` happen. |
| Prompt | KHRIP.md section: 658 o200k (695 Claude), replacing the PR paragraph of 124 (138). KHRIP.md grows 4078 → 4612 o200k. |
| Evidence | P1 247 o200k (PR API 742, Go 1184, PostgreSQL 318); P2 281 (703, 990); P3 243 (424, 889). Go/Khrip is 3.5–4.8 here against 1.4–2.1 with the PR API (2.31 on the PostgreSQL eval tasks). |

### 0.1 Review findings and where they go

| Finding | Resolution in this design |
|---|---|
| К1 cursor in store | There is no cursor value. Collections are not values. Streaming loops keep the cursor in a hidden local (§7.3). |
| В1 `Bson` inside `to_bson` | Users never build `Bson`. Document literals nest by syntax (§1.5). |
| В2 none written as null | A `T?` none is never stored; a struct update changes only fields that were sent; an explicit JSON null unsets an optional field and is 400 for a required one (§3.4). |
| В3 ClickHouse injection | `ch "..."` takes `{expr}` only as a typed server parameter; table names, ORDER BY and LIKE follow the `sql` rules (§2). The ClickHouse form `{x:Int64}` is a compile error with a hint. |
| В4 errors ignored | Fail-closed by default; reads used as statements are errors; an unread `DbResult` is an error (§4). |
| В5 cursor protocol | No cursor protocol in user code; `find` drains, `for` streams (§7.3). |
| В6 insert only Int64/Float64/Bool/String | Inserts are encoded through the DESCRIBE plan (low-level team) and checked at start against `T` (§3.6, §6.2). |
| С2 strict numbers | Widening on read (low-level team), documented in §3.2. |
| С3 invalid UTF-8 kills a batch | Checked per value at `str` conversion; the error names collection, `_id` and field (§3.8). |
| С11 binary in `str` | No `Bson`, `BsonBinary` or raw byte strings reach user code from MongoDB; `binary` fields are base64 text; ClickHouse `String` stays raw bytes as in D9 (§3.8). |
| С13 ObjectId, JSON of wrappers | `object_id()`; ids are plain strings in Khrip, JSON and routes; `id: objectid` for interop (§3.3). |
| С14 options, indexes | `Find { sort, skip, limit }`; indexes declared in the collection block and created at start (§1.2, §6.1). URI options are the low-level team's. |
| С15/С16 prompt and tokens | §9, §10. |
| Н2 positional traps | No positional options: `Find { ... }` fields are named; no boolean arguments anywhere. |
| Н5 naming, shared error slot | One naming scheme (`MONGODB_URI`, `CLICKHOUSE_URL`, `DbResult`); no `bson_error()`/`ch_error()` slot in the typed API: every failure is either the request's status or a field of the `DbResult` it belongs to. |

---
## 1. Surface

### 1.1 Declarations

All new words are contextual: they are keywords only at the start of a top-level declaration (like `every` and `migration` today, src/decl.kh:741-746), so existing programs that use `table`, `collection` or `ch` as names keep compiling.

```
collection_decl := "collection" NAME ":" TYPE ["in" CONN] ["at" STRING] [coll_block]
table_decl      := "table" NAME ":" TYPE ["in" CONN] ["at" STRING] [table_block]
conn_decl       := ("mongodb" | "clickhouse") CONN "=" EXPR      // EXPR: str or str?, evaluated once at start
migration_decl  := "migration" [CONN] INT STRING                  // no CONN: PostgreSQL, as today
ch_query        := "ch" [CONN] STRING                             // STRING: "..." or `...` starting on the same line
coll_block      := "{" { coll_item NEWLINE } "}"
coll_item       := "index" keys | "unique" keys | "ttl" PATH [INT UNIT] | PATH ":" STORAGE | "validate"
keys            := ["-"] PATH { "," ["-"] PATH }
PATH            := IDENT { "." IDENT }                             // Khrip field names of TYPE
STORAGE         := "date" | "objectid" | "int32" | "binary" | "uuid" | "decimal"
UNIT            := "ms" | "s" | "min" | "h" | "d"                  // as in every
table_block     := "{" { "async_insert" NEWLINE } "}"
```

- `TYPE` is a struct (not a variant type). Its fields may be int, float, bool, str, enums, structs, lists, `map[str, V]`, `map[int, V]` and optionals of these; variants with payload are stored as in JSON (an object with `"type"`). ClickHouse rows are flat: §3.6.
- Default connections: `mongodb` reads `MONGODB_URI`, `ch` reads `CLICKHOUSE_URL`. Writing `mongodb mongodb = env("MONGODB_URI") ?? "mongodb://127.0.0.1/app"` gives the default connection a fallback; `clickhouse ch = ...` likewise.
- `at "db.coll"` / `at "coll"` names the database object when it differs from `NAME` or lives in another database of the same server. Without `at`, the collection or table is called `NAME` and lives in the connection's database.
- `migration ch 1 \`...\`` runs ClickHouse DDL on the default ClickHouse connection; `migration metrics 1 \`...\`` on a declared one. PostgreSQL `migration 1` is unchanged. Each connection has its own numbering.
- Names of collections, tables and connections share the global namespace with functions, types, globals and stores (duplicate-name errors as today).

### 1.2 The collection block

```khrip
collection users: User {
    unique email                 // unique index on email
    unique org, login            // compound unique index
    index org, -created          // compound index; - is descending
    ttl expires                  // delete a document when expires (unix seconds) has passed
    born: date                   // store this int (unix seconds) as a BSON Date
    manager: objectid            // store this str (24 hex digits) as an ObjectId
    avatar: binary               // this str is base64 text; stored as BSON Binary
    validate                     // phase 3: install a $jsonSchema validator made from User
}
```

| Item | Effect |
|---|---|
| `index a, -b` | Index `{a: 1, b: -1}`, name as the official drivers make it (`a_1_b_-1`). Paths are Khrip names (`id` is `_id`, `address.city` is nested). |
| `unique a[, b]` | The same with `unique: true`. When a key field is optional (`T?`), the index gets `partialFilterExpression: {a: {$type: <BSON type of a>}}`, so documents without the field (none) do not collide. Probe A.1: a plain unique index on an absent field fails the second insert with `E11000 ... dup key: { phone: null }`. |
| `ttl f [N unit]` | Single-field index on `f` with `expireAfterSeconds: N` (0 without a duration; `ttl created 30 d` deletes 30 days after `created`). `f` must be an `int` field; it is stored as a BSON Date automatically (TTL works only on dates). |
| `f: date` | `int` (unix seconds) ↔ BSON Date (milliseconds). Also allowed on `str`: ISO text as `time_iso` ↔ Date. |
| `f: objectid` | `str` (24 hex digits, any case on input, lower case on output) ↔ ObjectId. |
| `f: int32` | `int` ↔ Int32, for collections whose validator demands `int`; values outside Int32 → 400. |
| `f: binary` | `str` holding base64 (standard alphabet, padded) ↔ Binary subtype 0. |
| `f: uuid` | `str` in canonical 8-4-4-4-12 form ↔ Binary subtype 4. |
| `f: decimal` | Phase 2: `str` decimal text ↔ Decimal128. Until then a Decimal128 field is a startup warning and a 500 on read with a hint to store int cents. |
| `validate` | Phase 3: at start, `collMod` with a `$jsonSchema` generated from `T` and `validationLevel: "moderate"`. |

Overrides apply to the field wherever it appears: stored documents, filters (`u.created >= since` sends a Date), update operators, sort keys, projections and indexes. Paths into lists of structs are allowed (`items.sku: objectid`).

### 1.3 MongoDB operations

`C` is a collection of type `T`; `P` is any struct whose fields are a subset of `T`'s fields (same names, same types or their optionals); `f` is a filter lambda (§1.4); `chg` is a change (§1.5).

| Call | Result by expected type | Wire |
|---|---|---|
| `C.find()`, `C.find(f)`, `C.find(Find {...})`, `C.find(f, Find {...})` | none or `[T]`: `[T]`; `[P]`: `[P]` with a projection | `find` + `getMore` until the cursor ends |
| `C.one(f)`, `C.one(f, Find { sort })` | `T` / `P`: the document, none → 404; `T?` / `P?`, no expected type, or followed by `else`/`??`: optional | `find` with `limit: 1` |
| `C.count()`, `C.count(f)` | `int` | `count` |
| `C.distinct(x => x.path)`, `C.distinct(x => x.path, f)` | `[E]`, E the element type of the path (lists are unwound) | `distinct` |
| `C.aggregate([stages])`, `C.aggregate(f, [stages])` | `[R]`, `R?` or `R` (none → 404); no expected type is an error | `aggregate` with `cursor: {}`, drained |
| `C.insert(v)` with `v: T` | none or `T`: `v`; `T?` or followed by `else`/`??`: none on a duplicate key; `DbResult` | `insert` |
| `C.insert(vs)` with `vs: [T]` | none or `[T]`: `vs` (ordered; a duplicate ends the request with 409 after the earlier documents were written); `DbResult`: unordered, every document is tried | `insert` |
| `C.update(f, chg)` | none or `int`: matched count (all matching documents are changed); `T`/`P`: the document after the change, none → 404; `T?`/`P?`: or none; `DbResult` | `update` with `multi: true`; `findAndModify` with `new: true` |
| `C.update(f, chg, Find { sort })` | `T`/`T?`/`P`/`P?` only: changes the first match by `sort` ("claim the next job") | `findAndModify` with `sort` |
| `C.upsert(f, chg)` | none: nothing (every matching document is changed, or one is inserted); `T`/`P`: the document after (never none; unique filter); `DbResult` | `update` with `multi: true, upsert: true`; `findAndModify` with `upsert`, `new` |
| `C.upsert(v)` with `v: T` | none or `DbResult` | `update {_id: v.id}` with `$set`/`$unset` of every field, `upsert: true` |
| `C.replace(v)` with `v: T` | none or `int`: matched (0 or 1); `DbResult` | `update {_id: v.id}` with `$set`/`$unset` of every field |
| `C.delete(f)` | none or `int`: deleted count; `T`/`T?`: the removed document (unique filter or `Find { sort }`); `DbResult` | `delete` with `limit: 0`; `findAndModify` with `remove` |
| `for x in C.find(...)` | phase 2: streams batches, see §7.3 | `find` + `getMore` on demand, `killCursors` on early exit |

Rules:
- Reads used as a statement (`notes.find(...)` alone) are compile errors; their only effect would be load.
- `delete()` and `update()` need a filter; to touch everything write `x => true`.
- `replace` and `upsert(v)` set every field of `T` (none fields are removed with `$unset`) and keep fields that `T` does not declare, so documents shared with other programs do not lose data. They need `T` to have `id`.
- `insert` takes `T` or `[T]` only. `id` is not generated implicitly: write `id: object_id()`. An empty-string `id` is refused (500: `notes.insert: empty id`).
- Updates never set `id` (MongoDB `_id` is immutable): a struct change skips its `id` field; `{"$set": {"_id": ...}}` is a compile error.

### 1.4 Filters

A filter is a lambda `x => condition` with the same type rules and the same meaning as in `list.filter`; the compiler translates it into a MongoDB query instead of compiling a loop. `x` has type `T` (inside `any`, the element type). Sub-expressions that do not mention `x` (locals, parameters, calls, arithmetic) are **outer values**: they are evaluated in Khrip, in order, before the query, and sent as BSON values encoded with the storage of the field they are compared with.

| Khrip in the lambda | MongoDB | Notes |
|---|---|---|
| `x.p == v` | `{p: v}` | v of type `U?` and none: never true if `p` is not optional (Khrip: a `str` is never none), `{p: null}` if `p` is optional |
| `x.p != v` | `{p: {$ne: v}}` | v none: always true for a required `p`, `{p: {$ne: null}}` for an optional one |
| `x.p < v`, `<=`, `>`, `>=` (and `v < x.p` …) | `{p: {$lt: v}}` … | int, float, str; Khrip already refuses optionals here |
| `x.p == none`, `x.p != none` | `{p: null}`, `{p: {$ne: null}}` | `p` optional (absent and null both read as none) |
| `x.p` (bool), `!x.p` | `{p: true}`, `{p: false}` | |
| `x.p == Admin` (enum) | `{p: "Admin"}` | enums are stored as their names, as in JSON |
| `x.tags.contains(v)` (list field) | `{tags: v}` | |
| `x.title.contains(v)` (str field) | `{title: {$regex: esc(v)}}` | substring, case-sensitive, not indexed |
| `x.title.starts_with(v)` | `{title: {$regex: "^" + esc(v)}}` | uses an index on `title` |
| `x.title.ends_with(v)` | `{title: {$regex: esc(v) + "\\z"}}` | |
| `x.title.lower() == v`; `x.title.lower().contains(v)` / `.starts_with(v)` / `.ends_with(v)` | `{title: {$regex: "^" + esc(v) + "\\z", $options: "i"}}`; the three regex forms above with `$options: "i"` | if `v != v.lower()` at run time the condition is false, exactly as in Khrip; not indexed |
| `x.title.matches(re)` | `{title: {$regex: "^(?:" + re + ")\\z"}}` | `re` must be a literal or `const` (checked by the v0.13 regex checker): MongoDB runs regexes with a backtracking engine |
| `xs.contains(x.p)` | `{p: {$in: xs}}` | `xs` an outer list |
| `x.tags.len() == v` | `{tags: {$size: v}}` | |
| `x.tags.len() > 0`, `!= 0`, `>= 1` | `{"tags.0": {$exists: true}}` | other comparisons on `len()` are compile errors |
| `x.items.any(i => cond)` | `{items: {$elemMatch: <cond>}}` | `cond` is a filter over the element type; on scalar lists `i > 5` becomes `{$elemMatch: {$gt: 5}}` |
| `x.attrs["color"] == v` (map field, literal key) | `{"attrs.color": v}` | the key must be a literal without `.` and `$` |
| `a && b`, `a \|\| b`, `!a` | `$and`, `$or`, `$nor` | `&&` of different fields merges into one document |
| outer `bool` sub-expression | folded at run time | `tag == none \|\| x.tags.contains(tag)`: `true \|\| _` is `{}`, `false \|\| B` is `B` |
| `true` | `{}` | |
| no filter | `{}` | `find()`, `count()` |

Paths map Khrip names to stored names: `x.id` is `_id`, `x.address.city` is `"address.city"`. A whole filter that folds to false is sent as `{_id: {$in: []}}` (probe A.3: matches nothing, uses the `_id` index); `find`/`one` skip the round trip entirely in that case.

Anything else that mentions `x` is a compile error (§8.3): comparing two fields, arithmetic on fields, other methods on fields, `if`/`match` inside the filter, `len()` of a str. The message lists what is supported and suggests reading and filtering in Khrip.

Differences from in-memory Khrip that remain, all documented: `$regex` with `i` folds case with PCRE rules, not Khrip's simple mapping (they agree on ASCII and on Latin/Cyrillic/Greek letters); `\w` in `matches` is ASCII in PCRE and Unicode in Khrip v0.13. On documents that do not conform to `T` (written by others), `$ne`/`$nor` also match documents where the field is missing; the startup sample check (§6.1) is what catches such data.

### 1.5 Changes and document literals

A **change** (the second argument of `update`/`upsert`) is either:
- a **struct** `S` whose fields are fields of `T` (same type or its optional): `$set` of every field of `S` except `id`; an optional field of `S` is set only if it has a value, unset (`$unset`) if the request sent an explicit JSON null and `T`'s field is optional, and 400 `missing value: notes.title` if the request sent null for a required field; a none that was not sent leaves the field alone. This is `SET {patch}` (src/sql.kh:1810-1828, `__json_null_sent`, lib/api.kh:1202). The update document is never empty: at least `{$set: {}}` is sent, because an operator-free document would replace the whole document;
- a **document literal** with update operators.

A **document literal** is `{` STRING `:` value, ... `}` where a document is expected: the change of `update`/`upsert`, and each element of the stage list of `aggregate`. Inside it, a value is a nested literal `{...}`, a list literal `[...]` of values, or any Khrip expression. Keys must be string literals or `const`s; a key can never come from data. A `map[str, V]` *value* is allowed (it becomes a document); its keys are checked at run time and a key that starts with `$` is a 400.

Checks against `T` (compile time):

| Operator | Key | Value |
|---|---|---|
| `$set`, `$setOnInsert` | a path of `T` (dotted; `items.$.qty` and `items.$[].qty` when the filter matches `items` through `any`) | the field's type; for an optional field also `U?`, where none means `$unset` (`$set`) or "not set" (`$setOnInsert`) |
| `$unset` | an optional field, or one with a default | any literal (`""`, `1`, `true`) |
| `$inc`, `$mul` | an int or float field, not optional | the same number type (an int literal is fine for float) |
| `$min`, `$max` | an int, float or str field | the same type |
| `$push`, `$addToSet` | a list field `[E]` | `E`, or `{"$each": [E...], "$slice": int, "$position": int, "$sort": 1 / -1 / {...}}` |
| `$pull` | a list field `[E]` | `E`, or for struct elements a literal over `E`'s fields |
| `$pullAll` | a list field `[E]` | `[E]` |
| `$pop` | a list field | the literal `1` or `-1` |
| `$currentDate` | a `date` field | `true` |
| `$rename`, `$bit`, top-level non-operator keys | — | compile errors |

Other `$`-operators are compile errors with a did-you-mean (`$sett` → `$set`). Optional values (`U?`) are compile errors everywhere in a literal except `$set`/`$setOnInsert` values of optional fields: there is no silent choice between "null" and "absent".

**Pipelines.** `aggregate(f, [stages])` sends `{$match: <f>}` first (when `f` is given), then the stages. Stage names are checked against the list of MongoDB stages (`$match $group $sort $limit $skip $project $unwind $lookup $count $addFields $set $unset $replaceRoot $replaceWith $facet $bucket $bucketAuto $sortByCount $sample $unionWith $densify $fill $setWindowFields $graphLookup $redact $out $merge`); `$where`, `$function` and `$accumulator` are compile errors (server-side JavaScript). The compiler tracks the document shape through the stages it understands:
- before the first reshaping stage (`$match`, `$sort`, `$limit`, `$skip`, `$unwind`, `$addFields`/`$set` keep `T`'s fields), every `"$field"` string literal and every `$match`/`$sort` key must be a path of the current shape (`"$amout"` → `Order has no field amout`; probe A.4 shows a misspelt `$sum` field silently gives 0);
- after a `$group`, `$project`, `$count` or `$replaceRoot` with literal keys, the shape is those keys; a later `$sort` key or `"$field"` is checked against it;
- if the shape is known at the end of the pipeline, every field of the result type `R` without a default must be in it (`_id` ↔ `id`), as `sql` demands a column for every such field (lib/db.kh:1023);
- after `$lookup`, `$facet` or a non-literal stage the shape is unknown and checks stop.

In stages other than `$match`, every value that is not a literal (any Khrip expression) is sent as `{"$literal": value}`. Probe A.5: `{"$addFields": {"label": s}}` with `s = "$secret"` copies the secret field into `label`; with `$literal` it is the text `$secret`.

### 1.6 Find options

```khrip
type Find { sort: str = "", skip: int = 0, limit: int = 0 }     // library type, linked with the drivers
```

- `Find {...}` must be written as a struct literal in the call. `sort` must be a string literal, a `const`, or a local whose value comes from string literals through `if`/`match` (the `ORDER BY {o}` rule, src/sql.kh:1664-1680); every variant is parsed at compile time: comma- or space-separated Khrip paths, `-` for descending, checked against `T` (`sort: "-creatd"` → `Note has no field creatd, did you mean created?`) and compiled into a constant BSON sort document.
- `skip` and `limit` are any int expressions; negative values are a 400 at run time (`limit must not be negative`); `limit: 0` means no limit.
- `skip` without `sort` is a compile error: pages in natural order are not stable.
- In `one`, `update`, `delete` and `upsert`, `Find` may only carry `sort` (the first match by that order).

### 1.7 ClickHouse

```khrip
migration ch 1 `
CREATE TABLE events (ts DateTime DEFAULT now(), user_id UInt64, page LowCardinality(String), ms Float32)
ENGINE = MergeTree ORDER BY (page, ts)
`
table events: Event { async_insert }       // block optional

events.insert(rows)                        // rows: [S] or one S; S is Event or a struct of some of its fields
let top: [PageStat] = ch `SELECT page, count() AS views FROM events
    WHERE ts >= {from} AND page IN {pages} GROUP BY page ORDER BY views DESC LIMIT {n}`
let n: int = ch "SELECT count() FROM events WHERE user_id = {uid}"
ch "ALTER TABLE events DELETE WHERE ts < {cutoff}"
```

| Form | Result by expected type |
|---|---|
| `t.insert(rows)` | none: nothing; `DbResult` |
| `ch "SELECT ..."` (or `WITH ...`) | as `sql`: `[R]` all rows; `R?` one row or none (more → 500); `R` one row, none → 404; a scalar type for one column; no expected type → compile error |
| `ch "INSERT INTO t SELECT ..."` | none; `int`: written rows (from `X-ClickHouse-Summary`); `DbResult` |
| `ch "ALTER TABLE ... DELETE/UPDATE ..."`, `TRUNCATE`, `OPTIMIZE` | none; `DbResult` |

- `{expr}` is always a server-side parameter `{pN:Type}` with `Type` from the Khrip type (§2.2). The query text and the values travel separately; nothing is ever spliced into SQL.
- The `sql` rewrites apply: `'%{q}%'` becomes `concat('%', {pN:String}, '%')` and the value's `\`, `%`, `_` are escaped when the literal is a LIKE/ILIKE pattern (probe A.6: unescaped `_` matches any character); `IN ({xs})` and `IN {xs}` both take a list as `Array(T)`; `ORDER BY {o}` takes literal variants; `{x}` in a table-name position is an error; `col = {x}` with an optional `x` needs `({x} IS NULL OR col = {x})`.
- Not allowed in `ch`: `CREATE`, `DROP`, `RENAME`, `ATTACH`, `DETACH`, `ALTER TABLE ... ADD/DROP/MODIFY/RENAME COLUMN` (put them in `migration ch N`); `FORMAT` (rows are read as RowBinaryWithNamesAndTypes); several statements; `INSERT INTO t VALUES`/`INSERT INTO t {rows}` (use `t.insert(rows)`); database-qualified table names other than `system.*` (the connection's database is used, and `khc test` replaces it).
- `async_insert` in the table block sends inserts with `async_insert=1, wait_for_async_insert=1`: the call returns after the server flushed the batch. Fire-and-forget (`wait_for_async_insert=0`) is not offered.
- `migration ch N` runs once, in order, recorded in `khrip_migrations` (a MergeTree table in the connection's database), exactly like PostgreSQL migrations; never edit one that ran.

### 1.8 Library types and functions the AI sees

```khrip
type Find { sort: str = "", skip: int = 0, limit: int = 0 }
type DbResult {
    ok: bool               // the whole operation succeeded
    status: int            // the status the default form would have answered (200 when ok)
    code: int              // server error code: MongoDB code or ClickHouse exception code; 0 if none
    error: str             // message, "" when ok
    count: int             // documents inserted / matched / deleted, rows written
    unknown_outcome: bool  // the write may have been applied (reply lost): do not retry blindly
    errors: [DbError]      // per-document errors of an insert of a list
}
type DbError { index: int, code: int, error: str }
fn object_id() -> str      // 24 lower-case hex digits: 4 bytes time, 5 random per process, 3 counter
```

These names exist only in programs that declare a collection or a table (drivers linked only when used). A user type with the same name is a compile error naming the clash.

### 1.9 What stays below

The low-level API (`Mongo`, `mongo_command`, `bson_*`, `ChConfig`, `ch_query_params`, ...) stays in the library for system code and rare commands (`collMod`, `listCollections`, `dropIndex`, `SYSTEM ...`). It is documented in DATABASES.md under "Low-level API" and is not in KHRIP.md. The typed layer calls only `__`-prefixed entry points of it.

---
## 2. Parameters and injection

### 2.1 MongoDB: nothing from data can become an operator or a field path

| Channel | Why injection cannot be expressed |
|---|---|
| Filters | The compiler produces the query structure from the lambda; data enters only as outer values. An outer `str` is always a BSON string, never parsed. Regexes are built from `esc(v)` (every regex metacharacter backslash-escaped) for `contains`/`starts_with`/`ends_with`; `matches` takes only compile-time patterns. Field names come only from Khrip field names. |
| Document literals | Keys are string literals or `const`s. A `map[str, V]` value with a `$`-prefixed key is refused at run time (400 `bad value: notes.attrs: a key cannot start with $`). Runtime strings in expression stages are wrapped in `$literal` (probe A.5), so `"$secret"` from a client cannot read another field. `$where`, `$function`, `$accumulator` do not compile. |
| Struct values (insert, replace, patch) | Encoded from the type descriptor: keys are the struct's field names; map keys are checked as above. |
| Sort, projection, indexes | Compile-time constants built from Khrip field names. A sort chosen by the client goes through literal variants (`let s = match q { "new" => "-created", _ => "title" }`). |
| Collection and database names | Declarations only; never values. |

### 2.2 ClickHouse: `{expr}` is a typed server parameter

The lexer of `ch` strings is `lex_sql` (src/lex.kh:628) with a flag; it already knows SQL quotes, comments, `$tag$` strings and `{}`/`{3}`/`{1,2}` as text. Each `{expr}` becomes `{pN:Type}` in the query text and `param_pN=<escaped value>` in the HTTP query string (the low-level `__ch_param` escaping, lib/clickhouse.kh:68). `Type` comes from the Khrip type of the expression:

| Khrip | ClickHouse parameter type | Value text |
|---|---|---|
| `int` | `Int64` | decimal |
| `float` | `Float64` | shortest round-trip text; `nan`, `inf`, `-inf` |
| `bool` | `Bool` | `true` / `false` |
| `str` | `String` | escaped bytes |
| enum | `String` | the variant name |
| `[T]` | `Array(T')` | `[v1,v2]` with quoted strings |
| `map[str, V]` | `Map(String, V')` | `{'k':v}` |
| `T?` | `Nullable(T')` | `\N` for none (fixes Н9: the PR doubled the backslash) |
| struct, list of structs | — | compile error: `a struct cannot be a ClickHouse parameter; insert rows with events.insert(rows)` |

ClickHouse converts these parameters where the query needs another type: probes A.6 show `DateTime >= Int64`, `DateTime64 >= Int64`, `UInt32/UInt64/Int32 = Int64`, `Float32 < Float64`, `Decimal < Float64`, `LowCardinality(String) = String`, `x IN {a:Array(Int64)}`, `LIMIT {n:Int64}`, `INTERVAL {n:Int64} DAY`, `toDate({t:Int64})` all work. One common case does not: `Date >= Int64` is `ILLEGAL_TYPE_OF_ARGUMENT`. It is caught by the startup DESCRIBE (§6.2) with the hint `compare a Date column with toDate({x})`.

The `sql` rules carry over unchanged, with their messages (src/sql.kh): table-name positions (`FROM {t}`), `ORDER BY {o}` from literal variants (at most 16), optional comparisons without `IS NULL`, `ch` in the initial value of a global, the result type required for a SELECT. The ClickHouse-native placeholder `{from:Int64}` inside a `ch` string is a lexer error with a hint (§8.3), so the habit from the ClickHouse docs fails loudly instead of being parsed as a Khrip expression `from:Int64`.

---

## 3. Types and mapping

### 3.1 Principles

1. The Khrip type is the schema. Encoding follows the declared type and the block's storage overrides; decoding accepts exactly the stored types that the declared type could have written, plus lossless numeric widening.
2. Nothing is implicit across comparison classes. In MongoDB a string, an ObjectId and a Date never compare equal (probe A.7: the string `"65a1…"` does not find a document whose `_id` is that ObjectId). A stored type that differs from the declaration is a loud decode error with a fix, not a silent conversion.
3. No new Khrip types. Storage choices live in the declaration (schema-first), not in the type system: `created: date` in the block, `created: int` in the struct.

### 3.2 MongoDB, Khrip → BSON (write) and BSON → Khrip (read)

| Khrip field | Writes | Reads | Read error (500, logged with collection, `_id`, path) |
|---|---|---|---|
| `int` | Int64 | Int64, Int32, Double with an integral value in range | fractional Double, NaN, ±Inf, out of range, other types |
| `int` + `int32` | Int32 (out of range → 400) | as `int` | |
| `int` + `date` | Date (seconds × 1000; values above 10^11, i.e. after year 5138, are 400 `looks like milliseconds`) | Date (milliseconds ÷ 1000, floor) | a non-Date |
| `float` | Double | Double, Int32, Int64 exactly representable | Int64 that Double cannot hold |
| `bool` | Boolean | Boolean | |
| `str` | String (invalid UTF-8 → 400, D9) | String (UTF-8 checked here, with the path) | invalid UTF-8; ObjectId (`add id: objectid`), Date (`add f: date`), Binary (`add f: binary`) |
| `str` + `objectid` | ObjectId (24 hex digits, else 400; in a filter a non-hex value can never match, so the condition is false) | ObjectId → lower-case hex | |
| `str` + `date` | Date from ISO 8601 (`parse_time`; else 400) | Date → `time_iso` text | |
| `str` + `binary` | Binary subtype 0 from base64 (else 400) | Binary (subtype 0 or 2) → base64 | |
| `str` + `uuid` | Binary subtype 4 from `8-4-4-4-12` hex (else 400) | Binary subtype 4 or 3 → canonical text | |
| enum | String (variant name) | String naming a variant | unknown name |
| variant type | Document with `"type"` and the variant's fields (as JSON) | same | |
| `[T]` | Array | Array (each element as `T`) | |
| struct | embedded Document | Document; missing fields take their defaults, missing optional fields are none | a missing required field (`add a default or make it T?`) |
| `map[str, V]` | Document (keys starting with `$` → 400) | Document | |
| `map[int, V]` | Document with decimal keys | Document with decimal keys | |
| `T?` | value, or **nothing** when none | absent or Null → none | |
| `id` (any type) | key `_id` | key `_id` | |

Fields of a stored document that `T` does not declare are ignored on read and kept by `replace`/`upsert(v)` (they use `$set`/`$unset`). Decimal128, JavaScript, MinKey/MaxKey, DBPointer and Timestamp values are read errors unless the field is phase-2 `decimal`; the error says which BSON type was found.

### 3.3 `_id` and ObjectId

- The Khrip field `id` is stored as `_id` in every MongoDB encoding and decoding: collection types, projections, aggregate results (`$group` output `_id` reads into `id`), filters (`x.id` is `_id`), sort and index paths (`id` is `_id`). A struct that has both `id` and `_id` is a compile error. A field written `_id` is accepted as-is (programs that copied MongoDB habits keep working), but KHRIP.md teaches `id`.
- `object_id()` returns a new ObjectId as 24 lower-case hex digits (time, process random, counter), so ids sort by creation time and `Find { sort: "id" }` is insertion order.
- By default an `id: str` is a **BSON string**. A Khrip program that owns its data needs nothing else, and foreign keys (`note_id: str` holding a note's id) compare equal in `$lookup` too.
- Collections written by other programs usually hold ObjectIds. `id: objectid` (and `user_id: objectid` for references) in the block makes the field an ObjectId on the wire while it stays a `str` in Khrip, JSON and route parameters. If the declaration is missing, the first read of such a document is a 500 whose log line says `notes "65a1…": _id is an ObjectId, Note.id is str: add "id: objectid" to collection notes`, and the startup sample check prints the same as a warning before the first request (§6.1).
- Rejected alternatives: a distinct `ObjectId` Khrip type (new type kind, conversions, prompt tokens, for a value that is a string everywhere outside MongoDB); storing every 24-hex string as an ObjectId (silently changes the BSON type of unrelated strings such as hash prefixes).

### 3.4 none, null and the PATCH idiom

| Operation | `T?` field is none | Explicit JSON null in the request body |
|---|---|---|
| `insert`, `replace`, `upsert(v)` | not stored (`replace`/`upsert(v)` send `$unset`) | the same |
| `update(f, patch)` | field left as it is | `$unset` if `T`'s field is optional; 400 `missing value: notes.title` if it is required (as PostgreSQL NOT NULL) |
| `{"$set": {"note": v}}` with `v: str?` | `$unset` of `note` (requires `Note.note: str?`) | — |
| filter `x.p == v` | see §1.4 (exactly Khrip's `==`) | — |
| any other literal value | compile error | — |
| read | absent or Null → none | — |

So `notes.update(n => n.id == id, patch)` with `type NotePatch { title: str?, body: str?, tags: [str]? }` changes only what the client sent, as `sql "UPDATE notes SET {patch} WHERE id = {id}"` does, and the in-memory idiom `Note { ...old, ...patch }` followed by `notes.replace(...)` also works.

### 3.5 Dates and time

Khrip keeps time as `int` unix seconds (`now()`, `parse_time`, `parse_date`) or ISO text (`time_iso`); this design adds no time type.
- MongoDB: an `int` field is Int64 by default (range queries in Khrip work); `f: date` (or `ttl f`) stores it as a BSON Date; `f: date` on a `str` field stores ISO text as a Date. Millisecond precision: use `int` milliseconds without `date` (an Int64), or keep the default seconds.
- ClickHouse: `int` ↔ `Date`/`Date32` (seconds at midnight UTC; writes floor to the day), `DateTime` (seconds; range 0…2^32−1, else 400), `DateTime64(P)` (seconds × 10^P on write; reads floor to seconds, so DateTime64(3) and (6) are no longer indistinguishable raw numbers, Н11). `str` ↔ the same types as ISO text (`2026-10-19` for dates, `time_iso` for date-times). Sub-second values are read with `toUnixTimestamp64Milli(ts) AS ts_ms` into an `int`.

### 3.6 ClickHouse, Khrip ↔ column types

Columns are matched by name; plans are built once at start from DESCRIBE (low-level column plans).

| Khrip field | Accepted column types on insert (conversion) | Accepted on read |
|---|---|---|
| `int` | Int8…Int64, UInt8…UInt64 (range-checked: `-1` into UInt64 → 400 `events.user_id: -1 is out of range for UInt64`), Date, Date32, DateTime, DateTime64 (seconds), Decimal(P, 0), Float32/64 (exact up to 2^53), Bool (0/1) | Int8…Int64, UInt8…UInt32, UInt64 ≤ 2^63−1 (larger → 500), Date…DateTime64 (seconds), Bool, Decimal(P, 0) |
| `float` | Float32, Float64, Decimal(P, S) (rounded half-to-even to S) | Float32, Float64, all integer types, Decimal(P, S) |
| `bool` | Bool, UInt8 | Bool, UInt8 (0/1, else 500) |
| `str` | String, FixedString(N) (≤ N bytes, else 400; zero-padded), LowCardinality(String), Enum8/16 (a known name, else 400), UUID (parsed, else 400), IPv4/IPv6 (parsed), Date/DateTime (ISO, else 400), Decimal(P, S) (exact decimal text, else 400) | String, FixedString (trailing zero bytes removed), LowCardinality, Enum (name), UUID, IPv4/6, Date…DateTime64 (ISO), Decimal (exact text) |
| enum | Enum8/16 with every variant name, String, LowCardinality(String) | Enum8/16 whose names are all variants, String/LowCardinality (unknown name → 500) |
| `[T]` | Array(T') | Array(T') |
| `map[str, V]` | Map(String, V') | Map(String or LowCardinality(String), V') |
| `T?` | Nullable(T'), LowCardinality(Nullable(T')) | the same; a Nullable column read into a non-optional field is a startup error |
| non-optional `T` | also Nullable(T') | — |
| struct, variant type | — (startup error: Tuple, Nested and JSON are phase 3) | — |

Insert rules checked at start for every `table` declaration and every type `S` passed to its `insert`: each field of `S` names a column of a compatible type; a field `T?` needs a Nullable column (`none` into a plain column would silently become the type's zero value); every column that `S` does not have must have `DEFAULT`, `MATERIALIZED`, `ALIAS` or `EPHEMERAL` (a plain column would silently get `0`/`''`). Columns are sent in `S`'s field order with their names, so column order never matters.

### 3.7 Decimals

- ClickHouse `Decimal(P, S)`: read into `str` (exact text, `"12.34"`), `float` (rounded) or `int` (S = 0 only); written from `str` (exact; too many digits → 400), `int` (S = 0 or scaled exactly), `float` (rounded to S). KHRIP.md keeps "money in int cents".
- MongoDB Decimal128: phase 2 `f: decimal` maps it to exact decimal text in a `str` (BID encoding and decoding, about 200 lines). Until then a Decimal128 field is a read error naming the field and a startup sample warning.

### 3.8 Binary data (С11) and v0.13 UTF-8

The decision follows v0.13-utf8.md: user `str` is text (D2, D5); `to_json` and KHRIP_DATA replace invalid bytes (D9).
- There is no `bytes` type and no binary reaches a user `str` from MongoDB: a Binary field must be declared `f: binary` and is base64 text in Khrip, which is safe in `store`, JSON, KHRIP_DATA and routes. Reading a Binary into an undeclared `str` is a read error with the fix.
- `Bson`, `BsonBinary`, `BsonDecimal128` and `ChResult.body` are not part of the typed API, so they cannot reach `store` or `to_json` from AI-written code. (The low-level API keeps them; DATABASES.md marks them as byte strings for system code, and К1's store ban covers `MongoCursor` and `BsonBuilder`.)
- ClickHouse `String` columns are byte strings. `ch` results and inserts pass `str` bytes through unchanged, like fetch bodies and PostgreSQL `bytea` (D9 "raw"). A program that keeps binary in ClickHouse selects `base64Encode(col)`; a raw invalid sequence returned in JSON becomes U+FFFD per D9 (documented).
- MongoDB strings are UTF-8 by the BSON spec: invalid UTF-8 in a stored string is a read error (500) with collection, `_id` and path; a Khrip `str` with invalid UTF-8 written to MongoDB is a 400 (the value came from a raw source: a header, a fetch body, a ClickHouse string), matching PostgreSQL's 22021 → 400.
- Rows to add to the D9 table (v0.13-utf8.md §2): typed MongoDB reads (strict, 500 with path), typed MongoDB writes (strict, 400), `binary`/`uuid` fields (ASCII text), `ch` results and parameters (raw), `ch` inserts (raw).

### 3.9 Numbers, sizes and limits per value

- MongoDB integers widen on read (С2); `float` accepts integers that Double holds exactly.
- MongoDB documents: 16 MiB; an insert of a list is split into batches below `maxMessageSizeBytes` by the low-level layer (one `insert` command per batch, ordered). A single document above 16 MiB is a 400 `document too large: notes (17.2 MB)`.
- ClickHouse: UInt64 above 2^63−1 in a result is a 500 naming the column (select `toString(x)` into a `str`); Int128/256 and UInt128/256 are read into `str` only.

---
## 4. Errors

### 4.1 One convention

Every typed operation of both databases (and, later, `sql` if wanted) uses the same three outcomes:
1. **Success**: the value of the expected type.
2. **Failure, default form**: the request ends with a status, through the same path as `sql` (`__db_answer`, lib/db.kh:1289: `fail(status, msg)` in a request, `Retry-After: 1` on 503, a panic with the message outside a request, so `every` tasks and test code report it). 5xx failures print one stderr line with the source location, as `sql failed` does: `app.kh:14:12: mongodb failed [11600] InterruptedAtShutdown (notes.update)`.
3. **Failure, explicit form**: when the expected type is `DbResult` (`let r: DbResult = events.insert(rows)`), nothing ends the request; the result carries `ok`, `status`, `code`, `error`, `count`, `unknown_outcome`, `errors`. Only write operations and non-SELECT `ch` statements have this form; reads always fail closed.

Two small additions keep the default form usable:
- `T?` on `insert` (or `insert(...) else { }`, `?? x`) turns a duplicate key into none, as `ON CONFLICT DO NOTHING` into `T?` does for `sql`.
- `T` on `one`/`update`/`delete`/`aggregate` turns "no document" into 404, and the route must list `| 404` (the existing check, src/sql.kh:308, extended to these calls; hint `add | 404 to the route, or answer yourself: let n: Note = notes.one(...) else { return 401 }`).

### 4.2 Status mapping

MongoDB:

| Condition | Status | Response body |
|---|---|---|
| duplicate key (11000, 11001, 12582) | 409 | `already exists: users.email` (collection and key fields from `keyPattern`) |
| document validation failed (121) | 400 | `invalid document: users` (the `errInfo` details go to the log only) |
| a value cannot be encoded (invalid UTF-8, bad hex for `objectid`, bad base64/uuid/ISO time, Int32 range, date in milliseconds, `$` map key, document over 16 MiB) | 400 | `bad value: users.avatar: not base64` |
| explicit null for a required field in a patch | 400 | `missing value: notes.title` |
| negative `skip` / `limit` | 400 | `limit must not be negative` |
| `T` expected and no document | 404 | — |
| network error, timeout, pool wait over the deadline, "not primary"/shutdown codes (6, 7, 89, 91, 189, 9001, 10107, 11600, 11602, 13435, 13436), `MaxTimeMSExpired` (50), `ExceededTimeLimit` (262), authentication failure after start (18) | 503 + `Retry-After: 1` | `database unavailable, try again` |
| a write was sent and its reply was lost (`unknown_outcome`), or a `writeConcernError` came back | 500 | `write outcome unknown` (as PostgreSQL 08007) |
| a stored document does not decode into `T` | 500 | `internal error`; the log names collection, `_id`, path and fix |
| anything else (2 BadValue, 9, 14, 16, 17, 40, 66 …: a program or driver bug) | 500 | `internal error`; the log has the command name and the server message |

ClickHouse:

| Condition | Status | Response body |
|---|---|---|
| a value cannot be encoded for its column (range, Enum name, FixedString length, UUID/IP/date/decimal text) | 400 | `bad value: events.user_id: -1 is out of range for UInt64` |
| server value errors on parameters: 6, 27, 38, 41, 69, 70, 72, 321, 457 | 400 | `bad value: ` + the first line of the server message |
| `R` expected and no row | 404 | — |
| network error, timeout, admission wait over the deadline, 159 TIMEOUT_EXCEEDED, 201 QUOTA_EXCEEDED, 202 TOO_MANY_SIMULTANEOUS_QUERIES, 203, 209, 210, 241 MEMORY_LIMIT_EXCEEDED, 252 TOO_MANY_PARTS, 439, HTTP 5xx without an exception code | 503 + `Retry-After: 1` | `database unavailable, try again` |
| insert body sent and the reply lost | 500 | `write outcome unknown` |
| result above `CLICKHOUSE_MAX_RESPONSE_BYTES` | 500 | `internal error`; log: `result is larger than 64 MiB: add LIMIT or aggregate` |
| anything else (43, 47, 60, 62, 153 division by zero, 164 READONLY, 497/516 access) | 500 | `internal error`; log with the query site and the server message |

`DbResult.status` holds exactly the status the default form would have used, so explicit code can still do `fail(r.status, r.error)` after looking at the cause.

### 4.3 Unused results

- A read used as a statement (`notes.find(...)`, `notes.one(...)`, `notes.count()`, `notes.aggregate(...)`, `ch "SELECT ..."`) is a compile error: `the result of notes.find is not used` (hint: `assign it, or delete the call`).
- A local of type `DbResult` that is never read is a compile error: `r is never read, so the failures it holds are ignored` (hint: `check r.ok, or drop ": DbResult" to let failures end the request`). The compiler tracks reads of locals of this one type (a flag set by `parse_ident` on a read).
- Ignoring the count of `update`/`delete` stays legal, as for `sql "UPDATE ..."`: idempotent PUT/DELETE handlers do it on purpose. §10.4 lists it as a remaining risk (S2).

---

## 5. Configuration

### 5.1 How a program gets a database

Nothing in the program: declaring a collection or a table is enough. At start the runtime reads:

| Variable | Default | Meaning |
|---|---|---|
| `MONGODB_URI` | — (required if a collection uses the default connection) | `mongodb://user:password@host:27017/app?authSource=admin&...`; the path is the database. URI options are the low-level layer's (authSource, tls, tlsCAFile, appName, maxPoolSize, w, wtimeoutMS, journal, replicaSet, directConnection, ...). |
| `MONGODB_TIMEOUT` | 10000 | ms per operation: pool wait, exchange, all getMores of one `find` |
| `CLICKHOUSE_URL` | — (required if a table or `ch` uses the default connection) | `http(s)://user:password@host:8123/database`; no path → `default` |
| `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD` | from the URL | override the URL's credentials (secrets kept apart) |
| `CLICKHOUSE_TIMEOUT` | 30000 | ms per operation, including admission; `max_execution_time` is the remaining budget |
| `CLICKHOUSE_MAX_RESPONSE_BYTES` | 67108864 | result size limit per query |
| `CLICKHOUSE_MAX_REQUEST_BYTES` | 67108864 | insert body limit; above it the insert is a 500 telling to send batches |
| `CLICKHOUSE_MAX_INFLIGHT` | 32 | ClickHouse operations per worker thread (FIFO admission) |
| `DATABASE_MIGRATE` | `apply` | shared with PostgreSQL: `apply` runs ClickHouse migrations and creates MongoDB indexes at start; `check` only verifies them (`./app migrate` applies all three and exits) |
| `KHRIP_TEST_MONGODB_URI`, `KHRIP_TEST_CLICKHOUSE_URL` (+ `_USER`, `_PASSWORD`) | the production variables | used by `khc test` (§6.4) |

Missing variables are startup errors in the style of `__pg_startup` (lib/pg.kh:1775):
`khrip: MONGODB_URI is not set (collections notes, orders): mongodb://user:password@host:27017/database`,
`khrip: MONGODB_URI has no database: add it to the path, mongodb://host:27017/app`,
`khrip: CLICKHOUSE_URL is not set (table events, 2 ch queries): http://user:password@host:8123/database`.

### 5.2 More databases

```khrip
mongodb archive = env("ARCHIVE_MONGODB_URI") ?? "mongodb://127.0.0.1:27017/archive"
clickhouse metrics = env("METRICS_URL")
collection old_notes: Note in archive at "notes"
collection audit: Entry at "audit.entries"      // another database on the default connection
table hits: Hit in metrics
migration metrics 1 `CREATE TABLE hits (...) ENGINE = MergeTree ORDER BY ts`
let top: [Top] = ch metrics "SELECT page, count() AS n FROM hits GROUP BY page"
```

- The expression is evaluated once at start (before routes run, after `const`s); `none` is a startup error naming the expression text.
- Each connection has its own pool (pools are keyed by URI in the low-level layer). PostgreSQL, any number of MongoDB and any number of ClickHouse connections coexist.
- `khc test` maps every connection to the test server of its kind with its own temporary database.

### 5.3 Where tuning lives

- Operations: environment variables above and URI options. No `ChConfig`/`Mongo` values in programs.
- Schema-level choices: the declaration block (`async_insert`, indexes, storage overrides).
- Per call: `Find { sort, skip, limit }` only.
- Defaults: MongoDB batch sizes as the server chooses (101 documents first, then up to 16 MiB; `batchSize` is not exposed), MongoDB pool 32 per worker (URI `maxPoolSize` up to 32), ClickHouse settings sent only when needed (`input_format_*` only on inserts; nothing at all for a `readonly=1` user, detected at start with `SELECT getSetting('readonly')`, С4).

---

## 6. Startup and schema

Start order: PostgreSQL (as today), then each ClickHouse connection, then each MongoDB connection. Every check runs; all failures are printed (`file:line:col: error: ...` for sites, `khrip: ...` for declarations), then the process exits with 1, as `__db_start_here` does for `sql` (lib/db.kh:1105). Network failures are retried for up to 60 s (the database may still be starting); authentication and configuration errors are not.

### 6.1 MongoDB

Per connection:
1. Connect and authenticate; `hello` (server version 6.0 or later, else exit: `khrip: MongoDB 5.0 is not supported (6.0 or later)`).
2. Per collection, `apply` mode: `createIndexes` with the declared indexes. "All indexes already exist" is success. Conflicts (code 85 IndexOptionsConflict, 86 IndexKeySpecsConflict) exit with the declaration and the existing index:
   `app.kh:3:5: error: collection users: index email_1 exists without unique` (hint: `drop it in the database (db.users.dropIndex("email_1")) or change the declaration`).
   Indexes not in the declaration are left alone (they may belong to someone else) and listed once: `khrip: note: users has index legacy_1 that is not declared`.
   `check` mode: `listIndexes` and compare; a missing index exits with `khrip: users: index email_1 is missing (DATABASE_MIGRATE=check): run ./app migrate`.
3. Validator: `listCollections` with the collection's name. If it has a `$jsonSchema`, compare with what `T` writes: for each property with `bsonType`, the BSON type that the Khrip field (with overrides) writes must be allowed (`int` vs Int64 → `khrip: orders: the validator wants amount as int (Int32); Order.amount is written as Int64: add "amount: int32" to the block`), and each `required` property must be a non-optional field of `T` (else every insert would be a 400). Errors exit; other validator operators are not interpreted.
4. Sample: `find` with `sort: {_id: -1}, limit: 1`; decode it into `T` with the storage rules. A failure is a **warning**, not an exit (one odd old document must not stop a deployment): `khrip: warning: notes: document "65a1…" does not match Note: _id is an ObjectId, Note.id is str: add "id: objectid" to collection notes`.

`./app migrate` and `DATABASE_MIGRATE=apply` create indexes; index builds on large collections block start until built (documented; run `./app migrate` as a deploy step for big collections).

Nothing about filters, updates, sorts, projections or pipelines needs the database: those are checked at compile time against `T` (§1.4–§1.6), which is the point of declaring `T`.

### 6.2 ClickHouse

Per connection:
1. `SELECT version(), getSetting('readonly')`; remember readonly mode.
2. Migrations (`migration ch N`): `CREATE TABLE IF NOT EXISTS khrip_migrations (name String, applied DateTime DEFAULT now()) ENGINE = MergeTree ORDER BY name`, read applied names, run the missing ones in order (each migration text is one or more statements separated by `;` outside quotes, sent one per request), insert their names. A failure exits with `khrip: ClickHouse migration ch 2 failed: <server message>`. `check` mode verifies only. ClickHouse has no transactional DDL: a migration that fails half-way stays half-applied, so the message says which statement failed. Concurrent first starts of several instances can race; `./app migrate` as a deploy step avoids it (documented).
3. Each `table` declaration: `DESCRIBE TABLE t` (name, type, default_type) → for `T` and every `S` passed to `t.insert`: the checks of §3.6. The result is the insert plan (low-level column plans: per field the column type, conversion, nullable, array depth, LowCardinality), stored in permanent memory. Messages:
   `app.kh:9:1: error: table events: Event.note is str?, but column note is String (not Nullable)` (hint: `make the column Nullable(String) in a migration, or the field str`);
   `app.kh:9:1: error: table events: column country has no DEFAULT and EventIn has no field country` (hint: `add country to EventIn, or give the column a DEFAULT`);
   `app.kh:9:1: error: table events: column props is Map(String, Int32); EventIn.props is map[str, str]`.
4. Each `ch` site (each ORDER BY variant): for `SELECT`/`WITH`, `DESCRIBE TABLE (<query>)` with sample parameter values (int 1, float 1, bool true, str "", list [], none NULL) → compare with the expected type exactly as `__db_check` does for PostgreSQL (lib/db.kh:867): every field without a default needs a column of a convertible type, a Nullable column needs `T?`, extra columns are ignored, a scalar type needs one column. Messages reuse the `sql` wording: `app.kh:21:12: error: column views is UInt64, but PageStat.views is str`; `app.kh:21:12: error: PageStat.avg_ms has no column: the query returns page, views, users` (hint: `select it (or rename with AS avg_ms), or give the field a default`).
   If DESCRIBE fails with a type or name error (43, 47, 60, 62, 386, 53…) the site is an error with the server message and a hint for known cases (`(Date, Int64)` → `compare a Date column with toDate({x})`). If it fails with a value error caused by the sample values (6, 27, 38, 41, 69, 70, 72, 153, 321), the site gets a warning `not checked at start: the query fails with sample parameter values (Cannot parse date: value is too short); it is checked on its first run`, and the first run compares the RowBinary header with the expected type before decoding (probe A.8 shows both behaviours).
   For `INSERT ... SELECT`: DESCRIBE of the SELECT part and of the target table, columns matched by name. For `ALTER ... DELETE/UPDATE`, `TRUNCATE`, `OPTIMIZE`: `EXPLAIN AST` (syntax) and `EXISTS TABLE` for the table.

### 6.3 Migrations and schema changes

| Database | DDL source | Who applies | Checked against the program |
|---|---|---|---|
| PostgreSQL | `migration N` | start / `./app migrate` | every `sql` (today) |
| ClickHouse | `migration ch N` | start / `./app migrate` | every `table` and `ch` (DESCRIBE) |
| MongoDB | the collection block (indexes, later `validate`) | start / `./app migrate` (`createIndexes` is idempotent) | compile time (`T`), validator and sample at start |

Changing `T` of a MongoDB collection: a new field needs a default or `?` (old documents lack it; the sample check warns, reads of old documents would be 500). Data rewrites (backfills, renames) are written as ordinary code for now; a once-only `migration mongodb N { ... }` block that records itself in a `khrip_migrations` collection is phase 3.

### 6.4 Tests (`khc test`)

| Database | Server | Temporary database | Cleanup |
|---|---|---|---|
| PostgreSQL | `KHRIP_TEST_DATABASE_URL` else `DATABASE_URL` | schema `khrip_test_<pid>_<rand>` (today) | `drop schema ... cascade` |
| MongoDB | `KHRIP_TEST_MONGODB_URI` else `MONGODB_URI` | per (connection, database): `kt<pid><rand6>_<db>`, at most 63 bytes | `dropDatabase` |
| ClickHouse | `KHRIP_TEST_CLICKHOUSE_URL` else `CLICKHOUSE_URL` | per connection: `khrip_test_<pid>_<rand6>` | `DROP DATABASE ... SYNC` |

All migrations, indexes and startup checks run against the temporary databases, so tests also check the declarations. Tests run in order and share data, as with PostgreSQL. Test code may call the typed operations directly (`expect notes.count() == 1`; a failure inside a test panics with the message and fails the test). Without any server variable `khc test` exits with `khrip: tests use MongoDB: set KHRIP_TEST_MONGODB_URI=mongodb://user:password@host:27017/test (khc test works in its own temporary database and drops it)`.

---

## 7. Concurrency and the runtime

### 7.1 `tx`

- MongoDB and ClickHouse operations inside a PostgreSQL `tx` stay compile errors, directly, as methods and through functions (`driver_io`, src/drivers.kh:4, and `fn_effect`, src/sql.kh:416, extended: a token that resolves to a collection or table followed by `.`, and a `T_CH` token, are I/O). Message: `notes.update inside tx: the block may run again after a conflict` (hint: `call it before or after the tx block`).
- There are no MongoDB transactions: the low-level driver has no sessions, and the target deployments (probe A.9: the test server is a standalone mongod) often cannot run them. The documented idiom puts the check into the filter of one atomic update and reads the count: `orders.update(o => o.id == id && o.status == "new", {"$set": {"status": "paid"}}) == 0 → 409/404`; `update` into `T` with `Find { sort }` claims one document atomically. A future `tx` over MongoDB (sessions, replica sets, `TransientTransactionError` retries) would fit the same block syntax; it is out of scope.
- Unlike `sql`, a MongoDB write after a read outside `tx` is not a compile error, because the remedy (a conditional update) cannot always replace the read. §10.4 lists the race as a remaining risk (S1).

### 7.2 Store lock windows (v0.13-store-gc.md §6.5/§6.6)

Each typed operation runs in three phases:
1. **Under the lock, if held.** Evaluate the outer values (user code, may read store), then encode: the filter, the change, the documents or rows, the ClickHouse parameters. Everything that reads user values, including values that live in store, happens here. The bytes go into fresh arena buffers.
2. **Window.** `__store_release_keep()` → pool take, exchange, getMores, decoding of the reply into **fresh arena memory above the published `hi`** → `__store_lock()` if it was held. The window reads only the request bytes, the plans (built at start in permanent memory, immutable) and the reply; it dereferences no store object (W2) and writes no arena word below `hi` (W1). The windows are the low-level layer's two (`mongo_command` and `__ch_run` after their restructuring, review §4.2); the typed layer adds none, so the §6.6 lint count does not grow.
3. **Back under the lock.** The value is returned to user code; assigning it into store copies it with the normal barrier.

Lock classes (src/rw.kh): typed operations and `ch` neither read nor write store, so a route that reads store and calls them stays a reader (С10). Decoding inside the window, instead of after re-locking as `__fetch` does, keeps a writer from holding the exclusive lock while it decodes megabytes.

Library writes into user-reachable objects (review §4.3, GC step 6): none. Typed operations only read their arguments and return fresh values; `insert` returns its argument unchanged. There is no cursor or builder object for library code to mutate.

### 7.3 Cursors

- `find`, `aggregate` and `distinct` drain the cursor inside the operation; no cursor id outlives the call except on failure, where the low-level request-end hook queues `killCursors` (С9).
- Phase 2, streaming: `for x in C.find(f, Find {...}) { ... }` (and `for x in C.aggregate(...)`) compiles to a loop over a hidden cursor local: `find` with the first batch; for each document decode into `x` and run the body; at the end of a batch `getMore` (a window). `break`, `return`, `fail` and panics leave the loop through the request-end hook, which sends `killCursors` for the hidden local (the hook already exists for the low-level cursors). Batches are read into a per-loop mmap buffer that is reused, so wire data does not accumulate; decoded documents still live in the request arena until the request ends (there is no per-iteration arena reset, because the body may keep references). Documented as "streams the network, not memory: for unbounded scans, page with `Find { sort: "id", limit }` and `x.id > last`".
- ClickHouse results are materialized (bounded by `CLICKHOUSE_MAX_RESPONSE_BYTES`); streaming ClickHouse needs `wait_end_of_query=0` and exception detection inside RowBinary, which is out of scope.

### 7.4 Cancellation and deadlines

- Each operation has a deadline: now + `MONGODB_TIMEOUT` or `CLICKHOUSE_TIMEOUT`. ClickHouse SELECTs carry `max_execution_time` = the remaining whole seconds (unless readonly=1) and `cancel_http_readonly_queries_on_client_close=1`; on the client deadline the connection is closed, so the server stops the query (Н12).
- Writes are never cancelled from the client side after the body was sent; a lost reply is `write outcome unknown` (500), never a retry.
- Every ClickHouse query gets a `query_id` (`khrip-<random 16>`), printed in the 5xx log line for correlation with `system.query_log`. A user-facing cancel API is not offered; `ch_cancel` remains in the low-level API.

### 7.5 GC and memory

- Declarations, sites, filter plans, literal plans and sort documents are compile-time data (DATA). Startup state (connection descriptors, index lists, DESCRIBE plans, readonly flags) is allocated once in permanent memory (`__perm_alloc` / the boot arena), never in STORE and never in a request arena; it holds no pointers into either. It is not a GC root and needs no barrier.
- Typed values returned to user code are ordinary arena values; storing them in `store` goes through the existing barriers (I1).
- The ctx words used by the low-level layer (MONGOHELD, CHHELD, TLS_PENDING, pools) are the only per-coroutine state; the typed layer adds one word for the streaming cursor list (phase 2), placed with the low-level ones in the coroutine-local range of the §3.3 layout.

---
## 8. Compiler work

### 8.1 Lexer (src/lex.kh)

- `ch` followed on the same line by an optional identifier and then `"` or `` ` `` starts a ClickHouse query: `lex_ch` = `lex_sql` (src/lex.kh:628) with a dialect flag stored in the `SqlLit`, token `T_CH` with the literal index and the connection name. `sql_string_next` (src/lex.kh:616) gets a variant that skips one identifier. `let ch = s[i]` and other uses of `ch` as a name are unaffected (no string follows).
- Inside a `ch` string, `{` IDENT `:` IDENT … `}` is a lexer error (§8.3, E-CH1) instead of being lexed as a Khrip expression.
- `collection`, `table`, `mongodb`, `clickhouse`, `index`, `unique`, `ttl` stay `T_IDENT`; they are recognised by position (§8.2).

### 8.2 Declarations (new src/docdb.kh, hooks in src/decl.kh `prescan_from`)

- Pass 2 of `prescan_from` (src/decl.kh:713): `collection` IDENT `:` → `prescan_collection`; `table` IDENT `:` → `prescan_table`; `mongodb`/`clickhouse` IDENT `=` → `prescan_conn`; `migration` IDENT INT → ClickHouse migration (beside `prescan_migration`, src/sql.kh:586). The "expected a declaration" message (src/decl.kh:748) lists the new words.
- New symbol kinds `SK_COLL`, `SK_TABLE`, `SK_CONN` indexing arrays `colls`, `tables`, `conns`. A collection or table name used as a value is E-D1; a local that shadows one is E-D2.
- After `prescan_struct_fields`: resolve `T`, check the block (paths, overrides allowed for the field type, `ttl` on `int`, index paths), compute per collection the **unique sets** (`[["id"]]` plus each `unique` declaration) and the **storage plan** (path → storage kind) used by every encoder and decoder of that collection.
- Emit a descriptor per collection/table/connection into DATA (like sql sites, `desc_reserve`/`desc_put`): connection index, database and object names, type descriptor of `T`, storage plan, index specs as constant BSON (built at compile time by a small BSON writer in the compiler), unique sets, block options, source location. Root table entries next to `sql_root()` so the runtime finds them at start.

### 8.3 Diagnostics (exact text)

Format as today: `file:line:col: error: <message>`, the source line, a caret, `hint: <hint>`. Field typos inside filters, type mismatches and none-narrowing errors are the existing Khrip messages (they come from the same type rules as `list.filter`; probe A.10 shows them), so they are not repeated here.

| Id | Trigger | Message | Hint |
|---|---|---|---|
| E-D1 | `let c = notes`, `f(notes)` | `notes is a MongoDB collection, not a value` | `call its methods: notes.find(...), notes.insert(...)` |
| E-D2 | `let notes = ...` in a function | `notes hides the collection notes` | `choose another name for the local` |
| E-D3 | `collection notes: Shape` (variant type) | `a collection holds a struct type; Shape is a variant type` | `wrap it: type Item { id: str, shape: Shape }` |
| E-D4 | `index titel` | `Note has no field titel` | `did you mean title?` |
| E-D5 | `ttl created` on a str field | `ttl needs an int field with unix seconds; Note.created is str` | — |
| E-D6 | `x: objectid` on an int field | `objectid stores a str; Note.x is int` | `make the field str` |
| E-D7 | struct with `id` and `_id` | `Note has both id and _id; both would be stored as _id` | `keep id` |
| E-D8 | user `type Find` with collections | `Find is the options type of collection methods; rename your type` | — |
| E-M1 | `notes.findOne(...)`, `insertOne`, `updateMany`, `deleteOne`, `countDocuments`, `findOneAndUpdate` | `collections have no method findOne` | `notes.one(n => ...) reads one document` (each habit maps to its method) |
| E-M2 | `notes.find({"tags": t})` | `a filter is a lambda, as in filter` | `notes.find(n => n.tags.contains(t))` |
| E-M3 | unsupported part of a filter | `MongoDB cannot run this part of the filter: n.title.len()` | `filters compare fields with values and use && \|\| ! == none contains starts_with ends_with matches any; read with find and filter the list in Khrip for the rest` |
| E-M4 | `n.price > n.cost` | `a filter compares a field with a value; this compares two fields` | `read the documents and filter them in Khrip: .filter(n => n.price > n.cost)` |
| E-M5 | `n.title.matches(q)` with a non-literal `q` | `matches in a MongoDB filter needs a literal pattern: the database runs it with a backtracking engine` | `use contains, starts_with or ends_with for user input` |
| E-M6 | one-document operation with a filter that is not unique | `this filter can match several notes, but one Note is expected` | `filter on id or on a unique field (add "unique email" to the collection block), read [Note] with find, or take the first: Find { sort: "-created" }` |
| E-M7 | `return notes.find(...)` into `Note` | `notes.find gives [Note]; Note is expected` | `notes.one(...) reads one document` |
| E-M8 | `sort: "-creatd"` | `sort: Note has no field creatd` | `did you mean created?` |
| E-M9 | `sort: s` with `s` from data | `sort must be made of string literals: the client cannot choose a field to sort by` | `let s = match q { "new" => "-created", _ => "title" }, then Find { sort: s }` |
| E-M10 | `Find { skip: n }` without `sort` | `skip without sort gives pages in no fixed order` | `add sort, for example Find { sort: "id", skip: n, limit: 20 }` |
| E-M11 | `let f = Find {...}` passed later | `write Find { ... } in the call` | — |
| E-M12 | read used as a statement | `the result of notes.find is not used` | `assign it, or delete the call` |
| E-M13 | `notes.insert(body)` with `body: NoteIn` | `notes.insert takes a Note or [Note]; NoteIn has no id, created` | `notes.insert(Note { id: object_id(), created: now(), ...body })` |
| E-M14 | change struct with a field not in `T` | `NotePatch.color is not a field of Note` | — |
| E-M15 | change literal without operators | `an update needs operators: {"$set": {...}}` | `to replace the whole document use notes.replace(note)` |
| E-M16 | `{"$sett": ...}` | `unknown update operator $sett` | `did you mean $set?` |
| E-M17 | `{"$set": {"statsu": ...}}` | `$set: Order has no field statsu` | `did you mean status?` |
| E-M18 | `{"$set": {"amount": "5"}}` | `$set: Order.amount is int, but this value is str` | — |
| E-M19 | optional value in a literal (not `$set` of an optional field) | `this value may be none, and a document literal does not say what none means here` | `unwrap it first: let v = x else { return 400 }` |
| E-M20 | `$set` of a required field with a `U?` value | `$set: Note.title is str, but this value may be none` | `unwrap it, or make the field str?` |
| E-M21 | `$unset` of a required field | `$unset: Note.title is not optional, so the document would no longer read as Note` | `make the field str? or give it a default` |
| E-M22 | `$inc` on a non-number | `$inc: Note.title is str` | — |
| E-M23 | upsert that may create an incomplete document | `this upsert can create a Counter without window` | `set it in the change: {"$setOnInsert": {"window": w}}, or give Counter.window a default` |
| E-M24 | upsert without `id` equality and `id` not `objectid` | `this upsert may create a document whose _id the server makes (an ObjectId), but Counter.id is a str stored as a string` | `filter on c.id == ..., or add "id: objectid" to the block` |
| E-M25 | `{"$where": ...}`, `$function`, `$accumulator` | `$where runs JavaScript in the database` | `write the condition as the filter lambda` |
| E-M26 | a key that is not a string literal | `document keys must be string literals: a key from data could be an operator` | `put data keys in a map[str, T] value` |
| E-M27 | `"$amout"` in a checked stage | `$group: Order has no field amout` | `did you mean amount?` |
| E-M28 | aggregate result field missing from the known shape | `CategoryStat.orders is not produced by the pipeline: the last $group gives _id, total` | `add it to $group, or give the field a default` |
| E-M29 | `aggregate` without an expected type | `aggregate needs the result type` | `let rows: [Stat] = orders.aggregate(...)` |
| E-M30 | `notes.update(chg)` / `notes.delete()` without a filter | `notes.delete needs a filter` (`notes.update needs a filter`) | `to change every document write the filter n => true: notes.delete(n => true)` |
| E-M31 | positional `$` without a matching `any` | `$set: the positional $ needs the filter to match an element of items` | `filter with n.items.any(i => ...)` |
| E-M32 | unread `DbResult` local | `r is never read, so the failures it holds are ignored` | `check r.ok, or drop ": DbResult" to let failures end the request` |
| E-M33 | `T` result in a route without `\| 404` | `notes.one answers 404 when no document matches, but route GET "/notes/{id}" does not list 404` | `add \| 404 to the route, or answer yourself: let n: Note = notes.one(...) else { return 401 }` |
| E-T1 | collection or table operation inside `tx` | `notes.update inside tx: the block may run again after a conflict` | `call it before or after the tx block` |
| E-CH1 | `{from:Int64}` in a `ch` string | `{from:Int64} is ClickHouse's placeholder syntax; in ch "..." write {from}` | `Khrip sends {expr} as a typed parameter` |
| E-CH2 | `ch "INSERT INTO events {rows}"` or `VALUES` | `insert rows with events.insert(rows)` | `declare the table: table events: Event` |
| E-CH3 | `CREATE`/`DROP`/`ALTER ... COLUMN` in `ch` | `schema changes go into migration ch N` | `migration ch 2 \`ALTER TABLE events ADD COLUMN ...\`` |
| E-CH4 | `FORMAT` in `ch` | `remove FORMAT: Khrip reads rows in its own format` | — |
| E-CH5 | `FROM analytics.events` | `name the table without a database: the connection's database is used, and khc test replaces it` | `declare another connection or table for other databases` |
| E-CH6 | struct parameter | `a struct cannot be a ClickHouse parameter` | `insert rows with events.insert(rows)` |
| E-CH7 | `table t: Row` with a struct field | `Row.meta is a struct; ClickHouse rows hold int, float, bool, str, enums, lists, maps and optionals` | `flatten it, or store JSON text in a str` |
| E-CH8 | `events.insert(xs)` with a field not in `Event` | `EventIn.color is not a field of Event` | — |
| (sql) | table name, ORDER BY, optional comparison, missing result type, global init | the existing `sql` messages with "ch" instead of "sql" | as today |

### 8.4 The filter translator

Input: the lambda parameter name, its type `T` (or an element type inside `any`), the token range of the body, the collection's storage plan. Output: code that pushes the outer values, and a node array in DATA.

1. **Structure.** A recursive descent over the body tokens: `or := and ('||' and)*`, `and := not ('&&' not)*`, `not := '!' not | '(' or ')' | atom`. Before parsing an atom, a token scan to the atom's end (depth-0 `&&`, `||`, `)` or the end of the lambda) decides whether it mentions the parameter.
2. **Outer atoms** (no parameter): `parse_expr(ty_bool)`, value pushed, node `CONST(slot)`.
3. **Path atoms**: parse the path (`x` `.` field … or `x.m["key"]`), then one of the forms of §1.4. The other operand is parsed with `parse_expr(field type)` and pushed; the comparison is type-checked by the same code as the in-memory comparison (`parse_expr`, `coerce`, src/expr.kh:358), so every error message is the familiar one. A form outside the table is E-M3/E-M4/E-M5.
4. **Short-circuit.** If the left operand of `||`/`&&` is entirely outer, the code that evaluates the right operand's outer values is guarded by a conditional jump (its slots are pre-pushed as 0 and marked absent), so `u == none || x.age > u.limit` never evaluates `u.limit` on none, exactly as in memory. Outer values under path-dependent branches are evaluated once, before the query, left to right (documented).
5. **Nodes.** `[kind, path (const str, stored name), slot, storage kind, flags]` with kinds `AND n`, `OR n`, `NOR`, `CONST`, `TRUE`, `FALSE`, `EQ`, `NE`, `LT`, `LE`, `GT`, `GE`, `IN`, `ISNONE`, `NOTNONE`, `REGEX_SUB`, `REGEX_PRE`, `REGEX_SUF`, `REGEX_FULL` (with a case-insensitive flag and, for `lower()`, the "value must be lower case" check), `SIZE`, `NONEMPTY`, `ELEM` (sub-array). Flags record whether the field is optional (for the none rules of §1.4).
6. **Uniqueness.** The top-level conjunction (after removing `CONST`) is unique if, for some unique set, every path has an `EQ` node whose value is not optional (or whose field is required). Used by E-M6.
7. **Runtime** (`__mf_build`, lib/docdb.kh): fold constants (`TRUE`/`FALSE` propagation), then write BSON with the low-level builder; values are encoded with the storage of the path (§3.2); a value that cannot be stored in that storage (non-hex for `objectid`) folds the node to `FALSE`.

### 8.5 Document literals

`parse_doc(ctx)` where `ctx` is `UPDATE`, `STAGE(shape)` or `VALUE`: `{` STRING `:` value … `}` and `[` value … `]`; any other token starts a Khrip expression (`parse_expr(expected)` where the expected type is known from `T`, so `{"$set": {"tags": []}}` types `[]` as `[str]`). The plan is a tree in DATA: (key const, kind DOC/ARR/VAL, slot, type descriptor, storage kind, flags `LITERAL_WRAP`, `NONE_UNSETS`). Validation per §1.5 runs during parsing (operator tables, field paths of the current shape, value types). Shape tracking for pipelines is a list of known top-level keys with their Khrip types (or "unknown").

### 8.6 Operations, shapes and sites

- `parse_coll_method(coll, name, w)` (src/docdb.kh), called from the postfix parser when an `SK_COLL` identifier is followed by `.name(`: parses the arguments (a lambda → filter; `Find {` → options; `{` → document literal; a list literal of `{` → stages; otherwise an expression), decides the shape from `w` and from a following `else`/`??` with the same code as `parse_sql` (src/sql.kh:1617-1645), checks uniqueness, projections (`P ⊆ T`), upsert completeness (§1.5), and the 404 note (`sql_note_404`, src/sql.kh:271).
- A site in DATA (24 words, like `SITE_*`): kind, collection descriptor, shape, result type descriptor, projection document, filter nodes, change plan or stage plans, sort variants, value count, location, flags. The call is `mov rdi, site; mov rsi, rsp; call __docdb_run; add rsp, 8*n` (the `sql` pattern, src/sql.kh:1905-1913).
- `parse_table_insert(table, w)`, ClickHouse: the argument type `[S]`/`S` must have fields ⊆ `T` (E-CH8); the site records `S`'s descriptor; startup checks `S` against DESCRIBE.
- `parse_ch(w)`: `parse_sql` (src/sql.kh:1554) with a dialect parameter: parameter type names from §2.2 instead of PostgreSQL OIDs; no `= ANY`, `SET {patch}` or `INSERT INTO t {v}` rewrites; `IN ({xs})`/`IN {xs}` → `IN {pN:Array(T)}`; `{x} IS NULL` uses the Nullable parameter itself; LIKE concatenation with `concat()`; `sq_check` (PostgreSQL schema from migrations) is skipped; statement-kind rules of §1.7. Sites go to a separate root list with the connection index.
- Effects (`fn_effect`, src/sql.kh:416), `tx` checks (src/atom.kh:1639, :1781) and lock classes (src/rw.kh): an `SK_COLL`/`SK_TABLE` identifier followed by `.` and a `T_CH` token count as database I/O that does not touch store.
- `for x in C.find(...)` (phase 2): src/stmt.kh's `for` recognises a collection call as the iterable and emits the streaming loop of §7.3.

### 8.7 What stays library code

| Library (lib/) | Compiler (src/) |
|---|---|
| Wire protocols, BSON and RowBinary codecs, pools, TLS, admission (low-level team) | Syntax: declarations, `ch` strings, blocks, document literals |
| `lib/docdb.kh`: start (connect, `createIndexes`/`listIndexes`, validator compare, sample), `__docdb_run` per site kind, filter and literal builders, typed encode/decode with the storage plan and `id`↔`_id`, status classification, `DbResult`, test databases | Name resolution and the new symbol kinds |
| `lib/chdb.kh`: start (migrations, DESCRIBE of tables and sites, plans, readonly detection), `__chdb_run`, `__chdb_insert`, classification, `DbResult`, test databases | Filter translation, uniqueness, shape checks, pipeline shape tracking |
| `lib/db.kh` shared: `__DbFail`, `__db_answer`, `DbResult`, `DbError`, `Find` | Shapes from expected types, 404 notes, effects, lock classes, unused-result checks |
| base64, uuid text, ISO time for `date` on str | Descriptors and plans emitted as DATA |

### 8.8 Cost

Sizes are estimates by analogy with v0.12 (src/sql.kh 2,335 lines, src/sqlcheck.kh 1,613, lib/db.kh 1,633 for the whole PostgreSQL language layer).

| Part | Lines | Notes |
|---|---|---|
| Lexer and declarations (src/lex.kh, src/decl.kh, src/docdb.kh) | 600 | contextual parsing, blocks, descriptors, compile-time BSON for indexes and sorts |
| Filter translator | 700 | §8.4, the largest new piece |
| Document literals and pipeline shapes | 500 | §8.5 |
| Collection operations, shapes, projections, upsert completeness | 600 | §8.6 |
| `ch` dialect on `parse_sql` | 300 | mostly shared code paths |
| Effects, locks, unused results, diagnostics | 350 | |
| **Compiler total** | **≈ 3,050** | |
| lib/docdb.kh | 1,400 | including startup checks and test databases |
| lib/chdb.kh | 900 | DESCRIBE plans themselves are the low-level team's |
| shared (db.kh), base64/uuid/time helpers | 250 | |
| **Runtime total** | **≈ 2,550** | on top of the low-level drivers |
| Tests: ~60 negative fixtures (one per diagnostic), translator golden tests (lambda → BSON), real-server suites for both databases, GC stress run over them | 2,000 | |

This is the size of the v0.12 language work (lang A–E), done in the same order: phase 1 (§11) first, measured with eval tasks, then phase 2.

### 8.9 Risks

| Risk | Mitigation |
|---|---|
| The filter subset drifts from in-memory semantics in a corner (non-conforming data, case folding) | A golden test compares `list.filter` and `find` on generated documents and filters (both run in `khc test`); documented differences (§1.4) are the only allowed ones. |
| The single-pass compiler has no AST, so the translator needs lookahead | The same technique as `sql` parameters (token ranges, `sql_pure_key`); atoms are short. |
| AIs write MongoDB-shell filters out of habit | E-M1/E-M2 with exact rewrites; eval tasks measure first-try error rates (§10.5). |
| Uniqueness errors (E-M6) annoy | The fix is one line in the block and also gives the database the index the lookup needs. |
| Startup DESCRIBE false failures with sample values | Value errors become warnings plus a first-run header check (§6.2). |
| Index builds slow the first start on big collections | `./app migrate` as a deploy step; `DATABASE_MIGRATE=check`. |
| Prompt growth (+534 o200k on KHRIP.md) | Less than the PostgreSQL section (853); programs are 1.7–3× shorter than with the PR API, which pays it back in one or two routes per task. |
| Dependence on the low-level fixes | §11 lists the exact entry points; the typed layer can start on the current low-level API with `mongo_command` for findAndModify/count/distinct. |
| ClickHouse migrations are not transactional | Messages name the failed statement; documentation recommends one statement per migration. |

---
## 9. KHRIP.md

### 9.1 The section

It replaces the PR's paragraph "MongoDB and ClickHouse" (KHRIP.md:283-291, 124 o200k / 138 Claude) in place, between PostgreSQL and Tests:

````markdown
## MongoDB and ClickHouse

```khrip
type Note { id: str, title: str, tags: [str] = [], views: int = 0, created: int }
collection notes: Note {         // MONGODB_URI=mongodb://host/app
    unique title                 // indexes are made at start
    index tags, -created         // - is descending
}
return notes.one(n => n.id == id)                     // in a route: none → 404
let page: [Note] = notes.find(n => tag == none || n.tags.contains(tag),
    Find { sort: "-created", skip: 20, limit: 20 })
let note = notes.insert(Note { id: object_id(), created: now(), ...body })
let changed = notes.update(n => n.id == id, patch)    // matched count
notes.update(n => n.id == id, {"$inc": {"views": 1}, "$push": {"tags": t}})
let gone = notes.delete(n => n.created < cutoff)      // also count(filter)
let stats: [TagStat] = notes.aggregate(n => n.views > 0,
    [{"$unwind": "$tags"}, {"$group": {"_id": "$tags", "n": {"$sum": 1}}}])

migration ch 1 `CREATE TABLE events (ts DateTime, page String) ENGINE = MergeTree ORDER BY ts`
table events: Event              // CLICKHOUSE_URL=http://user:pass@host:8123/db
events.insert(rows)
let top: [Top] = ch "SELECT page, count() AS n FROM events WHERE ts >= {t} GROUP BY page"
```

- Filters are lambdas as in `filter`, run by the database: fields compared with
  values, `&& || !`, `== none`, `contains`, `starts_with`, `any`. `find` gives
  `[T]`; `one` gives `T?` (`T` in a route) and filters on `id` or a `unique`
  field, or takes the first match by `Find { sort }`.
- `id` is stored as `_id`; a `T?` field with none is not stored. `update` with a
  struct sets its fields (`T?` ones only if sent); `{...}` holds operators,
  checked against the type; a struct result type gives the document after the
  update; `upsert` inserts when nothing matches. In the block, `born: date`
  stores an int (unix seconds) as a Date, and `ttl born` deletes documents then.
- `ch "..."` is `sql` for ClickHouse. Tables and queries are checked at start.
- Failures end the request as with `sql`; `notes.insert(note) else { }` catches a
  duplicate. No calls inside `tx`; MongoDB has no `tx`: put the condition into
  the update filter and check the count.
- `khc test` uses `KHRIP_TEST_MONGODB_URI` and `KHRIP_TEST_CLICKHOUSE_URL`, in a
  temporary database.
````

In the PostgreSQL `tx` bullet, "MongoDB or ClickHouse network operations" becomes "collection, table or `ch` calls".

Optional, in "Habits from other languages" (+55 o200k / +64 Claude; the compiler hints E-M1, E-M2, E-CH1 already say the same):

```markdown
`{"tags": t}`, `bson.M{...}` filters → `notes.find(n => n.tags.contains(t))`;
`_id`, `ObjectId()` → `id`, `object_id()`; ClickHouse `{x:Int64}` → `{x}`.
```

### 9.2 Token counts (spec_tokens.mjs, whole text)

| Text | o200k | Claude |
|---|---:|---:|
| The new section | 658 | 695 |
| The PR paragraph it replaces | 124 | 138 |
| The PostgreSQL section, for scale | 853 | 841 |
| The draft for the PR API (review §5.3, signatures and traps only) | 634 | 706 |
| KHRIP.md before PR #1 (1bc4605) | 3,945 | 4,118 |
| KHRIP.md now (with the PR paragraph) | 4,078 | 4,265 |
| KHRIP.md with this section | 4,612 | 4,823 |
| ... plus the optional habits line | 4,667 | 4,887 |

The section costs about as much as the PR-API draft, which only listed signatures and warned about traps; here the same tokens are enough to write the programs of §10, and the traps it warned about no longer compile.

### 9.3 Why each line is there

- The code block shows every form once, in the order an AI needs them: type, declaration with indexes, one, find with `Find`, insert with `object_id()`, both update forms, delete/count, aggregate, then the ClickHouse migration, table, insert and query. The comments carry the environment variables and the two non-obvious results (404, counts).
- Bullet 1 is the filter contract (it reuses the reader's knowledge of `filter`) and the uniqueness rule, which is the one compile error an AI will meet most.
- Bullet 2 is the storage contract: `id`, none, the PATCH rule, operators, the struct-result rule, `upsert`, `date`/`ttl`.
- Bullet 3 delegates all ClickHouse query rules to the `sql` section.
- Bullet 4 is the error contract and the replacement for transactions.
- Bullet 5 is the test setup.
- Left to DATABASES.md (English, rewritten): `distinct`, `replace`, `upsert(v)`, projections, `DbResult`, `objectid`/`int32`/`binary`/`uuid`, more connections, `async_insert`, streaming, the low-level API, the type tables of §3.

---
## 10. Evidence

The three programs of the review (pr1-evidence/1/p1, p2, p3) rewritten in this design. They keep the PR versions' type declarations (only `_id` → `id`) so that the differences come from the API. They are design sketches: the compiler for them does not exist yet. The MongoDB and ClickHouse behaviour each line relies on was probed on the real servers (Appendix A). Files: /tmp/claude-0/-home-user-khrip/c69287a0-5c25-565c-bc10-daebb195400d/scratchpad/drvdesign/schema-first/progs/.

### 10.1 Programs

**P1, notes CRUD on MongoDB** (p1_notes.kh; with `index tags, -created` in a block: p1_notes_indexed.kh)

```khrip
type NoteIn { title: str, body: str, tags: [str] = [] }
type Note { id: str, title: str, body: str, tags: [str], created: int }

collection notes: Note

route POST "/notes" (body: NoteIn) -> 201 Note {
    return 201 notes.insert(Note { id: object_id(), created: now(), ...body })
}

route GET "/notes/{id}" (id: str) -> Note | 404 {
    return notes.one(n => n.id == id)
}

route GET "/notes" (tag: str?, limit: int = 20) -> [Note] {
    return notes.find(n => tag == none || n.tags.contains(tag), Find { sort: "-created", limit })
}

route PUT "/notes/{id}" (id: str, body: NoteIn) -> Note | 404 {
    return notes.update(n => n.id == id, body)
}

route DELETE "/notes/{id}" (id: str) -> 204 | 404 {
    if notes.delete(n => n.id == id) == 0 {
        return 404
    }
    return 204
}
```

What the compiler and runtime do with it: `notes` binds to `MONGODB_URI`'s database; `one` is unique by `id`, so it compiles, and the route lists 404; the list filter folds `tag == none` at run time (`{}` or `{tags: tag}`), the sort is a constant `{created: -1}`; `update` into `Note` becomes `findAndModify {_id: id}, {$set: {title, body, tags}}, new: true`; a duplicate id would be 409, MongoDB down 503.

**P2, orders: insert, conditional update, aggregation** (p2_orders.kh)

```khrip
type NewOrder { customer: str, category: str, amount: int }
type Order { id: str, customer: str, category: str, amount: int, status: str, created: int }
type CategoryStat { id: str, total: int, orders: int }

collection orders: Order

route POST "/orders" (body: NewOrder) -> 201 Order | 400 str {
    if body.amount <= 0 {
        return 400 "amount must be positive"
    }
    return 201 orders.insert(Order { id: object_id(), status: "new", created: now(), ...body })
}

route POST "/orders/{id}/pay" (id: str) -> 204 | 404 {
    if orders.update(o => o.id == id && o.status == "new", {"$set": {"status": "paid"}}) == 0 {
        return 404
    }
    return 204
}

route GET "/stats/categories" (since: int = 0) -> [CategoryStat] {
    return orders.aggregate(o => o.status == "paid" && o.created >= since, [
        {"$group": {"_id": "$category", "total": {"$sum": "$amount"}, "orders": {"$sum": 1}}},
        {"$sort": {"total": -1}}
    ])
}
```

The pay route is the transaction replacement: one atomic `update` with the state in the filter; a second call finds `status == "new"` false and answers 404. In the pipeline, `"$category"` and `"$amount"` are checked against `Order`; the `$group` output keys (`_id`, `total`, `orders`) are checked against `CategoryStat` (`_id` ↔ `id`) and the `$sort` key against the `$group` output; `{"$sum": 1}` comes back as Int32 and widens into `int`.

**P3, ClickHouse batch insert and parameterized report** (p3_events.kh; with the DDL as `migration ch 1`: p3_events_migration.kh; with `ts DateTime DEFAULT now()` and `events.insert(body)`: p3_events_default.kh)

```khrip
// CREATE TABLE events (ts DateTime, user_id UInt64, page LowCardinality(String), ms Float32)
//     ENGINE = MergeTree ORDER BY (page, ts)
type EventIn { user_id: int, page: str, ms: float }
type Event { ts: int, user_id: int, page: str, ms: float }
type PageStat { page: str, views: int, users: int, avg_ms: float }
type Inserted { inserted: int }

table events: Event

route POST "/events" (body: [EventIn]) -> 202 Inserted | 400 str {
    if body.len() == 0 || body.len() > 10000 {
        return 400 "send 1..10000 events"
    }
    let t = now()
    events.insert(body.map(e => Event { ts: t, ...e }))
    return 202 Inserted { inserted: body.len() }
}

route GET "/stats/pages" (from: int, to: int, limit: int = 10) -> [PageStat] {
    return ch `SELECT page, count() AS views, uniq(user_id) AS users, avg(ms) AS avg_ms
        FROM events WHERE ts >= {from} AND ts < {to}
        GROUP BY page ORDER BY views DESC LIMIT {limit}`
}
```

At start: `DESCRIBE TABLE events` checks `Event` against `(ts DateTime, user_id UInt64, page LowCardinality(String), ms Float32)` and builds the insert plan (int → DateTime and UInt64 with range checks, str → LowCardinality(String), float → Float32); `DESCRIBE TABLE (SELECT ... {p1:Int64} ... {p3:Int64})` with sample values returns `page LowCardinality(String), views UInt64, users UInt64, avg_ms Float64` (probe A.8), which matches `PageStat`. The PR version could not insert into this table at all (В6: `Type of 'user_id' must be UInt64, not Int64`).

### 10.2 Tokens

`node bench/tokens/count.mjs` (code only, comments and blank lines removed), o200k (Claude):

| Program | PR API | Go (official drivers) | Khrip + PostgreSQL | Review's sketch | **Schema-first** | Go / schema-first | PR / schema-first |
|---|---:|---:|---:|---:|---:|---:|---:|
| P1 | 742 (775) | 1184 (1443) | 318 (324) | 356 (352) | **247 (263)** | 4.79 (5.49) | 3.00 (2.95) |
| P1 with the index block | | | | | 255 (272) | 4.64 (5.31) | |
| P2 | 703 (772) | 990 (1188) | — | — | **281 (284)** | 3.52 (4.18) | 2.50 (2.72) |
| P3 | 424 (456) | 889 (1067) | — | 248 (257) | **243 (254)** | 3.66 (4.20) | 1.74 (1.80) |
| P3 with `migration ch 1` (DDL counted) | | | | | 283 (299) | 3.14 (3.57) | |
| P3 with `DEFAULT now()` and `events.insert(body)` | | | | | 268 (282) | | |

For scale: Go/Khrip on the PostgreSQL eval tasks is 2.31. The PR API gave 1.41–2.10 here.

- P1 is shorter than its PostgreSQL version (318) mainly because MongoDB needs no DDL: without its `migration 1` the PostgreSQL version is 278 (282), 12% longer than this one (alt/notes_pg_noddl.kh); the rest is its `NewNote` type and the SQL text.
- The ClickHouse version is as short as the review's `ch "..."` sketch (248); the declaration `table events: Event` costs 5 tokens and buys the startup check of every column.
- A design alternative with MongoDB-shell document filters (`notes.one({"_id": id})`, an `if` to build the optional tag filter) measured 257 (264) for P1, slightly longer than lambdas, and it reintroduces the none trap (an omitted none in a filter matches every document: `users.one({"email": header("X-Email")})` would return any user when the header is missing). File: alt/p1_literal_filters.kh.

### 10.3 What the AI no longer writes, and the PR traps that cannot be expressed

| In the PR programs | Here |
|---|---|
| `fn db() -> Mongo {...}`, `const DB`, collection names repeated per call | one declaration |
| 6 manual `if r.error != "" { return 503 r.error }` (P1), 2 in P3 | none: fail-closed |
| cursor loop with `mongo_next`, silently skipping undecodable documents | none: `find` drains; a bad document is a loud 500 |
| `bson_get_int(r.document, "n") ?? 0` for counts | the call's value |
| re-`find` after `update` | `update` into `Note` |
| 25 builder calls for one pipeline (P2) | one literal, checked against `Order` |
| `ch_query_params` + `map[str, str]` of `.to_str()` + `ch_decode` + 2 checks | `ch` with `{x}` |
| `ChConfig`, `Mongo` values | none |
| В1 `Bson` inside `to_bson` | no `Bson` values |
| В2 PATCH erases fields | struct changes use `SET {patch}` semantics |
| В3 `'{page}'` interpolation in ClickHouse | `{x}` is a parameter; `{x:Int64}` is E-CH1 |
| В4 ignored write result | fail-closed; unread `DbResult` is E-M32 |
| В5 first batch lost | no cursor protocol |
| В6 no UInt64/DateTime/LowCardinality inserts | DESCRIBE plan, checked at start |
| Н2 `mongo_find(..., 20)` means batch size | `Find { limit }` |
| `_id: BsonObjectId?` none → `_id: null` | `id: str` + `object_id()` |

### 10.4 Remaining places where an AI can still make a silent mistake

Silent means: it compiles, starts, passes a quick test and gives wrong results or loses data.

| # | Mistake | Example | Why the design does not stop it | Mitigation |
|---|---|---|---|---|
| S1 | Check-then-act race without a transaction | `let o: Order = orders.one(...)`, `if o.status == "new" { orders.update(x => x.id == id, {"$set": {"status": "paid"}}) }` | MongoDB has no `tx` here; a compile rule like `sql`'s "write after a read outside tx" would also reject correct code | KHRIP.md teaches the conditional update; candidate lint: a one-document read followed by an update of the same collection whose filter is only `id` |
| S2 | Ignoring the matched count | PUT/DELETE answers 204 for a missing id | Legal on purpose (idempotent handlers), as with `sql` | eval checks; the example in KHRIP.md uses the count |
| S3 | Units | `ts >= {from}` with milliseconds against a `DateTime` column; `now_ms()` into an `int` field without `date` | Both are `int` | `date` fields reject values after year 5138 (catches ms in seconds fields); DateTime range check catches ms on insert; queries are not checked |
| S4 | A field reference in a later pipeline stage | `"$totl"` after `$lookup`/`$facet`, where the shape is unknown | Shape tracking stops at stages it cannot model | Most pipelines are `$match/$group/$sort` and fully checked; probe A.4 shows the server gives 0 for a missing field |
| S5 | Foreign ObjectIds without `objectid` in the block | `orders.find(o => o.user_id == uid)` when another program stores `user_id` as an ObjectId: empty result | Strings and ObjectIds never compare equal (probe A.7) | the startup sample check warns, naming the field, when the newest document has it; `_id` mismatches are loud read errors |
| S6 | Pagination by `limit` without `sort` | `Find { limit: 20 }` | Only `skip` without `sort` is rejected; "any 20" is a legal query | documentation |
| S7 | `limit` from the client is 0 | `Find { sort: "id", limit }` with `?limit=0` returns everything | 0 means "no limit" in MongoDB | validate inputs in the route (documented) |
| S8 | Substring search expectations | `n.title.contains(q)` is case-sensitive and not indexed | Same meaning as in memory | documentation; `lower()` form for case-insensitive |
| S9 | PUT with defaulted fields clears data | `tags: [str] = []` absent in the body → `$set: {tags: []}` | Same as `SET {body}` in PostgreSQL | patch types with `T?` fields |
| S10 | ClickHouse semantics | `ReplacingMergeTree` read without `FINAL` double counts; `LIMIT` without `ORDER BY` | Domain rules of ClickHouse, not types | documentation |
| S11 | Retrying after `write outcome unknown` | a client retry of a ClickHouse insert duplicates rows | The server may have applied the insert | 500 (not 503) discourages blind retries; `DbResult.unknown_outcome` for code that dedupes |
| S12 | Data loss in an `every` flush | `let rows = buffer.copy(); buffer.clear(); events.insert(rows)` panics when ClickHouse is down and the rows are gone | Fail-closed in a task is a panic | `let r: DbResult = events.insert(rows)` and put rows back when `!r.ok` (documented example) |
| S13 | ClickHouse `String` holding binary returned as JSON | invalid UTF-8 becomes U+FFFD (D9) | `String` is bytes by design | `base64Encode` in the query |
| S14 | A query that could not be checked at start | DESCRIBE failed on sample values (e.g. `toDate({s})` with `""`) | Sample values are not real values | warning at start; the first run checks the header before decoding, so a mismatch is a loud 500, not wrong data |

Not in the list because they are loud now: field typos (compile), wrong value types (compile), none in filters (Khrip semantics), missing indexes for `one` (compile), operators without `$set` (compile), missing 404 in a route (compile), nullable columns into required fields (start), Date compared with Int64 (start), inserts into narrower or nullable columns (start or 400), undecodable stored documents (500 with path), duplicate keys (409), lost replies (500).

### 10.5 Validation still to do

The token numbers above are for programs written by the designer from the design. Before promoting the section, run the eval protocol (eval/PROMPT.md with KHRIP.md as `{RULES}`) on MongoDB and ClickHouse versions of the eval tasks, as was done for PostgreSQL in v0.12: first-try compile errors, silent failures caught by check.sh, tokens, and Go/C#/Python baselines.

---
## 11. Phases and what the low-level layer must provide

### 11.1 Phases

| Phase | Content | Exit criterion |
|---|---|---|
| 1 | Declarations with default connections; block items `index`, `unique` (with automatic partial filters), `ttl`, `date`, `objectid`; `find`, `one`, `count`, `insert`, `update`, `upsert(f, c)`, `replace`, `upsert(v)`, `delete`, `aggregate`; filters, document literals, `Find`, shapes, projections; fail-closed, `T?` insert, `DbResult` for writes; startup: indexes, sample warning; ClickHouse `table`, `insert`, `ch`, `migration ch`, DESCRIBE of tables and sites; `khc test` databases; all diagnostics of §8.3; KHRIP.md section; DATABASES.md rewritten in English | P1–P3 compile and pass against real servers; eval tasks on MongoDB and ClickHouse in four languages (§10.5); GC stress mode over the database suites |
| 2 | `for x in C.find(...)` streaming; `distinct`; `int32`, `binary`, `uuid`, `decimal`; validator comparison; more connections and `at`; `async_insert` | |
| 3 | `validate` (generated `$jsonSchema`); once-only MongoDB code migrations; compile-time parsing of ClickHouse migrations so `khc check` checks tables without a server (as `sqlcheck` does for PostgreSQL); Tuple/Nested/JSON columns; MongoDB transactions if sessions land | |

### 11.2 Needed from the low-level layer

Most of it is already on the other team's list; the additions are marked.

| Need | Status |
|---|---|
| BSON encode/decode from a type descriptor, one pass, no allocation per field; none omitted; numeric widening; UTF-8 checked at `str` with the field path | in progress |
| **Addition:** a storage-plan parameter for encode/decode (`id` ↔ `_id`; per-path `date`/`objectid`/`int32`/`binary`/`uuid`) and decode errors that carry the path | new, small: one extra table lookup per field |
| A command call with a deadline returning the reply, `code`, `codeName`, `writeErrors` (index, code, `keyPattern`), `writeConcernError`, `unknown_outcome` | mostly there (`MongoResult`); `keyPattern` and the deadline parameter to add |
| Cursor draining with a per-batch callback (decode in the window); `killCursors` queued at request end | in progress (killCursors) |
| `createIndexes` with `partialFilterExpression`, `expireAfterSeconds`, names; `listIndexes`; `listCollections` | `mongo_create_indexes` exists; **partial filter, listIndexes, listCollections to add** |
| `object_id()` | done (lib/bson.kh:1016) |
| ClickHouse: `DESCRIBE TABLE t` and `DESCRIBE TABLE (q)` with parameters; per-column encode plans with range checks and field-path errors; header check against an expected type before decoding | in progress (DESCRIBE cache, column plans); the query form and the header check are additions |
| ClickHouse: exception code exposed; `X-ClickHouse-Summary` parsed (`written_rows`); settings sent only when needed and none under `readonly=1`; `max_execution_time` and `query_id` per call; FIFO admission | partly in progress; summary parsing and per-call settings to add |
| Drivers linked only when used, triggered by `collection`, `table`, `ch` and `migration ch` too | in progress (trigger list to extend) |
| The two store-lock windows restructured as in review §4.2 (prepare before release, exchange only inside) | in progress |

### 11.3 Changes to other documents

- **v0.13-utf8.md §2 (D9):** add rows: typed MongoDB reads (strict UTF-8, 500 with collection, `_id`, path), typed MongoDB writes (strict, 400), `binary`/`uuid` fields (ASCII text), `ch` results, parameters and inserts (raw bytes).
- **v0.13-store-gc.md §6.5/§6.6:** no new release sites beyond the low-level layer's two; add one sentence that typed database operations encode before `__store_release_keep` and decode only into memory allocated after it.
- **DESIGN.md:** the rule "library functions do not write into user-reachable objects" (review §4.3), with the typed database layer as an example that satisfies it by construction.
- **DATABASES.md:** rewritten in English around the typed layer; the low-level API moves to a last section.
- **ROADMAP.md:** phases of §11.1.

---

## 12. Alternatives considered

| Alternative | Why not |
|---|---|
| Library functions with a client argument (`mongo_one(db, "notes", ...)`), as in the review's sketch | Names of databases and collections as strings in every call; no compile-time knowledge of the schema, so field typos, wrong value types and missing indexes stay silent or runtime errors. The declaration costs 4–6 tokens once. |
| MongoDB-shell document filters (`{"tags": tag}`) | Slightly longer (§10.2); needs a rule for none in filters, and both choices are traps (omit → matches everything; null → matches documents without the field). The lambda inherits Khrip's semantics and type errors. Habit is covered by E-M2. |
| A chained query builder (`notes.where(...).sort_by(...).take(20)`) | Lazy evaluation is a new concept in Khrip, and `sort_by` on a list already means something eager; a chain that looks like list code but runs in the database invites mixing the two. One call with `Find` keeps it explicit. |
| A distinct `ObjectId` type (or `str` flavours) | A new type kind with conversions and prompt tokens for a value that is a string in JSON, routes and logs. The storage override gives the same wire behaviour; strict decoding makes a missing override loud. |
| Storing every 24-hex string as an ObjectId | Changes the stored type of unrelated strings; breaks `$regex` and other programs' expectations. |
| Generating ClickHouse `CREATE TABLE` from the Khrip type | Khrip types cannot express engines, ORDER BY, LowCardinality, codecs, TTL or partitions; two sources of truth with migrations. DDL stays in migrations; the declaration binds and checks. |
| `ch "INSERT INTO events {rows}"` instead of `events.insert(rows)` | Equivalent in tokens; the declaration gives one place for the row type, the plan, options (`async_insert`) and the connection, and keeps the `ch` statement set small. |
| Auto-creating or dropping indexes that differ from the declaration | Dropping loses other programs' indexes; rebuilding a unique index can fail on existing duplicates or take hours. Conflicts stop the start with a message. |
| MongoDB transactions in v1 | The driver has no sessions, standalone servers cannot run them, and conditional updates cover the common cases. |
| Warning instead of error for non-unique `one` | A filter that can match several documents and silently returns an arbitrary one is the trap this design exists to remove; the fix is one line. |

---

## Appendix A. Probes on the real servers

MongoDB 8.0.34 at 127.0.0.1:27019 (standalone), database `sf_t`; ClickHouse 25.8.33.6 at 127.0.0.1:8125, database `sfirst_t`. Both were dropped afterwards. Commands were run with `mongosh` inside the container and `curl` against the HTTP port.

**A.1 Unique index on an optional field.** `createIndexes` with `unique: true` on `phone`, then two documents without `phone`: `writeErrors: [{index: 1, code: 11000, errmsg: 'E11000 duplicate key error collection: sf_t.v index: phone_1 dup key: { phone: null }'}]`. With `partialFilterExpression: {phone: {$exists: true}}`: two documents without `phone` and one with `phone: "1"` insert; a second `phone: "1"` gets 11000. (The design uses `$type` instead of `$exists`, so an explicit null written by another program is also outside the index.)

**A.2 null, absent and `$ne`.** Documents `{_id:1, note:"x"}`, `{_id:2}`, `{_id:3, note:null}`: `{note: null}` → 2, 3; `{note: {$ne: null}}` → 1; `{note: {$ne: "x"}}` → 2, 3. These are Khrip's `n.note == none`, `!= none`, `!= "x"` for `note: str?`.

**A.3 Translator building blocks.** `{tags: "a"}` matches arrays containing "a"; `{tags: {$size: 0}}` → the empty array; `{"tags.0": {$exists: true}}` → non-empty arrays; `{_id: {$in: []}}` → nothing; `{note: {$regex: "^x\\z"}}` and `{note: {$regex: "^X\\z", $options: "i"}}` → `_id` 1. `{$set: {}}` in `update` and `findAndModify` is accepted (`n: 1, nModified: 0`). `findAndModify` with `sort: {_id: -1}` and `new: true` returns the changed document. `update` with `upsert: true` returns `upserted: [{index: 0, _id: ObjectId(...)}]` when nothing matched and the filter fixes no `_id` (server-made ObjectId, E-M24). `update` with `multi: true, upsert: true`, filter `{_id: "k"}` and `{$inc: {n: 1}}`, twice: first `upserted: [{_id: 'k'}]`, then `nModified: 1`; the document is `{_id: 'k', n: 2}` (the counter idiom).

**A.4 Misspelt field in a pipeline.** `$group: {_id: "$name", total: {$sum: "$amout"}}` → `total: 0` for every group, no error.

**A.5 Field-path injection.** `$addFields: {label: "$secret"}` (the string as a value from data) → `label: 's1'`, `'s2'` (the secret field). With `{$literal: "$secret"}` → `label: '$secret'`. In `$match` and `find` filters, `{name: "$secret"}` is a plain string.

**A.6 ClickHouse parameter types.** Work: `now() >= {f:Int64}`, `toDateTime64(now(),3) >= {f:Int64}`, `toUInt32(5) = {f:Int64}`, `toInt32(5) < {f:Int64}`, `toUInt64(5) < {f:Int64}`, `toFloat32(1.5) < {f:Float64}`, `toDecimal64(1.5, 2) < {f:Float64}`, `toLowCardinality('a') = {u:String}`, `LIMIT {n:Int64}`, `INTERVAL {n:Int64} DAY`, `toDate({t:Int64})`, `number IN {a:Array(Int64)}` and `IN ({a:Array(Int64)})` (2 rows), `({t:Nullable(String)} IS NULL OR ...)` with `\N` (10 rows) and with `3` (1 row). Fails: `toDate(now()) >= {f:Int64}` → `Code: 43 ... Illegal types of arguments (Date, Int64) of function greaterOrEquals`. LIKE: `'xZaQbx' LIKE concat('%', {s:String}, '%')` with `s = "%a_b"` → 1 (`_` matched `Q`), hence the escaping rule.

**A.7 String id against an ObjectId.** After inserting `{_id: ObjectId("65a1b2c3d4e5f60718293a4b")}`, `find {_id: "65a1b2c3d4e5f60718293a4b"}` → `[]`.

**A.8 ClickHouse DESCRIBE.** `DESCRIBE TABLE (SELECT ... {p:Int64} ...)` without values → `Code: 456 ... Substitution 'p' is not set`; with `param_p=0` → names and types. With the P3 query and sample values: `page LowCardinality(String)`, `views UInt64`, `users UInt64`, `avg_ms Float64`. Value errors from sample values: `toDate({s:String})` with `''` → `Code: 38 CANNOT_PARSE_DATE`; `intDiv(10, {n:Int64})` with 0 → `Code: 153` (hence int samples are 1). Type errors: `d >= {from:Int64}` on a Date column → `Code: 43`. `DESCRIBE TABLE sfirst_t.events FORMAT TSVWithNames` gives `name, type, default_type, default_expression, ...`, with `DEFAULT now()` and `MATERIALIZED toDate(ts)` visible. `EXPLAIN PLAN` accepts only SELECT; `EXPLAIN AST INSERT INTO nosuch SELECT 1` parses without checking the table. `getSetting('readonly')` → 0 for the test user.

**A.9 MongoDB server facts.** `hello` has no `setName`: standalone, so no transactions. `createIndexes` repeated → `note: 'all indexes already exist'`; the same name with other keys or other options (`unique` dropped) → `86 IndexKeySpecsConflict`; the same keys under another name → `85 IndexOptionsConflict` (`Index already exists with a different name: a_1`). A duplicate in `insert` and in `update` → `writeErrors` with `code: 11000`, `keyPattern` and `keyValue` (used for `already exists: users.email`).

**A.10 Existing Khrip messages reused by filters** (khc check on a list filter): `type 'Note' has no field 'titel'` with `hint: did you mean 'title'?`; `n.tags.contains(tag)` with `tag: str?` → `expected str, found str?` with the unwrap hint; `n.title == tag` with `tag: str?` compiles (none is never equal to a str), which is the meaning the translator gives it.
