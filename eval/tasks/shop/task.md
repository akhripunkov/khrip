# Shop

Write an HTTP JSON API server. It listens on the port from the `PORT`
environment variable (8080 when it is not set) and keeps all data in
PostgreSQL; the connection URL is in `DATABASE_URL`
(`postgres://user:password@host:port/database?sslmode=disable`). The database
starts empty: the server creates its tables when it starts and must also start
when they already exist. Several copies of the server run at the same time on
the same database, and the server is restarted between checks.

Prices are integer cents. A category is `{"id": int, "name": string}`. A product
is `{"id": int, "name": string, "category_id": int, "price": int, "stock": int,
"tags": [string]}`. An order is `{"id": int, "customer": string, "status":
string, "total": int, "created_at": string, "lines": [{"product_id": int, "qty":
int, "price": int}]}`, where `created_at` is an ISO 8601 UTC time such as
`2026-10-21T19:37:54Z`.

- `POST /categories` with body `{"name": string}`: 201 with the category. The
  name is trimmed and must be 1–50 characters; otherwise 400. A name equal to an
  existing one ignoring case: 409.
- `GET /categories`: 200 with all categories sorted by name.
- `POST /products` with body `{"name", "category_id", "price", "stock", "tags"}`:
  201 with the product. `name` is not blank, `price` > 0, `stock` ≥ 0; `tags` may
  be absent (no tags), has at most 5 tags, each 1–20 lower-case letters or
  digits; repeated tags are kept once, in the order of first appearance.
  Otherwise 400. An unknown category: 404.
- `GET /products/{id}`: 200 with the product. Unknown: 404.
- `PATCH /products/{id}` with any of `name`, `price`, `stock`, `tags`: changes
  only the given fields, with the same rules; 200 with the product. Unknown
  product: 404.
- `GET /products` with optional query parameters: `category_id`, `tag` (has
  this tag), `q` (the name contains it, ignoring case), `min_price`,
  `max_price`, `in_stock` (`true`: stock > 0), `sort` (`price`, `-price` for
  descending, or `name`; by default by id; ties by id), `page` (from 1, default
  1) and `per_page` (1–50, default 10). 200 with `{"items": [...], "total":
  int}`, where `total` counts all matching products. A bad value: 400.
- `POST /orders` with body `{"customer": string, "lines": [{"product_id": int,
  "qty": int}]}` takes the stock and answers 201 with the order: status
  `placed`, each line with the current price of its product, `total` = sum of
  qty × price. Lines with the same product are merged into the first of them.
  `customer` is an email: one `@` with something on both sides and no spaces; it
  is stored in lower case. A bad customer, no lines or a `qty` ≤ 0: 400. An
  unknown product: 404. Not enough stock for any line: 409, and nothing changes.
- `POST /orders/{id}/cancel`: returns the stock and answers 200 with the order,
  now `cancelled`. Already cancelled: 409. Unknown order: 404.
- `GET /customers/{email}/orders`: 200 with the orders of this customer (email
  ignoring case), newest first.
- `GET /stats/categories`: 200 with `[{"category": string, "products": int,
  "units_sold": int, "revenue": int}]` for every category: its number of
  products, and the units and money of its products in placed (not cancelled)
  orders. Sorted by revenue, highest first, then by name.

Error responses use the status codes above; the body is a short message in any format.
