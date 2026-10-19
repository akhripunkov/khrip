# Meeting room bookings

Write an HTTP JSON API server. It listens on port 8080 and keeps data in memory.

Times are UTC strings in the form `2026-10-19T15:04:05Z`.

- `POST /rooms` with body `{"name": string, "capacity": int}`: 201 with
  `{"id": int, "name": string, "capacity": int}`. Ids are 1, 2, 3, … A blank name
  or `capacity` < 1: 400.
- `POST /bookings` with body
  `{"room_id": int, "title": string, "start": string, "end": string}`: 201 with
  `{"id": int, "room_id": int, "title": string, "start": string, "end": string}`.
  Ids are 1, 2, 3, …
  - `start` and `end` must be valid times in the form above (a real date, hours
    00–23, minutes and seconds 00–59), `end` after `start`, at most 8 hours apart,
    and the title not blank; otherwise 400.
  - Unknown room: 404.
  - The room is already booked at an overlapping time: 409. A booking that ends
    exactly when another starts does not overlap.
- `GET /rooms/{id}/bookings` with an optional query parameter `date`
  (`2026-10-19`): 200 with the room's bookings sorted by start; with `date`, only
  bookings that overlap that UTC day. A `date` not in this form: 400. Unknown
  room: 404.
- `DELETE /bookings/{id}`: 204, or 404.

Error responses use the status codes above; the body is a short message in any format.
