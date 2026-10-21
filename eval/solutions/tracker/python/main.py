import os
from contextlib import asynccontextmanager
from typing import Annotated, Literal

import asyncpg
from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, StringConstraints

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
    id bigserial PRIMARY KEY,
    email text NOT NULL UNIQUE,
    name text NOT NULL
);
CREATE TABLE IF NOT EXISTS projects (
    key text PRIMARY KEY,
    name text NOT NULL,
    owner_id bigint NOT NULL REFERENCES users,
    last_number integer NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS issues (
    project text NOT NULL REFERENCES projects,
    number integer NOT NULL,
    key text GENERATED ALWAYS AS (project || '-' || number) STORED UNIQUE,
    title text NOT NULL,
    status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'in_progress', 'done')),
    priority text NOT NULL CHECK (priority IN ('low', 'medium', 'high')),
    assignee_id bigint REFERENCES users,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (project, number)
);
"""

pool: asyncpg.Pool


@asynccontextmanager
async def lifespan(app: FastAPI):
    global pool
    pool = await asyncpg.create_pool(os.environ["DATABASE_URL"])
    async with pool.acquire() as conn, conn.transaction():
        # Copies starting together would race on CREATE TABLE IF NOT EXISTS.
        await conn.execute("SELECT pg_advisory_xact_lock(hashtext('tracker schema'))")
        await conn.execute(SCHEMA)
    yield
    await pool.close()


app = FastAPI(lifespan=lifespan)


@app.exception_handler(RequestValidationError)
@app.exception_handler(asyncpg.DataError)  # an id outside bigint or a NUL character in text
async def bad_request(request: Request, exc: Exception):
    return JSONResponse({"error": str(exc)}, status_code=400)


NonBlank = Annotated[str, StringConstraints(pattern=r"\S")]
Title = Annotated[str, StringConstraints(pattern=r"\S", max_length=200)]
Status = Literal["open", "in_progress", "done"]
Priority = Literal["low", "medium", "high"]


class NewUser(BaseModel):
    email: Annotated[str, StringConstraints(pattern=r"^[^@\s]+@[^@\s]+$", to_lower=True)]
    name: NonBlank


class NewProject(BaseModel):
    key: Annotated[str, StringConstraints(pattern=r"^[A-Z]{2,5}$")]
    name: NonBlank
    owner_id: int


class NewIssue(BaseModel):
    title: Title
    priority: Priority = "medium"
    assignee_id: int | None = None


class IssuePatch(BaseModel):
    title: Title | None = None
    status: Status | None = None
    priority: Priority | None = None
    assignee_id: int | None = None


def issue_json(row: asyncpg.Record) -> dict:
    return {
        "key": row["key"],
        "project": row["project"],
        "number": row["number"],
        "title": row["title"],
        "status": row["status"],
        "priority": row["priority"],
        "assignee_id": row["assignee_id"],
        "created_at": row["created_at"].strftime("%Y-%m-%dT%H:%M:%SZ"),
        "updated_at": row["updated_at"].strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


async def require_project(db: asyncpg.Pool | asyncpg.Connection, key: str):
    if not await db.fetchval("SELECT EXISTS (SELECT 1 FROM projects WHERE key = $1)", key):
        raise HTTPException(404, "project not found")


@app.post("/users", status_code=201)
async def create_user(body: NewUser):
    row = await pool.fetchrow(
        "INSERT INTO users (email, name) VALUES ($1, $2) ON CONFLICT (email) DO NOTHING RETURNING *",
        body.email, body.name,
    )
    if row is None:
        raise HTTPException(409, "email exists")
    return dict(row)


@app.post("/projects", status_code=201)
async def create_project(body: NewProject):
    try:
        row = await pool.fetchrow(
            """INSERT INTO projects (key, name, owner_id) VALUES ($1, $2, $3)
               ON CONFLICT (key) DO NOTHING RETURNING key, name, owner_id""",
            body.key, body.name, body.owner_id,
        )
    except asyncpg.ForeignKeyViolationError:
        raise HTTPException(404, "owner not found")
    if row is None:
        raise HTTPException(409, "project exists")
    return dict(row)


@app.post("/projects/{key}/issues", status_code=201)
async def create_issue(key: str, body: NewIssue):
    async with pool.acquire() as conn, conn.transaction():
        # The project row stays locked until commit, so concurrent issues get consecutive numbers,
        # and a failed insert rolls the counter back.
        number = await conn.fetchval(
            "UPDATE projects SET last_number = last_number + 1 WHERE key = $1 RETURNING last_number", key
        )
        if number is None:
            raise HTTPException(404, "project not found")
        try:
            row = await conn.fetchrow(
                """INSERT INTO issues (project, number, title, priority, assignee_id)
                   VALUES ($1, $2, $3, $4, $5) RETURNING *""",
                key, number, body.title, body.priority, body.assignee_id,
            )
        except asyncpg.ForeignKeyViolationError:
            raise HTTPException(404, "assignee not found")
    return issue_json(row)


@app.get("/issues/{key}")
async def get_issue(key: str):
    row = await pool.fetchrow("SELECT * FROM issues WHERE key = $1", key)
    if row is None:
        raise HTTPException(404, "issue not found")
    return issue_json(row)


@app.patch("/issues/{key}")
async def update_issue(key: str, body: IssuePatch):
    given = body.model_fields_set
    if any(getattr(body, field) is None for field in given - {"assignee_id"}):
        raise HTTPException(400, "only assignee_id can be null")
    try:
        row = await pool.fetchrow(
            """UPDATE issues SET title = coalesce($2, title), status = coalesce($3, status),
                                 priority = coalesce($4, priority),
                                 assignee_id = CASE WHEN $5 THEN $6 ELSE assignee_id END,
                                 updated_at = now()
               WHERE key = $1 RETURNING *""",
            key, body.title, body.status, body.priority, "assignee_id" in given, body.assignee_id,
        )
    except asyncpg.ForeignKeyViolationError:
        raise HTTPException(404, "assignee not found")
    if row is None:
        raise HTTPException(404, "issue not found")
    return issue_json(row)


@app.delete("/issues/{key}", status_code=204)
async def delete_issue(key: str):
    if await pool.execute("DELETE FROM issues WHERE key = $1", key) == "DELETE 0":
        raise HTTPException(404, "issue not found")


@app.get("/projects/{key}/issues")
async def list_issues(
    key: str,
    status: Status | None = None,
    assignee_id: int | Literal["none"] | None = None,
    q: str | None = None,
):
    await require_project(pool, key)
    rows = await pool.fetch(
        """SELECT * FROM issues
           WHERE project = $1 AND ($2::text IS NULL OR status = $2)
             AND (NOT $3 OR assignee_id IS NOT DISTINCT FROM $4)
             AND ($5::text IS NULL OR strpos(lower(title), lower($5)) > 0)
           ORDER BY number""",
        key, status, assignee_id is not None, None if assignee_id == "none" else assignee_id, q,
    )
    return [issue_json(r) for r in rows]


@app.get("/projects/{key}/summary")
async def summary(key: str):
    # One snapshot, so that the counts agree with the assignees.
    async with pool.acquire() as conn, conn.transaction(isolation="repeatable_read", readonly=True):
        await require_project(conn, key)
        counts = await conn.fetchrow(
            """SELECT count(*) AS total,
                      count(*) FILTER (WHERE status = 'open') AS open,
                      count(*) FILTER (WHERE status = 'in_progress') AS in_progress,
                      count(*) FILTER (WHERE status = 'done') AS done
               FROM issues WHERE project = $1""",
            key,
        )
        assignees = await conn.fetch(
            """SELECT u.id, u.name, count(*) AS active
               FROM issues i JOIN users u ON u.id = i.assignee_id
               WHERE i.project = $1 AND i.status <> 'done'
               GROUP BY u.id ORDER BY active DESC, u.id""",
            key,
        )
    return {**dict(counts), "assignees": [dict(a) for a in assignees]}
