import Fastify from 'fastify'

const app = Fastify()
const products = []

const valid = (p) => typeof p.name === 'string' && p.name.trim() !== '' &&
  typeof p.category === 'string' && p.category.trim() !== '' && p.price >= 0

const input = {
  body: {
    type: 'object',
    additionalProperties: false,
    properties: {
      name: { type: 'string' },
      category: { type: 'string' },
      price: { type: 'number' },
      tags: { type: 'array', items: { type: 'string' } },
    },
  },
}
const query = {
  querystring: {
    type: 'object',
    properties: {
      q: { type: 'string' },
      category: { type: 'string' },
      tag: { type: 'string' },
      min_price: { type: 'number' },
      max_price: { type: 'number' },
      sort: { enum: ['price', '-price', 'name'] },
      page: { type: 'integer', minimum: 1, default: 1 },
      per_page: { type: 'integer', minimum: 1, maximum: 100, default: 10 },
    },
  },
}

app.post('/products', { schema: input }, async (req, reply) => {
  const { name, category, price = -1, tags = [] } = req.body
  const product = { id: products.length + 1, name, category, price, tags }
  if (!valid(product)) return reply.code(400).send('name and category are required, price must not be negative')
  products.push(product)
  return reply.code(201).send(product)
})

app.get('/products/:id', async (req, reply) => products[req.params.id - 1] ?? reply.code(404).send('not found'))

app.patch('/products/:id', { schema: input }, async (req, reply) => {
  const old = products[req.params.id - 1]
  if (!old) return reply.code(404).send('not found')
  const product = { ...old, ...req.body, id: old.id }
  if (!valid(product)) return reply.code(400).send('name and category are required, price must not be negative')
  products[old.id - 1] = product
  return product
})

const byName = (a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0)
const orders = { price: (a, b) => a.price - b.price, '-price': (a, b) => b.price - a.price, name: byName }

app.get('/products', { schema: query }, async (req) => {
  const { q, category, tag, min_price, max_price, sort, page, per_page } = req.query
  const needle = q?.toLowerCase()
  const items = products.filter((p) =>
    (needle === undefined || p.name.toLowerCase().includes(needle)) &&
    (category === undefined || p.category === category) &&
    (tag === undefined || p.tags.includes(tag)) &&
    (min_price === undefined || p.price >= min_price) &&
    (max_price === undefined || p.price <= max_price))
  if (sort) items.sort(orders[sort])
  return { items: items.slice((page - 1) * per_page, page * per_page), total: items.length, page, per_page }
})

app.get('/categories', async () => {
  const groups = new Map()
  for (const p of products) {
    const g = groups.get(p.category) ?? { name: p.category, count: 0, sum: 0 }
    g.count++
    g.sum += p.price
    groups.set(p.category, g)
  }
  return [...groups.values()].sort(byName).map((g) => ({ name: g.name, count: g.count, avg_price: Math.round((g.sum / g.count) * 100) / 100 }))
})

await app.listen({ port: Number(process.env.PORT ?? 8080), host: '0.0.0.0' })
