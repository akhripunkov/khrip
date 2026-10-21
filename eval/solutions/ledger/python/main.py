import os
from contextlib import asynccontextmanager
from typing import Annotated, Literal, get_args

import asyncpg
from fastapi import Body, FastAPI, Header, HTTPException, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel

SCHEMA = """
CREATE TABLE IF NOT EXISTS accounts (
    id bigserial PRIMARY KEY,
    owner text NOT NULL,
    currency text NOT NULL,
    balance bigint NOT NULL DEFAULT 0 CHECK (balance >= 0)
);
CREATE TABLE IF NOT EXISTS transfers (
    id bigserial PRIMARY KEY,
    from_id bigint NOT NULL REFERENCES accounts,
    to_id bigint NOT NULL REFERENCES accounts,
    amount bigint NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    idempotency_key text UNIQUE
);
CREATE INDEX IF NOT EXISTS transfers_from_id ON transfers (from_id, id);
CREATE INDEX IF NOT EXISTS transfers_to_id ON transfers (to_id, id);
"""

Currency = Literal["USD", "EUR", "GBP"]
pool: asyncpg.Pool


@asynccontextmanager
async def lifespan(app: FastAPI):
    global pool
    pool = await asyncpg.create_pool(os.environ["DATABASE_URL"])
    async with pool.acquire() as conn, conn.transaction():
        # Copies starting together would race on CREATE TABLE IF NOT EXISTS.
        await conn.execute("SELECT pg_advisory_xact_lock(hashtext('ledger schema'))")
        await conn.execute(SCHEMA)
    yield
    await pool.close()


app = FastAPI(lifespan=lifespan)


@app.exception_handler(RequestValidationError)
async def validation_error(request: Request, exc: RequestValidationError):
    return JSONResponse({"error": str(exc)}, status_code=400)


class NewAccount(BaseModel):
    owner: str
    currency: Currency


class Amount(BaseModel):
    amount: int


def transfer_json(row: asyncpg.Record) -> dict:
    return {
        "id": row["id"],
        "from": row["from_id"],
        "to": row["to_id"],
        "amount": row["amount"],
        "created_at": row["created_at"].strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


@app.post("/accounts", status_code=201)
async def create_account(body: NewAccount):
    if not body.owner.strip():
        raise HTTPException(400, "owner is required")
    row = await pool.fetchrow(
        "INSERT INTO accounts (owner, currency) VALUES ($1, $2) RETURNING *", body.owner, body.currency
    )
    return dict(row)


@app.get("/accounts/{account_id}")
async def get_account(account_id: int):
    row = await pool.fetchrow("SELECT * FROM accounts WHERE id = $1", account_id)
    if row is None:
        raise HTTPException(404, "account not found")
    return dict(row)


@app.post("/accounts/{account_id}/deposit")
async def deposit(account_id: int, body: Amount):
    if body.amount <= 0:
        raise HTTPException(400, "amount must be positive")
    row = await pool.fetchrow(
        "UPDATE accounts SET balance = balance + $2 WHERE id = $1 RETURNING *", account_id, body.amount
    )
    if row is None:
        raise HTTPException(404, "account not found")
    return dict(row)


@app.post("/transfers", status_code=201)
async def transfer(
    from_: Annotated[int, Body(alias="from")],
    to: Annotated[int, Body()],
    amount: Annotated[int, Body()],
    idempotency_key: Annotated[str | None, Header(min_length=1, max_length=64)] = None,
):
    if amount <= 0 or from_ == to:
        raise HTTPException(400, "amount must be positive and accounts different")
    async with pool.acquire() as conn, conn.transaction():
        if idempotency_key is not None:
            # Requests with one key run one after another; a later one finds the committed transfer.
            await conn.execute("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", idempotency_key)
            done = await conn.fetchrow("SELECT * FROM transfers WHERE idempotency_key = $1", idempotency_key)
            if done is not None:
                if (done["from_id"], done["to_id"], done["amount"]) != (from_, to, amount):
                    raise HTTPException(422, "idempotency key was used with another request")
                return transfer_json(done)
        # Locking both rows in id order keeps crossing transfers from deadlocking.
        rows = await conn.fetch(
            "SELECT id, currency, balance FROM accounts WHERE id = ANY($1::bigint[]) ORDER BY id FOR UPDATE",
            [from_, to],
        )
        accounts = {r["id"]: r for r in rows}
        if len(accounts) < 2:
            raise HTTPException(404, "account not found")
        source, target = accounts[from_], accounts[to]
        if source["currency"] != target["currency"]:
            raise HTTPException(422, "accounts have different currencies")
        if source["balance"] < amount:
            raise HTTPException(409, "insufficient funds")
        await conn.execute("UPDATE accounts SET balance = balance - $2 WHERE id = $1", from_, amount)
        await conn.execute("UPDATE accounts SET balance = balance + $2 WHERE id = $1", to, amount)
        row = await conn.fetchrow(
            "INSERT INTO transfers (from_id, to_id, amount, idempotency_key) VALUES ($1, $2, $3, $4) RETURNING *",
            from_, to, amount, idempotency_key,
        )
    return transfer_json(row)


@app.get("/accounts/{account_id}/transfers")
async def history(
    account_id: int,
    limit: Annotated[int, Query(ge=1, le=100)] = 20,
    before: int | None = None,
):
    if not await pool.fetchval("SELECT EXISTS (SELECT 1 FROM accounts WHERE id = $1)", account_id):
        raise HTTPException(404, "account not found")
    rows = await pool.fetch(
        """SELECT * FROM transfers
           WHERE (from_id = $1 OR to_id = $1) AND ($2::bigint IS NULL OR id < $2)
           ORDER BY id DESC LIMIT $3""",
        account_id, before, limit,
    )
    return [transfer_json(r) for r in rows]


@app.get("/stats")
async def stats():
    rows = await pool.fetch(
        "SELECT currency, count(*) AS accounts, sum(balance)::bigint AS balance FROM accounts GROUP BY currency"
    )
    transfers = await pool.fetchval("SELECT count(*) FROM transfers")
    return {
        "accounts": sum(r["accounts"] for r in rows),
        "transfers": transfers,
        "balances": {c: 0 for c in get_args(Currency)} | {r["currency"]: r["balance"] for r in rows},
    }
