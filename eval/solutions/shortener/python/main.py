import re
import secrets
import string

from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, RedirectResponse, Response
from pydantic import BaseModel

app = FastAPI()
links: dict[str, dict] = {}
ALPHABET = string.ascii_letters + string.digits


@app.exception_handler(RequestValidationError)
async def validation_error(request: Request, exc: RequestValidationError):
    return JSONResponse({"error": str(exc)}, status_code=400)


class NewLink(BaseModel):
    url: str
    code: str | None = None


@app.post("/links", status_code=201)
async def create_link(body: NewLink):
    if not body.url.startswith(("http://", "https://")):
        raise HTTPException(400, "url must start with http:// or https://")
    code = body.code
    if code is None:
        code = "".join(secrets.choice(ALPHABET) for _ in range(7))
        while code in links:
            code = "".join(secrets.choice(ALPHABET) for _ in range(7))
    elif not re.fullmatch(r"[A-Za-z0-9_-]{3,32}", code):
        raise HTTPException(400, "code must be 3-32 letters, digits, - or _")
    elif code in links:
        raise HTTPException(409, "code is taken")
    links[code] = {"code": code, "url": body.url, "clicks": 0}
    return links[code]


@app.get("/links")
async def list_links():
    return sorted(links.values(), key=lambda l: (-l["clicks"], l["code"]))


@app.get("/links/{code}")
async def get_link(code: str):
    if code not in links:
        raise HTTPException(404, "not found")
    return links[code]


@app.delete("/links/{code}", status_code=204)
async def delete_link(code: str):
    if links.pop(code, None) is None:
        raise HTTPException(404, "not found")
    return Response(status_code=204)


@app.get("/{code}")
async def follow(code: str):
    if code not in links:
        raise HTTPException(404, "not found")
    links[code]["clicks"] += 1
    return RedirectResponse(links[code]["url"], status_code=302)
