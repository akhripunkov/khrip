# Issue tracker

Write an HTTP JSON API server. It listens on the port from the `PORT`
environment variable (8080 when it is not set) and keeps all data in
PostgreSQL; the connection URL is in `DATABASE_URL`
(`postgres://user:password@host:port/database?sslmode=disable`). The database
starts empty: the server creates its tables when it starts and must also start
when they already exist. Several copies of the server run at the same time on
the same database, and the server is restarted between checks.

A user is `{"id": int, "email": string, "name": string}`. A project is
`{"key": string, "name": string, "owner_id": int}`. An issue is `{"key": string,
"project": string, "number": int, "title": string, "status": string,
"priority": string, "assignee_id": int or null, "created_at": string,
"updated_at": string}`; its key is the project key, `-` and the number
(`API-7`); times are ISO 8601 UTC such as `2026-10-21T19:37:54Z`.

- `POST /users` with body `{"email": string, "name": string}`: 201 with the user.
  `email` has one `@` with something on both sides and no spaces, and is stored
  in lower case; `name` is not blank; otherwise 400. An email that exists
  (ignoring case): 409.
- `POST /projects` with body `{"key": string, "name": string, "owner_id": int}`:
  201 with the project. `key` is 2–5 upper-case Latin letters, `name` is not
  blank; otherwise 400. An existing key: 409. An unknown owner: 404.
- `POST /projects/{key}/issues` with body `{"title": string, "priority":
  string, "assignee_id": int or null}`: 201 with the new issue, status `open`.
  `title` is 1–200 characters and not blank; `priority` is `low`, `medium` or
  `high`, `medium` when absent; `assignee_id` may be absent or null (no
  assignee). Bad values: 400. An unknown project or assignee: 404. Issues of a
  project are numbered 1, 2, 3, … in the order they are created, with no number
  repeated or skipped, also when they are created at the same time.
- `GET /issues/{key}`: 200 with the issue. Unknown: 404.
- `PATCH /issues/{key}` with any of `title`, `status` (`open`, `in_progress`,
  `done`), `priority`, `assignee_id`: changes only the given fields;
  `"assignee_id": null` removes the assignee. Bad values: 400. Unknown issue or
  assignee: 404. Sets `updated_at` to the current time; 200 with the issue.
- `DELETE /issues/{key}`: 204. Unknown: 404. Numbers of deleted issues are not
  given again.
- `GET /projects/{key}/issues` with optional query parameters `status`,
  `assignee_id` (a user id, or `none` for issues without an assignee) and `q`
  (the title contains it, ignoring case): 200 with the matching issues sorted by
  number. A bad status or assignee_id: 400. Unknown project: 404.
- `GET /projects/{key}/summary`: 200 with `{"total": int, "open": int,
  "in_progress": int, "done": int, "assignees": [{"id": int, "name": string,
  "active": int}]}`: the number of issues of the project, by status, and the
  users who have issues in the project that are not done, with how many, sorted
  by that number (highest first), then by id. Unknown project: 404.

Error responses use the status codes above; the body is a short message in any format.
