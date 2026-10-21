import json
import os
from contextlib import asynccontextmanager
from typing import Annotated, Literal

import asyncpg
from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import AfterValidator, BaseModel, Field, StringConstraints

SCHEMA = """
CREATE TABLE IF NOT EXISTS categories (
    id bigserial PRIMARY KEY,
    name text NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS categories_name ON categories (lower(name));
CREATE TABLE IF NOT EXISTS products (
    id bigserial PRIMARY KEY,
    name text NOT NULL,
    category_id bigint NOT NULL REFERENCES categories,
    price bigint NOT NULL CHECK (price > 0),
    stock bigint NOT NULL CHECK (stock >= 0),
    tags text[] NOT NULL
);
CREATE INDEX IF NOT EXISTS products_category_id ON products (category_id);
CREATE TABLE IF NOT EXISTS orders (
    id bigserial PRIMARY KEY,
    customer text NOT NULL,
    status text NOT NULL DEFAULT 'placed' CHECK (status IN ('placed', 'cancelled')),
    total bigint NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS orders_customer ON orders (customer, id);
CREATE TABLE IF NOT EXISTS order_lines (
    order_id bigint NOT NULL REFERENCES orders,
    product_id bigint NOT NULL REFERENCES products,
    line_no int NOT NULL,
    qty bigint NOT NULL,
    price bigint NOT NULL,
    PRIMARY KEY (order_id, product_id)
);
"""

pool: asyncpg.Pool


@asynccontextmanager
async def lifespan(app: FastAPI):
    global pool
    pool = await asyncpg.create_pool(os.environ["DATABASE_URL"])
    async with pool.acquire() as conn, conn.transaction():
        # Copies starting together would race on CREATE TABLE IF NOT EXISTS.
        await conn.execute("SELECT pg_advisory_xact_lock(hashtext('shop schema'))")
        await conn.execute(SCHEMA)
    yield
    await pool.close()


app = FastAPI(lifespan=lifespan)


@app.exception_handler(RequestValidationError)
@app.exception_handler(asyncpg.DataError)  # a number outside bigint: an id, price, filter or order total
async def bad_request(request: Request, exc: Exception):
    return JSONResponse({"error": str(exc)}, status_code=400)


NonBlank = Annotated[str, StringConstraints(pattern=r"\S")]
Price = Annotated[int, Field(gt=0)]
Stock = Annotated[int, Field(ge=0)]
Tags = Annotated[
    list[Annotated[str, StringConstraints(pattern=r"^[a-z0-9]{1,20}$")]],
    Field(max_length=5),
    AfterValidator(lambda tags: list(dict.fromkeys(tags))),
]


class NewCategory(BaseModel):
    name: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=50)]


class NewProduct(BaseModel):
    name: NonBlank
    category_id: int
    price: Price
    stock: Stock
    tags: Tags = []


class ProductPatch(BaseModel):
    name: NonBlank | None = None
    price: Price | None = None
    stock: Stock | None = None
    tags: Tags | None = None


class Line(BaseModel):
    product_id: int
    qty: Annotated[int, Field(gt=0)]


class NewOrder(BaseModel):
    customer: Annotated[str, StringConstraints(pattern=r"^[^@\s]+@[^@\s]+$", to_lower=True)]
    lines: Annotated[list[Line], Field(min_length=1)]


@app.post("/categories", status_code=201)
async def create_category(body: NewCategory):
    row = await pool.fetchrow(
        "INSERT INTO categories (name) VALUES ($1) ON CONFLICT (lower(name)) DO NOTHING RETURNING *", body.name
    )
    if row is None:
        raise HTTPException(409, "category exists")
    return dict(row)


@app.get("/categories")
async def list_categories():
    return [dict(r) for r in await pool.fetch("SELECT * FROM categories ORDER BY name")]


@app.post("/products", status_code=201)
async def create_product(body: NewProduct):
    try:
        row = await pool.fetchrow(
            "INSERT INTO products (name, category_id, price, stock, tags) VALUES ($1, $2, $3, $4, $5) RETURNING *",
            body.name, body.category_id, body.price, body.stock, body.tags,
        )
    except asyncpg.ForeignKeyViolationError:
        raise HTTPException(404, "category not found")
    return dict(row)


@app.get("/products/{product_id}")
async def get_product(product_id: int):
    row = await pool.fetchrow("SELECT * FROM products WHERE id = $1", product_id)
    if row is None:
        raise HTTPException(404, "product not found")
    return dict(row)


@app.patch("/products/{product_id}")
async def update_product(product_id: int, body: ProductPatch):
    if any(getattr(body, field) is None for field in body.model_fields_set):
        raise HTTPException(400, "fields cannot be null")
    row = await pool.fetchrow(
        """UPDATE products SET name = coalesce($2, name), price = coalesce($3, price),
                               stock = coalesce($4, stock), tags = coalesce($5, tags)
           WHERE id = $1 RETURNING *""",
        product_id, body.name, body.price, body.stock, body.tags,
    )
    if row is None:
        raise HTTPException(404, "product not found")
    return dict(row)


SORTS = {None: "id", "price": "price, id", "-price": "price DESC, id", "name": "name, id"}


@app.get("/products")
async def list_products(
    category_id: int | None = None,
    tag: str | None = None,
    q: str | None = None,
    min_price: int | None = None,
    max_price: int | None = None,
    in_stock: bool = False,
    sort: Literal["price", "-price", "name"] | None = None,
    page: Annotated[int, Query(ge=1)] = 1,
    per_page: Annotated[int, Query(ge=1, le=50)] = 10,
):
    where = """($1::bigint IS NULL OR category_id = $1)
        AND ($2::text IS NULL OR $2 = ANY (tags))
        AND ($3::text IS NULL OR strpos(lower(name), lower($3)) > 0)
        AND ($4::bigint IS NULL OR price >= $4)
        AND ($5::bigint IS NULL OR price <= $5)
        AND (NOT $6 OR stock > 0)"""
    args = category_id, tag, q, min_price, max_price, in_stock
    # One snapshot for both queries, so that total agrees with the page.
    async with pool.acquire() as conn, conn.transaction(isolation="repeatable_read", readonly=True):
        total = await conn.fetchval(f"SELECT count(*) FROM products WHERE {where}", *args)
        rows = await conn.fetch(
            f"SELECT * FROM products WHERE {where} ORDER BY {SORTS[sort]} LIMIT $7 OFFSET $8",
            *args, per_page, (page - 1) * per_page,
        )
    return {"items": [dict(r) for r in rows], "total": total}


async def fetch_orders(db: asyncpg.Pool | asyncpg.Connection, condition: str, *args) -> list[dict]:
    rows = await db.fetch(
        f"""SELECT o.*, json_agg(json_build_object('product_id', l.product_id, 'qty', l.qty, 'price', l.price)
                                 ORDER BY l.line_no) AS lines
            FROM orders o JOIN order_lines l ON l.order_id = o.id
            WHERE {condition} GROUP BY o.id ORDER BY o.id DESC""",
        *args,
    )
    return [
        {**dict(r), "created_at": r["created_at"].strftime("%Y-%m-%dT%H:%M:%SZ"), "lines": json.loads(r["lines"])}
        for r in rows
    ]


@app.post("/orders", status_code=201)
async def place_order(body: NewOrder):
    qty: dict[int, int] = {}
    for line in body.lines:
        qty[line.product_id] = qty.get(line.product_id, 0) + line.qty
    async with pool.acquire() as conn, conn.transaction():
        # Locking the products in id order keeps concurrent orders and cancellations from deadlocking.
        rows = await conn.fetch(
            "SELECT id, price, stock FROM products WHERE id = ANY($1::bigint[]) ORDER BY id FOR UPDATE", list(qty)
        )
        products = {r["id"]: r for r in rows}
        if len(products) < len(qty):
            raise HTTPException(404, "product not found")
        if any(products[p]["stock"] < n for p, n in qty.items()):
            raise HTTPException(409, "not enough stock")
        order_id = await conn.fetchval(
            "INSERT INTO orders (customer, total) VALUES ($1, $2) RETURNING id",
            body.customer, sum(n * products[p]["price"] for p, n in qty.items()),
        )
        await conn.executemany(
            "INSERT INTO order_lines (order_id, product_id, line_no, qty, price) VALUES ($1, $2, $3, $4, $5)",
            [(order_id, p, i, n, products[p]["price"]) for i, (p, n) in enumerate(qty.items())],
        )
        await conn.executemany("UPDATE products SET stock = stock - $2 WHERE id = $1", qty.items())
        return (await fetch_orders(conn, "o.id = $1", order_id))[0]


@app.post("/orders/{order_id}/cancel")
async def cancel_order(order_id: int):
    async with pool.acquire() as conn, conn.transaction():
        status = await conn.fetchval("SELECT status FROM orders WHERE id = $1 FOR UPDATE", order_id)
        if status is None:
            raise HTTPException(404, "order not found")
        if status == "cancelled":
            raise HTTPException(409, "order already cancelled")
        await conn.execute("UPDATE orders SET status = 'cancelled' WHERE id = $1", order_id)
        lines = await conn.fetch(
            "SELECT product_id, qty FROM order_lines WHERE order_id = $1 ORDER BY product_id", order_id
        )
        await conn.executemany("UPDATE products SET stock = stock + $2 WHERE id = $1", lines)
        return (await fetch_orders(conn, "o.id = $1", order_id))[0]


@app.get("/customers/{email}/orders")
async def customer_orders(email: str):
    return await fetch_orders(pool, "o.customer = $1", email.lower())


@app.get("/stats/categories")
async def category_stats():
    rows = await pool.fetch(
        """SELECT c.name AS category, count(DISTINCT p.id) AS products,
                  coalesce(sum(l.qty), 0)::bigint AS units_sold,
                  coalesce(sum(l.qty * l.price), 0)::bigint AS revenue
           FROM categories c
           LEFT JOIN products p ON p.category_id = c.id
           LEFT JOIN (order_lines l JOIN orders o ON o.id = l.order_id AND o.status = 'placed')
                  ON l.product_id = p.id
           GROUP BY c.id ORDER BY revenue DESC, c.name"""
    )
    return [dict(r) for r in rows]
