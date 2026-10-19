from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

app = FastAPI()


class NewUser(BaseModel):
    name: str
    email: str
    age: int


class User(NewUser):
    id: int


users: dict[int, User] = {}
next_id = 1


@app.post("/users", status_code=201)
def create_user(data: NewUser) -> User:
    global next_id
    if not data.name:
        raise HTTPException(400, "name is required")
    if "@" not in data.email:
        raise HTTPException(400, "email is invalid")
    if not 0 <= data.age <= 150:
        raise HTTPException(400, "age is out of range")
    user = User(id=next_id, **data.model_dump())
    users[user.id] = user
    next_id += 1
    return user


@app.get("/users/{id}")
def get_user(id: int) -> User:
    if id not in users:
        raise HTTPException(404)
    return users[id]


@app.get("/users")
def list_users() -> list[User]:
    return list(users.values())


@app.delete("/users/{id}", status_code=204)
def delete_user(id: int) -> None:
    if users.pop(id, None) is None:
        raise HTTPException(404)
