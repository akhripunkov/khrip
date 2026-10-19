import hashlib
import hmac
import os
import secrets
from datetime import datetime, timezone

from fastapi import FastAPI, Header, HTTPException, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel

app = FastAPI()
users: dict[str, dict] = {}
sessions: dict[str, str] = {}
notes: dict[int, dict] = {}
last_note = 0


@app.exception_handler(RequestValidationError)
async def validation_error(request: Request, exc: RequestValidationError):
    return JSONResponse({"error": str(exc)}, status_code=400)


class Credentials(BaseModel):
    username: str
    password: str


class NewNote(BaseModel):
    title: str
    text: str = ""


def hash_password(password: str, salt: bytes) -> bytes:
    return hashlib.pbkdf2_hmac("sha256", password.encode(), salt, 100_000)


def current_user(authorization: str | None = Header(None)) -> str:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "unauthorized")
    user = sessions.get(authorization[7:])
    if user is None:
        raise HTTPException(401, "unauthorized")
    return user


def own_note(note_id: int, user: str) -> dict:
    note = notes.get(note_id)
    if note is None or note["owner"] != user:
        raise HTTPException(404, "note not found")
    return note


def public(note: dict) -> dict:
    return {k: v for k, v in note.items() if k != "owner"}


@app.post("/register", status_code=201)
def register(body: Credentials):
    if not 3 <= len(body.username) <= 32 or len(body.password) < 8:
        raise HTTPException(400, "username must be 3-32 characters, password at least 8")
    if body.username in users:
        raise HTTPException(409, "username is taken")
    salt = os.urandom(16)
    user = {"id": len(users) + 1, "username": body.username, "salt": salt, "hash": hash_password(body.password, salt)}
    users[body.username] = user
    return {"id": user["id"], "username": user["username"]}


@app.post("/login")
def login(body: Credentials):
    user = users.get(body.username)
    if user is None or not hmac.compare_digest(hash_password(body.password, user["salt"]), user["hash"]):
        raise HTTPException(401, "invalid credentials")
    token = secrets.token_urlsafe(32)
    sessions[token] = body.username
    return {"token": token}


@app.post("/notes", status_code=201)
def create_note(body: NewNote, authorization: str | None = Header(None)):
    global last_note
    user = current_user(authorization)
    if not body.title.strip():
        raise HTTPException(400, "title is required")
    last_note += 1
    note = {
        "id": last_note,
        "title": body.title,
        "text": body.text,
        "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "owner": user,
    }
    notes[last_note] = note
    return public(note)


@app.get("/notes")
def list_notes(authorization: str | None = Header(None)):
    user = current_user(authorization)
    return [public(n) for n in sorted(notes.values(), key=lambda n: n["id"]) if n["owner"] == user]


@app.get("/notes/{note_id}")
def get_note(note_id: int, authorization: str | None = Header(None)):
    return public(own_note(note_id, current_user(authorization)))


@app.delete("/notes/{note_id}", status_code=204)
def delete_note(note_id: int, authorization: str | None = Header(None)):
    own_note(note_id, current_user(authorization))
    del notes[note_id]
    return Response(status_code=204)
