# Шлюз: цена товара из сервиса UPSTREAM с налогом 20%.
import os

import httpx
from fastapi import FastAPI
from fastapi.responses import PlainTextResponse
from pydantic import BaseModel, ValidationError

UP = os.environ.get("UPSTREAM", "http://127.0.0.1:9090")
app = FastAPI()
# по умолчанию httpx держит не больше 100 соединений — для шлюза мало
client = httpx.AsyncClient(limits=httpx.Limits(max_connections=1024, max_keepalive_connections=1024))


class Item(BaseModel):
    id: int
    name: str
    price: int


@app.get("/quote")
async def quote(id: int):
    try:
        r = await client.get(f"{UP}/item", params={"id": id})
        if r.status_code == 200:
            item = Item.model_validate_json(r.content)
            return {"id": item.id, "name": item.name, "total": item.price * 120 // 100}
    except (httpx.HTTPError, ValidationError):
        pass
    return PlainTextResponse("upstream failed", status_code=502)
