# PostgreSQL

The server uses `DATABASE_URL` (`postgres://user:pass@host:5432/db?sslmode=disable`).
The compiler checks SQL against the migrations, the server against the database
at start.

```khrip
migration 1 `
CREATE TABLE accounts (id bigserial PRIMARY KEY, owner text NOT NULL,
    balance bigint NOT NULL DEFAULT 0 CHECK (balance >= 0),
    created_at timestamptz NOT NULL DEFAULT now());
`
type Account { id: int, owner: str, balance: int, created_at: str }

route POST "/accounts" (body: { owner: str }) -> 201 Account {
    return 201 sql "INSERT INTO accounts {body} RETURNING *"   // fields → columns
}

route POST "/transfers" (body: { from: int, to: int, amount: int }) -> 204 | 404 | 409 str {
    tx {
        let from: Account = sql "SELECT * FROM accounts WHERE id = {body.from}"  // none: 404
        let to: Account = sql "SELECT * FROM accounts WHERE id = {body.to}"
        if from.balance < body.amount {
            return 409 "insufficient funds"                    // rolls back
        }
        sql "UPDATE accounts SET balance = balance - {body.amount} WHERE id = {from.id}"
        sql "UPDATE accounts SET balance = balance + {body.amount} WHERE id = {to.id}"
    }
    return 204
}
```

- `sql "..."` (or `` sql `...` ``) runs one statement. `{expr}` is a typed
  parameter (no `::cast`), never SQL text; `none` is NULL, so compare an optional
  exactly as `({x} IS NULL OR col = {x})`. `IN ({list})` takes a list; `ILIKE
  '%{q}%'` matches q literally; `ORDER BY {o}` takes a local made of string
  literals.
- The expected type picks the result: `T` one row, none → 404 (the route lists
  `| 404`, or `let r: T = sql "..." else { return 401 }`); `T?` one row or none
  (more is a 500: add `LIMIT 1`); `[T]` all rows; no type: rows changed. `T` is
  a struct (columns by name) or one column's type: `let n: int = sql "SELECT
  count(*) ..."`.
- timestamptz → `str` (as `time_iso`) or `int`; date → `"2026-01-02"` or `int`;
  numeric → `float`; json and jsonb → any type; a nullable column → `T?`.
- `INSERT INTO t {v}` puts fields into columns of the same name (`none` → the
  column default); `{rows}` with a list inserts them all. `SET {patch}` sets only
  the fields the request sent. A duplicate allowed: `let r: T? = sql "INSERT ...
  ON CONFLICT DO NOTHING RETURNING *"` (none: it existed).
- `migration N` runs once, in order, at start; never edit one that ran: add the
  next number.
- A failed statement ends the request: duplicate or CHECK 409, missing foreign
  key 404, row still referenced 409, NOT NULL or a bad value 400, database down
  or busy 503.
- Outside `tx` each statement commits on its own, so in a route a write after
  another statement (or in a loop) is an error: use `tx { }`. `tx` is
  SERIALIZABLE and runs again on a conflict, so inside it no `fetch`, `sleep`,
  `call`, MongoDB, ClickHouse, store or outer-variable changes; a status from
  400, `fail` or a panic rolls it back. `let t = tx { ...; value }` commits and
  gives the value.
- `khc test` uses a temporary schema of `KHRIP_TEST_DATABASE_URL` (else
  `DATABASE_URL`).
