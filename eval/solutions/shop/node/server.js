import Fastify from 'fastify'
import pg from 'pg'

// bigint columns as numbers, times as 2026-10-21T19:37:54Z
pg.types.setTypeParser(20, Number)
const parseTime = pg.types.getTypeParser(1184)
pg.types.setTypeParser(1184, (s) => parseTime(s).toISOString().replace(/\.\d+Z$/, 'Z'))

const app = Fastify()
const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL })

await pool.query(`
  SELECT pg_advisory_xact_lock(hashtext('shop schema'));
  CREATE TABLE IF NOT EXISTS categories (
    id bigserial PRIMARY KEY,
    name text NOT NULL
  );
  CREATE UNIQUE INDEX IF NOT EXISTS categories_name_key ON categories (lower(name));
  CREATE TABLE IF NOT EXISTS products (
    id bigserial PRIMARY KEY,
    name text NOT NULL,
    category_id bigint NOT NULL REFERENCES categories,
    price bigint NOT NULL CHECK (price > 0),
    stock bigint NOT NULL CHECK (stock >= 0),
    tags text[] NOT NULL DEFAULT '{}'
  );
  CREATE TABLE IF NOT EXISTS orders (
    id bigserial PRIMARY KEY,
    customer text NOT NULL,
    status text NOT NULL DEFAULT 'placed' CHECK (status IN ('placed', 'cancelled')),
    total bigint NOT NULL,
    created_at timestamptz NOT NULL DEFAULT date_trunc('second', now())
  );
  CREATE INDEX IF NOT EXISTS orders_customer ON orders (customer, created_at);
  CREATE TABLE IF NOT EXISTS order_lines (
    order_id bigint NOT NULL REFERENCES orders,
    position int NOT NULL,
    product_id bigint NOT NULL REFERENCES products,
    qty bigint NOT NULL CHECK (qty > 0),
    price bigint NOT NULL,
    PRIMARY KEY (order_id, position)
  );
`)

const httpError = (statusCode, message) => Object.assign(new Error(message), { statusCode })

async function transaction(fn) {
  const client = await pool.connect()
  try {
    await client.query('BEGIN')
    const result = await fn(client)
    await client.query('COMMIT')
    return result
  } catch (err) {
    await client.query('ROLLBACK')
    throw err
  } finally {
    client.release()
  }
}

const id = (req) => Number(req.params.id) || 0
const tagList = { type: 'array', maxItems: 5, items: { type: 'string', pattern: '^[a-z0-9]{1,20}$' } }
const product = {
  body: {
    type: 'object',
    required: ['name', 'category_id', 'price', 'stock'],
    properties: {
      name: { type: 'string', pattern: '\\S' },
      category_id: { type: 'integer' },
      price: { type: 'integer', minimum: 1 },
      stock: { type: 'integer', minimum: 0 },
      tags: tagList,
    },
  },
}
const patch = {
  body: {
    type: 'object',
    properties: {
      name: { type: 'string', pattern: '\\S' },
      price: { type: 'integer', minimum: 1 },
      stock: { type: 'integer', minimum: 0 },
      tags: tagList,
    },
  },
}
const search = {
  querystring: {
    type: 'object',
    properties: {
      category_id: { type: 'integer' },
      tag: { type: 'string' },
      q: { type: 'string' },
      min_price: { type: 'integer' },
      max_price: { type: 'integer' },
      in_stock: { type: 'boolean' },
      sort: { enum: ['price', '-price', 'name'] },
      page: { type: 'integer', minimum: 1, default: 1 },
      per_page: { type: 'integer', minimum: 1, maximum: 50, default: 10 },
    },
  },
}
const newOrder = {
  body: {
    type: 'object',
    required: ['customer', 'lines'],
    properties: {
      customer: { type: 'string', pattern: '^[^@\\s]+@[^@\\s]+$' },
      lines: {
        type: 'array',
        minItems: 1,
        items: {
          type: 'object',
          required: ['product_id', 'qty'],
          properties: { product_id: { type: 'integer' }, qty: { type: 'integer', minimum: 1 } },
        },
      },
    },
  },
}

app.post('/categories', async (req, reply) => {
  const name = typeof req.body?.name === 'string' ? req.body.name.trim() : ''
  if (name.length < 1 || [...name].length > 50) return reply.code(400).send('name must be 1-50 characters')
  const { rows } = await pool.query('INSERT INTO categories (name) VALUES ($1) ON CONFLICT (lower(name)) DO NOTHING RETURNING *', [name])
  if (!rows.length) return reply.code(409).send('category exists')
  return reply.code(201).send(rows[0])
})

app.get('/categories', async () => (await pool.query('SELECT * FROM categories ORDER BY name, id')).rows)

app.post('/products', { schema: product }, async (req, reply) => {
  const { name, category_id, price, stock, tags = [] } = req.body
  const { rows } = await pool.query(
    `INSERT INTO products (name, category_id, price, stock, tags)
     SELECT $1, id, $2, $3, $4 FROM categories WHERE id = $5
     RETURNING *`,
    [name, price, stock, [...new Set(tags)], category_id])
  if (!rows.length) return reply.code(404).send('category not found')
  return reply.code(201).send(rows[0])
})

app.get('/products/:id', async (req, reply) => {
  const { rows } = await pool.query('SELECT * FROM products WHERE id = $1', [id(req)])
  return rows[0] ?? reply.code(404).send('not found')
})

app.patch('/products/:id', { schema: patch }, async (req, reply) => {
  const { name, price, stock, tags } = req.body
  const { rows } = await pool.query(
    `UPDATE products SET name = coalesce($2, name), price = coalesce($3, price),
       stock = coalesce($4, stock), tags = coalesce($5, tags)
     WHERE id = $1
     RETURNING *`,
    [id(req), name, price, stock, tags && [...new Set(tags)]])
  return rows[0] ?? reply.code(404).send('not found')
})

const ORDER_BY = { price: 'price, id', '-price': 'price DESC, id', name: 'name, id' }

app.get('/products', { schema: search }, async (req) => {
  const { category_id, tag, q, min_price, max_price, in_stock, sort, page, per_page } = req.query
  const filters = ['true']
  const params = []
  const add = (sql, value) => {
    params.push(value)
    filters.push(sql.replace('?', `$${params.length}`))
  }
  if (category_id !== undefined) add('category_id = ?', category_id)
  if (tag !== undefined) add('? = ANY(tags)', tag)
  if (q !== undefined) add('strpos(lower(name), lower(?)) > 0', q)
  if (min_price !== undefined) add('price >= ?', min_price)
  if (max_price !== undefined) add('price <= ?', max_price)
  if (in_stock) filters.push('stock > 0')
  const where = filters.join(' AND ')
  const { rows: [{ count }] } = await pool.query(`SELECT count(*) FROM products WHERE ${where}`, params)
  const { rows } = await pool.query(
    `SELECT * FROM products WHERE ${where} ORDER BY ${ORDER_BY[sort] ?? 'id'} LIMIT ${per_page} OFFSET ${(page - 1) * per_page}`,
    params)
  return { items: rows, total: count }
})

async function withLines(db, orders) {
  const { rows } = await db.query(
    'SELECT order_id, product_id, qty, price FROM order_lines WHERE order_id = ANY($1) ORDER BY position',
    [orders.map((o) => o.id)])
  return orders.map((o) => ({
    ...o,
    lines: rows.filter((l) => l.order_id === o.id).map(({ product_id, qty, price }) => ({ product_id, qty, price })),
  }))
}

app.post('/orders', { schema: newOrder }, async (req, reply) => {
  const customer = req.body.customer.toLowerCase()
  const wanted = new Map()
  for (const { product_id, qty } of req.body.lines) wanted.set(product_id, (wanted.get(product_id) ?? 0) + qty)
  const ids = [...wanted.keys()]
  const order = await transaction(async (db) => {
    // Products are locked in id order, here and in cancel, so the two cannot deadlock.
    const { rows } = await db.query('SELECT id, price, stock FROM products WHERE id = ANY($1) ORDER BY id FOR UPDATE', [ids])
    const products = new Map(rows.map((p) => [p.id, p]))
    if (products.size < ids.length) throw httpError(404, 'unknown product')
    if (ids.some((id) => products.get(id).stock < wanted.get(id))) throw httpError(409, 'not enough stock')
    const lines = ids.map((id) => ({ product_id: id, qty: wanted.get(id), price: products.get(id).price }))
    const total = lines.reduce((s, l) => s + l.qty * l.price, 0)
    const { rows: [order] } = await db.query('INSERT INTO orders (customer, total) VALUES ($1, $2) RETURNING *', [customer, total])
    const qtys = lines.map((l) => l.qty)
    await db.query('UPDATE products p SET stock = p.stock - l.qty FROM unnest($1::bigint[], $2::bigint[]) AS l(id, qty) WHERE p.id = l.id', [ids, qtys])
    await db.query(
      `INSERT INTO order_lines (order_id, position, product_id, qty, price)
       SELECT $1, position, id, qty, price FROM unnest($2::bigint[], $3::bigint[], $4::bigint[]) WITH ORDINALITY AS l(id, qty, price, position)`,
      [order.id, ids, qtys, lines.map((l) => l.price)])
    return { ...order, lines }
  })
  return reply.code(201).send(order)
})

app.post('/orders/:id/cancel', async (req) =>
  transaction(async (db) => {
    const { rows: [order] } = await db.query('SELECT * FROM orders WHERE id = $1 FOR UPDATE', [id(req)])
    if (!order) throw httpError(404, 'order not found')
    if (order.status === 'cancelled') throw httpError(409, 'order is already cancelled')
    // Products are locked in id order, as in POST /orders, so the two cannot deadlock.
    await db.query('SELECT 1 FROM products WHERE id IN (SELECT product_id FROM order_lines WHERE order_id = $1) ORDER BY id FOR UPDATE', [order.id])
    await db.query('UPDATE products p SET stock = p.stock + l.qty FROM order_lines l WHERE l.order_id = $1 AND p.id = l.product_id', [order.id])
    await db.query("UPDATE orders SET status = 'cancelled' WHERE id = $1", [order.id])
    return (await withLines(db, [{ ...order, status: 'cancelled' }]))[0]
  }))

app.get('/customers/:email/orders', async (req) => {
  const { rows } = await pool.query('SELECT * FROM orders WHERE customer = $1 ORDER BY created_at DESC, id DESC', [req.params.email.toLowerCase()])
  return withLines(pool, rows)
})

app.get('/stats/categories', async () => {
  const { rows } = await pool.query(`
    SELECT c.name AS category, count(p.id) AS products,
           coalesce(sum(s.units), 0)::bigint AS units_sold, coalesce(sum(s.revenue), 0)::bigint AS revenue
    FROM categories c
    LEFT JOIN products p ON p.category_id = c.id
    LEFT JOIN (
      SELECT l.product_id, sum(l.qty) AS units, sum(l.qty * l.price) AS revenue
      FROM order_lines l JOIN orders o ON o.id = l.order_id
      WHERE o.status = 'placed'
      GROUP BY l.product_id
    ) s ON s.product_id = p.id
    GROUP BY c.id
    ORDER BY revenue DESC, c.name`)
  return rows
})

await app.listen({ port: Number(process.env.PORT ?? 8080), host: '0.0.0.0' })
