# URL shortener

Write an HTTP JSON API server. It listens on port 8080 and keeps data in memory.

A link is `{"code": string, "url": string, "clicks": int}`.

- `POST /links` with body `{"url": string, "code": string}` (`code` is optional)
  - `url` must start with `http://` or `https://`, otherwise 400.
  - A given `code` must be 3–32 characters, each a letter, digit, `-` or `_`,
    otherwise 400. If a link with this code exists, 409.
  - Without `code`, generate a random unique 7-character code of letters and digits.
  - Answer 201 with the new link (`clicks` is 0).
- `GET /{code}` redirects: status 302 with header `Location: <url>`, and the
  link's `clicks` grows by 1. Unknown code: 404.
- `GET /links/{code}`: 200 with the link, or 404.
- `GET /links`: 200 with all links, most clicks first; equal clicks by code (A→Z).
- `DELETE /links/{code}`: 204, or 404.

Error responses use the status codes above; the body is a short message in any format.
