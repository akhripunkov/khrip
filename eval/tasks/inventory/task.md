# Inventory and orders

Write an HTTP JSON API server. It listens on port 8080 and keeps data in memory.
Many requests may arrive at the same time: stock must never go below 0 and no
update may be lost.

An item is `{"sku": string, "name": string, "stock": int}`.

- `POST /items` with body `{"sku", "name", "stock"}`: 201 with the item. `sku` is
  3–20 characters, each an upper-case letter, digit or `-`; `name` is not blank;
  `stock` ≥ 0; otherwise 400. An existing sku: 409.
- `GET /items`: 200 with all items sorted by sku.
- `POST /items/{sku}/restock` with body `{"amount": int}`: 200 with the item.
  `amount` ≤ 0: 400. Unknown sku: 404.
- `POST /orders` with body `{"lines": [{"sku": string, "qty": int}]}` takes the stock
  and answers 201 with the order
  `{"id": int, "lines": [...], "status": "placed", "total_qty": int}`. Ids are
  1, 2, 3, … No lines or a `qty` ≤ 0: 400. An unknown sku: 404. Not enough stock
  for any line (lines with the same sku add up): 409, and no stock changes.
- `POST /orders/{id}/cancel`: returns the stock and answers 200 with the order,
  now `"status": "cancelled"`. Already cancelled: 409. Unknown order: 404.
- `GET /orders` with an optional query parameter `status` (`placed` or
  `cancelled`; any other value: 400): 200 with the matching orders in id order.

Error responses use the status codes above; the body is a short message in any format.
