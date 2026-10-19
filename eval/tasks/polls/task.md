# Polls

Write an HTTP JSON API server. It listens on port 8080 and keeps data in memory.

A poll is `{"id": int, "question": string, "options": [{"text": string,
"votes": int}], "closed": bool}`. Ids are 1, 2, 3, …

- `POST /polls` with body `{"question": string, "options": [string]}`: 201 with the
  poll (all votes 0, not closed). The question is not blank and there are 2–10
  options, each not blank and all different; otherwise 400.
- `GET /polls/{id}`: 200 with the poll, or 404.
- `GET /polls` with an optional query parameter `open` (`true` or `false`): 200
  with the polls in id order, only open or only closed ones when `open` is given.
- `POST /polls/{id}/votes` with the header `X-Voter-Id` and body
  `{"option": int}` (the option's index, from 0): 200 with the poll.
  - No `X-Voter-Id` header: 401.
  - Unknown poll: 404. Closed poll: 403.
  - The index is out of range: 400.
  - This voter has already voted in this poll: 409.
- `POST /polls/{id}/close`: 200 with the poll, now closed (closing again is fine).
  Unknown poll: 404.
- `GET /polls/{id}/results`: 200 with
  `{"total": int, "results": [{"text": string, "votes": int, "percent": number}]}`,
  most votes first, equal votes in option order; `percent` is the share of all
  votes in percent rounded to 1 decimal (0 when there are no votes). Unknown
  poll: 404.

Error responses use the status codes above; the body is a short message in any format.
