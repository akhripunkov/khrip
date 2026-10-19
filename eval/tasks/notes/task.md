# Notes with accounts

Write an HTTP JSON API server. It listens on port 8080 and keeps data in memory.

- `POST /register` with body `{"username": string, "password": string}`: 201 with
  `{"id": int, "username": string}`. The username is 3–32 characters and the password
  at least 8 characters, otherwise 400. A taken username: 409.
- `POST /login` with the same body: 200 with `{"token": string}`. A wrong username or
  password: 401. Each login creates a new random token of at least 20 characters;
  tokens stay valid until the server stops.
- Store passwords only as a salted slow hash (bcrypt, scrypt, Argon2 or PBKDF2),
  never as plain text.
- Every `/notes` request needs the header `Authorization: Bearer <token>`. A missing
  or unknown token: 401.
- `POST /notes` with body `{"title": string, "text": string}`: 201 with
  `{"id": int, "title": string, "text": string, "created_at": string}`. Ids are
  1, 2, 3, … across all users. `created_at` is the UTC time in ISO 8601, like
  `2026-10-19T15:04:05Z`. A blank title: 400.
- `GET /notes`: 200 with the caller's own notes in id order.
- `GET /notes/{id}`: 200 with the note; 404 if there is no such note or it belongs
  to another user.
- `DELETE /notes/{id}`: 204; 404 as above.

Error responses use the status codes above; the body is a short message in any format.
