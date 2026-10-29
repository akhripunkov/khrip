import Fastify from 'fastify'

const app = Fastify()
const accounts = new Map()
const transfers = []

const now = () => new Date().toISOString().replace(/\.\d+Z$/, 'Z')

const amount = {
  body: { type: 'object', required: ['amount'], properties: { amount: { type: 'integer' } } },
}
const newTransfer = {
  body: {
    type: 'object',
    required: ['from_id', 'to_id', 'amount'],
    properties: { from_id: { type: 'integer' }, to_id: { type: 'integer' }, amount: { type: 'integer' } },
  },
}

app.post('/accounts', async (req, reply) => {
  const owner = req.body?.owner
  if (typeof owner !== 'string' || !owner.trim()) return reply.code(400).send('owner is required')
  const account = { id: accounts.size + 1, owner, balance: 0 }
  accounts.set(account.id, account)
  return reply.code(201).send(account)
})

app.get('/accounts/:id', async (req, reply) => accounts.get(Number(req.params.id)) ?? reply.code(404).send('not found'))

app.post('/accounts/:id/deposit', { schema: amount }, async (req, reply) => {
  const account = accounts.get(Number(req.params.id))
  if (!account) return reply.code(404).send('not found')
  if (req.body.amount <= 0) return reply.code(400).send('amount must be positive')
  account.balance += req.body.amount
  return account
})

app.post('/transfers', { schema: newTransfer }, async (req, reply) => {
  const { from_id, to_id, amount } = req.body
  if (amount <= 0 || from_id === to_id) return reply.code(400).send('amount must be positive and accounts different')
  const from = accounts.get(from_id)
  const to = accounts.get(to_id)
  if (!from || !to) return reply.code(404).send('account not found')
  if (from.balance < amount) return reply.code(409).send('insufficient funds')
  from.balance -= amount
  to.balance += amount
  const transfer = { id: transfers.length + 1, from_id, to_id, amount, created_at: now() }
  transfers.push(transfer)
  return reply.code(201).send(transfer)
})

app.get('/accounts/:id/transfers', async (req, reply) => {
  const id = Number(req.params.id)
  if (!accounts.has(id)) return reply.code(404).send('not found')
  return transfers.filter((t) => t.from_id === id || t.to_id === id).reverse()
})

await app.listen({ port: Number(process.env.PORT ?? 8080), host: '0.0.0.0' })
