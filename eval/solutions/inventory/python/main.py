import re
from collections import Counter
from typing import Literal

from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel

app = FastAPI()
items: dict[str, dict] = {}
orders: list[dict] = []


@app.exception_handler(RequestValidationError)
async def validation_error(request: Request, exc: RequestValidationError):
    return JSONResponse({"error": str(exc)}, status_code=400)


class Item(BaseModel):
    sku: str
    name: str
    stock: int


class Restock(BaseModel):
    amount: int


class Line(BaseModel):
    sku: str
    qty: int


class NewOrder(BaseModel):
    lines: list[Line]


@app.post("/items", status_code=201)
async def add_item(body: Item):
    if not re.fullmatch(r"[A-Z0-9-]{3,20}", body.sku) or not body.name.strip() or body.stock < 0:
        raise HTTPException(400, "sku must be 3-20 of A-Z, 0-9, -; name required; stock >= 0")
    if body.sku in items:
        raise HTTPException(409, "sku exists")
    items[body.sku] = body.model_dump()
    return items[body.sku]


@app.get("/items")
async def list_items():
    return sorted(items.values(), key=lambda i: i["sku"])


@app.post("/items/{sku}/restock")
async def restock(sku: str, body: Restock):
    if sku not in items:
        raise HTTPException(404, "unknown sku")
    if body.amount <= 0:
        raise HTTPException(400, "amount must be positive")
    items[sku]["stock"] += body.amount
    return items[sku]


@app.post("/orders", status_code=201)
async def place_order(body: NewOrder):
    if not body.lines or any(l.qty <= 0 for l in body.lines):
        raise HTTPException(400, "lines must not be empty and qty must be positive")
    need = Counter()
    for l in body.lines:
        need[l.sku] += l.qty
    for sku, qty in need.items():
        if sku not in items:
            raise HTTPException(404, f"unknown sku {sku}")
        if items[sku]["stock"] < qty:
            raise HTTPException(409, f"not enough {sku}")
    for sku, qty in need.items():
        items[sku]["stock"] -= qty
    order = {
        "id": len(orders) + 1,
        "lines": [l.model_dump() for l in body.lines],
        "status": "placed",
        "total_qty": sum(need.values()),
    }
    orders.append(order)
    return order


@app.post("/orders/{order_id}/cancel")
async def cancel_order(order_id: int):
    if not 1 <= order_id <= len(orders):
        raise HTTPException(404, "unknown order")
    order = orders[order_id - 1]
    if order["status"] == "cancelled":
        raise HTTPException(409, "already cancelled")
    order["status"] = "cancelled"
    for l in order["lines"]:
        items[l["sku"]]["stock"] += l["qty"]
    return order


@app.get("/orders")
async def list_orders(status: Literal["placed", "cancelled"] | None = None):
    return [o for o in orders if status is None or o["status"] == status]
