from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel

app = FastAPI()
polls: list[dict] = []
voters: set[tuple[int, str]] = set()


@app.exception_handler(RequestValidationError)
async def validation_error(request: Request, exc: RequestValidationError):
    return JSONResponse({"error": str(exc)}, status_code=400)


class NewPoll(BaseModel):
    question: str
    options: list[str]


class Vote(BaseModel):
    option: int


def find(poll_id: int) -> dict:
    if not 1 <= poll_id <= len(polls):
        raise HTTPException(404, "poll not found")
    return polls[poll_id - 1]


@app.post("/polls", status_code=201)
async def create_poll(body: NewPoll):
    opts = body.options
    if not body.question.strip() or not 2 <= len(opts) <= 10 or any(not o.strip() for o in opts) or len(set(opts)) != len(opts):
        raise HTTPException(400, "question and 2-10 different options are required")
    poll = {
        "id": len(polls) + 1,
        "question": body.question,
        "options": [{"text": o, "votes": 0} for o in opts],
        "closed": False,
    }
    polls.append(poll)
    return poll


@app.get("/polls/{poll_id}")
async def get_poll(poll_id: int):
    return find(poll_id)


@app.get("/polls")
async def list_polls(open: bool | None = None):
    return [p for p in polls if open is None or p["closed"] != open]


@app.post("/polls/{poll_id}/votes")
async def vote(poll_id: int, body: Vote, x_voter_id: str | None = Header(None)):
    if not x_voter_id:
        raise HTTPException(401, "X-Voter-Id is required")
    poll = find(poll_id)
    if poll["closed"]:
        raise HTTPException(403, "poll is closed")
    if not 0 <= body.option < len(poll["options"]):
        raise HTTPException(400, "no such option")
    if (poll_id, x_voter_id) in voters:
        raise HTTPException(409, "already voted")
    voters.add((poll_id, x_voter_id))
    poll["options"][body.option]["votes"] += 1
    return poll


@app.post("/polls/{poll_id}/close")
async def close_poll(poll_id: int):
    poll = find(poll_id)
    poll["closed"] = True
    return poll


@app.get("/polls/{poll_id}/results")
async def results(poll_id: int):
    options = find(poll_id)["options"]
    total = sum(o["votes"] for o in options)
    rows = [
        {"text": o["text"], "votes": o["votes"], "percent": round(o["votes"] * 100 / total, 1) if total else 0}
        for o in options
    ]
    return {"total": total, "results": sorted(rows, key=lambda r: -r["votes"])}
