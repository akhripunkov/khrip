# Todo list

Write an HTTP JSON API server. It listens on port 8080 and keeps data in memory.

A todo is `{"id": int, "title": string, "type": string, "notes": string or null,
"due": string or null, "priority": int or null, "done": bool}`. Ids are 1, 2, 3, …

- `POST /todos` with body `{"title", "type", "notes", "due", "priority"}`: only
  `title` is required. `type` is `"task"` (the default) or `"note"`; `notes`,
  `due` and `priority` are null when missing; `done` starts false. 201 with the
  todo. 400 for a blank title, another `type`, a `due` that is not a real date
  `YYYY-MM-DD`, or a `priority` outside 1..5.
- `GET /todos/{id}`: 200 with the todo, or 404.
- `PATCH /todos/{id}` with a body holding any of `title`, `type`, `notes`, `due`,
  `priority`, `done`: changes only the fields in the body, keeps the others, and
  answers 200 with the todo. The same validation as on create: 400. Unknown
  todo: 404.
- `DELETE /todos/{id}`: 204, or 404.
- `GET /todos`: 200 with the list. Optional query parameters: `done` (`true` or
  `false`), `type`, and `sort`: `id` (the default) or `priority` (1 first, todos
  without a priority last, ties by id); any other `sort`: 400.

Error responses use the status codes above; the body is a short message in any format.
