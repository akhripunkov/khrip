# MongoDB

A library driver (MongoDB 6+, one server or the primary with
`directConnection=true`): calls return results, are never retried, stay outside
`tx` and wait like `fetch`.

```khrip
type Event { _id: str, user: int, title: str, ts: int }

fn db() -> Mongo {
    return Mongo { uri: env("MONGODB_URI") ?? "mongodb://127.0.0.1:27017/?directConnection=true" }
}

route POST "/events" (body: { user: int, title: str }) -> 201 Event | 409 str {
    let e = Event { _id: object_id(), ...body, ts: now() }
    let r = mongo_insert(db(), "app", "events", [to_bson(e)])
    if r.code == 11000 {                     // duplicate key
        return 409 "exists"
    }
    if r.error != "" {
        fail(500, r.error)
    }
    return 201 e
}

route GET "/events" (user: int) -> [Event] {
    let c = mongo_find_with(db(), "app", "events", to_bson({ user }),
        MongoFindOptions { sort: to_bson({ ts: -1 }), limit: 50 })
    var out: [Event] = []
    while c.error == "" {
        for d in c.documents {
            let e: Event? = from_bson(d)
            out.push(e ?? fail(500, bson_error()))
        }
        if !mongo_next(c) {
            break
        }
    }
    if c.error != "" {
        fail(500, c.error)
    }
    return out
}
```

- `Mongo { uri, timeout_ms: 10000 }`; unsupported URI options are errors.
- `to_bson(v)` takes a struct or `map[str, T]`; `from_bson(doc)` gives `T?` by the
  annotation (why none: `bson_error()`). A `none` field is not written, so
  `mongo_update(db(), "app", "events", to_bson({ _id: id }), to_bson({ "$set":
  patch }))` sets only the sent fields. `mongo_update` and `mongo_delete` refuse
  a filter that lost a none field (it would match everything).
- Calls start with `(client, db, coll, ...)`: `mongo_insert(..., docs)`,
  `mongo_update(..., filter, update, many = false, upsert = false)`,
  `mongo_delete(..., filter, many = false)`, `mongo_find(..., filter)`,
  `mongo_find_with(..., filter, MongoFindOptions { sort, projection, skip, limit
  })`, `mongo_cursor(..., command)` (own `find` or `aggregate`),
  `mongo_create_indexes(..., [MongoIndex { keys, unique }])` (repeating is fine);
  `mongo_command(client, db, command)`.
- `MongoResult { document, error, code, unknown_outcome }`: always check `error`;
  `unknown_outcome`: the write may have happened; `document` is the reply
  (`bson_get_int(r.document, "n")`).
- A cursor has `documents`, `error`, `id`: read `documents`, then `mongo_next(c)`
  (false at the end or on error); `mongo_close(c)` after an early exit.
- `int` is Int64 (Int32 and whole doubles read too); `T?`: null or missing is
  none; a `Bson` field nests a document as is; exact types: `BsonObjectId { hex }`
  (`object_id()` gives a new hex), `BsonDate { milliseconds }`, `BsonBinary`.
- By hand: `let b = bson_new()`, `bson_int(b, "n", 1)`, `bson_str`, `bson_doc`,
  ..., `bson_finish(b)`; `bson_get_int(doc, key)`, `bson_get_str`, ... give `T?`.
