from datetime import datetime, timedelta

from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel

app = FastAPI()
rooms: list[dict] = []
bookings: dict[int, dict] = {}
last_booking = 0


@app.exception_handler(RequestValidationError)
async def validation_error(request: Request, exc: RequestValidationError):
    return JSONResponse({"error": str(exc)}, status_code=400)


class NewRoom(BaseModel):
    name: str
    capacity: int


class NewBooking(BaseModel):
    room_id: int
    title: str
    start: str
    end: str


def parse(value: str, fmt: str = "%Y-%m-%dT%H:%M:%SZ") -> datetime | None:
    try:
        return datetime.strptime(value, fmt)
    except ValueError:
        return None


@app.post("/rooms", status_code=201)
async def create_room(body: NewRoom):
    if not body.name.strip() or body.capacity < 1:
        raise HTTPException(400, "name is required and capacity must be at least 1")
    room = {"id": len(rooms) + 1, **body.model_dump()}
    rooms.append(room)
    return room


@app.post("/bookings", status_code=201)
async def create_booking(body: NewBooking):
    global last_booking
    start, end = parse(body.start), parse(body.end)
    if not start or not end or end <= start or end - start > timedelta(hours=8) or not body.title.strip():
        raise HTTPException(400, "need a title and valid start < end, at most 8 hours apart")
    if not 1 <= body.room_id <= len(rooms):
        raise HTTPException(404, "room not found")
    for b in bookings.values():
        if b["room_id"] == body.room_id and parse(b["start"]) < end and start < parse(b["end"]):
            raise HTTPException(409, "the room is booked at that time")
    last_booking += 1
    booking = {"id": last_booking, **body.model_dump()}
    bookings[last_booking] = booking
    return booking


@app.get("/rooms/{room_id}/bookings")
async def room_bookings(room_id: int, date: str | None = None):
    lo, hi = datetime.min, datetime.max
    if date is not None:
        lo = parse(date, "%Y-%m-%d")
        if lo is None:
            raise HTTPException(400, "date must look like 2026-10-19")
        hi = lo + timedelta(days=1)
    if not 1 <= room_id <= len(rooms):
        raise HTTPException(404, "room not found")
    found = [b for b in bookings.values() if b["room_id"] == room_id and parse(b["start"]) < hi and lo < parse(b["end"])]
    return sorted(found, key=lambda b: b["start"])


@app.delete("/bookings/{booking_id}", status_code=204)
async def delete_booking(booking_id: int):
    if bookings.pop(booking_id, None) is None:
        raise HTTPException(404, "booking not found")
    return Response(status_code=204)
