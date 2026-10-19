from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel

app = FastAPI()
products: list[dict] = []


@app.exception_handler(RequestValidationError)
async def validation_error(request: Request, exc: RequestValidationError):
    return JSONResponse({"error": str(exc)}, status_code=400)


class NewProduct(BaseModel):
    name: str
    category: str
    price: float
    tags: list[str] = []


class ProductPatch(BaseModel):
    name: str | None = None
    category: str | None = None
    price: float | None = None
    tags: list[str] | None = None


def validate(p: dict):
    if not p["name"].strip() or not p["category"].strip() or p["price"] < 0:
        raise HTTPException(400, "name and category are required, price must not be negative")


def find(product_id: int) -> dict:
    if not 1 <= product_id <= len(products):
        raise HTTPException(404, "product not found")
    return products[product_id - 1]


@app.post("/products", status_code=201)
async def create_product(body: NewProduct):
    product = {"id": len(products) + 1, **body.model_dump()}
    validate(product)
    products.append(product)
    return product


@app.get("/products/{product_id}")
async def get_product(product_id: int):
    return find(product_id)


@app.patch("/products/{product_id}")
async def patch_product(product_id: int, body: ProductPatch):
    updated = {**find(product_id), **body.model_dump(exclude_none=True)}
    validate(updated)
    products[product_id - 1] = updated
    return updated


SORTS = {"price": (lambda p: p["price"], False), "-price": (lambda p: p["price"], True), "name": (lambda p: p["name"], False)}


@app.get("/products")
async def list_products(
    q: str = "",
    category: str | None = None,
    tag: str | None = None,
    min_price: float | None = None,
    max_price: float | None = None,
    sort: str | None = None,
    page: int = 1,
    per_page: int = 10,
):
    if page < 1 or not 1 <= per_page <= 100:
        raise HTTPException(400, "page must be at least 1, per_page from 1 to 100")
    if sort is not None and sort not in SORTS:
        raise HTTPException(400, "sort must be price, -price or name")
    items = [
        p
        for p in products
        if q.lower() in p["name"].lower()
        and (category is None or p["category"] == category)
        and (tag is None or tag in p["tags"])
        and (min_price is None or p["price"] >= min_price)
        and (max_price is None or p["price"] <= max_price)
    ]
    if sort:
        key, reverse = SORTS[sort]
        items.sort(key=key, reverse=reverse)
    start = (page - 1) * per_page
    return {"items": items[start : start + per_page], "total": len(items), "page": page, "per_page": per_page}


@app.get("/categories")
async def categories():
    groups: dict[str, list[float]] = {}
    for p in products:
        groups.setdefault(p["category"], []).append(p["price"])
    return [
        {"name": name, "count": len(prices), "avg_price": round(sum(prices) / len(prices), 2)}
        for name, prices in sorted(groups.items())
    ]
