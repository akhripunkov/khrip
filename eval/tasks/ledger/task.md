# Ledger

Write an HTTP JSON API server. It listens on the port from the `PORT`
environment variable (8080 when it is not set) and keeps all data in
PostgreSQL; the connection URL is in `DATABASE_URL`
(`postgres://user:password@host:port/database?sslmode=disable`). The database
starts empty: the server creates its tables when it starts and must also start
when they already exist. Several copies of the server run at the same time on
the same database, and the server is restarted between checks.

Money is an integer number of cents. An account is
`{"id": int, "owner": string, "currency": string, "balance": int}`. A transfer is
`{"id": int, "from": int, "to": int, "amount": int, "created_at": string}`, where
`created_at` is an ISO 8601 UTC time such as `2026-10-21T19:37:54Z`.

- `POST /accounts` with body `{"owner": string, "currency": string}`: 201 with
  the new account, balance 0. `owner` is not blank; `currency` is `USD`, `EUR`
  or `GBP`; otherwise 400.
- `GET /accounts/{id}`: 200 with the account. Unknown account: 404.
- `POST /accounts/{id}/deposit` with body `{"amount": int}`: 200 with the
  account. `amount` ≤ 0: 400. Unknown account: 404.
- `POST /transfers` with body `{"from": int, "to": int, "amount": int}` moves the
  money and answers 201 with the transfer. `amount` ≤ 0 or `from` equal to `to`:
  400. An unknown account: 404. Accounts in different currencies: 422. Not
  enough money on `from`: 409, and nothing changes.
  The request may have an `Idempotency-Key` header (1–64 characters). A request
  with a key that was already used with the same body answers 201 with the
  transfer made the first time and moves no money; with a different body: 422.
  This holds when such requests arrive at the same time, too.
- `GET /accounts/{id}/transfers` with optional query parameters `limit` (1–100,
  default 20) and `before` (a transfer id): 200 with the transfers from or to
  the account, newest first (by id, descending); with `before`, only those with
  a smaller id. A bad `limit` or `before`: 400. Unknown account: 404.
- `GET /stats`: 200 with `{"accounts": int, "transfers": int, "balances":
  {"USD": int, "EUR": int, "GBP": int}}` — the number of accounts and of
  transfers and the sum of balances in each currency (0 for a currency without
  accounts).

Error responses use the status codes above; the body is a short message in any format.
