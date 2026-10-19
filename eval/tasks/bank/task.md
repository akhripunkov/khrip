# Bank accounts

Write an HTTP JSON API server. It listens on port 8080 and keeps data in memory.
Amounts are integers (cents). Many requests may arrive at the same time: no update
may be lost and a balance must never go below 0.

- `POST /accounts` with body `{"owner": string}`: 201 with
  `{"id": int, "owner": string, "balance": 0}`. Ids are 1, 2, 3, … A blank owner: 400.
- `GET /accounts/{id}`: 200 with the account, or 404.
- `POST /accounts/{id}/deposit` with body `{"amount": int}`: 200 with the updated
  account. `amount` ≤ 0: 400. Unknown account: 404.
- `POST /transfers` with body `{"from_id": int, "to_id": int, "amount": int}` moves
  money and answers 201 with the transfer
  `{"id": int, "from_id": int, "to_id": int, "amount": int, "created_at": string}`.
  Transfer ids are 1, 2, 3, … `created_at` is the UTC time in ISO 8601, like
  `2026-10-19T15:04:05Z`.
  - `amount` ≤ 0 or `from_id` equal to `to_id`: 400.
  - Either account does not exist: 404.
  - Not enough money on the sender's account: 409, nothing changes.
- `GET /accounts/{id}/transfers`: 200 with the transfers where the account is the
  sender or the receiver, newest first. Unknown account: 404.

Error responses use the status codes above; the body is a short message in any format.
