import Fastify from 'fastify'

const app = Fastify()
const items = new Map()
const orders = []

const newItem = {
  body: {
    type: 'object',
    required: ['sku', 'name', 'stock'],
    properties: {
      sku: { type: 'string', pattern: '^[A-Z0-9-]{3,20}$' },
      name: { type: 'string' },
      stock: { type: 'integer', minimum: 0 },
    },
  },
}
const restock = { body: { type: 'object', required: ['amount'], properties: { amount: { type: 'integer' } } } }
const newOrder = {
  body: {
    type: 'object',
    required: ['lines'],
    properties: {
      lines: {
        type: 'array',
        minItems: 1,
        items: {
          type: 'object',
          required: ['sku', 'qty'],
          additionalProperties: false,
          properties: { sku: { type: 'string' }, qty: { type: 'integer', minimum: 1 } },
        },
      },
    },
  },
}
const status = { querystring: { type: 'object', properties: { status: { enum: ['placed', 'cancelled'] } } } }

app.post('/items', { schema: newItem }, async (req, reply) => {
  const { sku, name, stock } = req.body
  if (!name.trim()) return reply.code(400).send('name is required')
  if (items.has(sku)) return reply.code(409).send('sku exists')
  const item = { sku, name, stock }
  items.set(sku, item)
  return reply.code(201).send(item)
})

app.get('/items', async () => [...items.values()].sort((a, b) => (a.sku < b.sku ? -1 : a.sku > b.sku ? 1 : 0)))

app.post('/items/:sku/restock', { schema: restock }, async (req, reply) => {
  const item = items.get(req.params.sku)
  if (!item) return reply.code(404).send('not found')
  if (req.body.amount <= 0) return reply.code(400).send('amount must be positive')
  item.stock += req.body.amount
  return item
})

app.post('/orders', { schema: newOrder }, async (req, reply) => {
  const { lines } = req.body
  const need = new Map()
  for (const { sku, qty } of lines) need.set(sku, (need.get(sku) ?? 0) + qty)
  for (const [sku, qty] of need) {
    const item = items.get(sku)
    if (!item) return reply.code(404).send(`unknown sku ${sku}`)
    if (item.stock < qty) return reply.code(409).send(`not enough ${sku}`)
  }
  for (const [sku, qty] of need) items.get(sku).stock -= qty
  const order = { id: orders.length + 1, lines, status: 'placed', total_qty: lines.reduce((s, l) => s + l.qty, 0) }
  orders.push(order)
  return reply.code(201).send(order)
})

app.post('/orders/:id/cancel', async (req, reply) => {
  const order = orders[req.params.id - 1]
  if (!order) return reply.code(404).send('not found')
  if (order.status === 'cancelled') return reply.code(409).send('already cancelled')
  order.status = 'cancelled'
  for (const { sku, qty } of order.lines) items.get(sku).stock += qty
  return order
})

app.get('/orders', { schema: status }, async (req) => orders.filter((o) => !req.query.status || o.status === req.query.status))

await app.listen({ port: Number(process.env.PORT ?? 8080), host: '0.0.0.0' })
