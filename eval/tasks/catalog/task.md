# Product catalog

Write an HTTP JSON API server. It listens on port 8080 and keeps data in memory.

A product is `{"id": int, "name": string, "category": string, "price": number,
"tags": [string]}`. Ids are 1, 2, 3, …

- `POST /products` with body `{"name", "category", "price", "tags"}` (`tags` is
  optional, empty by default): 201 with the product. A blank name or category or a
  negative price: 400.
- `GET /products/{id}`: 200 with the product, or 404.
- `PATCH /products/{id}` with a body holding any of `name`, `category`, `price`,
  `tags`: changes only the given fields and answers 200 with the product. The same
  validation as on create: 400. Unknown product: 404.
- `GET /products` with optional query parameters:
  - `q`: the name contains this text, ignoring case;
  - `category`: exact match; `tag`: the product has this tag;
  - `min_price`, `max_price`: inclusive bounds;
  - `sort`: `price`, `-price` (descending) or `name`; by id when absent; any other
    value: 400. Ties keep id order.
  - `page` (default 1, at least 1) and `per_page` (default 10, from 1 to 100);
    out of range: 400.

  Answer 200 with `{"items": [...], "total": int, "page": int, "per_page": int}`,
  where `total` counts all matching products before paging.
- `GET /categories`: 200 with `[{"name": string, "count": int, "avg_price": number}]`
  sorted by name; `avg_price` is rounded to 2 decimals.

Error responses use the status codes above; the body is a short message in any format.
