from enum import Enum

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

app = FastAPI()


class Status(str, Enum):
    Todo = "Todo"
    Doing = "Doing"
    Done = "Done"


class NewTask(BaseModel):
    title: str
    status: Status = Status.Todo
    tags: list[str] = []


class Task(NewTask):
    id: int


class Stats(BaseModel):
    total: int
    done: int
    open: int


tasks: dict[int, Task] = {}
last_id = 0


@app.post("/tasks", status_code=201)
def create_task(body: NewTask) -> Task:
    global last_id
    if not body.title.strip():
        raise HTTPException(400, "title is required")
    last_id += 1
    task = Task(id=last_id, **body.model_dump())
    tasks[task.id] = task
    return task


@app.get("/tasks")
def list_tasks(status: Status | None = None, tag: str | None = None) -> list[Task]:
    found = [t for t in tasks.values() if (status is None or t.status == status) and (tag is None or tag in t.tags)]
    return sorted(found, key=lambda t: t.title)


@app.get("/tasks/{id}")
def get_task(id: int) -> Task:
    if id not in tasks:
        raise HTTPException(404)
    return tasks[id]


@app.put("/tasks/{id}/status")
def set_status(id: int, status: Status) -> Task:
    if id not in tasks:
        raise HTTPException(404)
    tasks[id].status = status
    return tasks[id]


@app.get("/stats")
def stats() -> Stats:
    done = sum(1 for t in tasks.values() if t.status == Status.Done)
    return Stats(total=len(tasks), done=done, open=len(tasks) - done)
