from datetime import datetime, timezone

from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel

app = FastAPI()
accounts: dict[int, dict] = {}
transfers: list[dict] = []


@app.exception_handler(RequestValidationError)
async def validation_error(request: Request, exc: RequestValidationError):
    return JSONResponse({"error": str(exc)}, status_code=400)


class NewAccount(BaseModel):
    owner: str


class Amount(BaseModel):
    amount: int


class NewTransfer(BaseModel):
    from_id: int
    to_id: int
    amount: int


def find(account_id: int) -> dict:
    if account_id not in accounts:
        raise HTTPException(404, "account not found")
    return accounts[account_id]


@app.post("/accounts", status_code=201)
async def create_account(body: NewAccount):
    if not body.owner.strip():
        raise HTTPException(400, "owner is required")
    account = {"id": len(accounts) + 1, "owner": body.owner, "balance": 0}
    accounts[account["id"]] = account
    return account


@app.get("/accounts/{account_id}")
async def get_account(account_id: int):
    return find(account_id)


@app.post("/accounts/{account_id}/deposit")
async def deposit(account_id: int, body: Amount):
    account = find(account_id)
    if body.amount <= 0:
        raise HTTPException(400, "amount must be positive")
    account["balance"] += body.amount
    return account


@app.post("/transfers", status_code=201)
async def transfer(body: NewTransfer):
    if body.amount <= 0 or body.from_id == body.to_id:
        raise HTTPException(400, "amount must be positive and accounts different")
    source, target = find(body.from_id), find(body.to_id)
    if source["balance"] < body.amount:
        raise HTTPException(409, "insufficient funds")
    source["balance"] -= body.amount
    target["balance"] += body.amount
    t = {
        "id": len(transfers) + 1,
        **body.model_dump(),
        "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    transfers.append(t)
    return t


@app.get("/accounts/{account_id}/transfers")
async def history(account_id: int):
    find(account_id)
    return [t for t in reversed(transfers) if account_id in (t["from_id"], t["to_id"])]
