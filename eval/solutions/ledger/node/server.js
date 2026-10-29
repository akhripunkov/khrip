import Fastify from 'fastify'
import pg from 'pg'

// bigint columns as numbers, times as 2026-10-21T19:37:54Z
pg.types.setTypeParser(20, Number)
const parseTime = pg.types.getTypeParser(1184)
pg.types.setTypeParser(1184, (s) => parseTime(s).toISOString().replace(/\.\d+Z$/, 'Z'))

const app = Fastify()
const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL })

// The statements run as one implicit transaction, so the advisory lock keeps
// servers starting at the same time from racing on the DDL.
await pool.query(`
  SELECT pg_advisory_xact_lock(4207);
  CREATE TABLE IF NOT EXISTS accounts (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    owner text NOT NULL,
    currency text NOT NULL,
    balance bigint NOT NULL DEFAULT 0 CHECK (balance >= 0)
  );
  CREATE TABLE IF NOT EXISTS transfers (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    from_id bigint NOT NULL REFERENCES accounts,
    to_id bigint NOT NULL REFERENCES accounts,
    amount bigint NOT NULL CHECK (amount > 0),
    created_at timestamptz NOT NULL DEFAULT date_trunc('second', now()),
    idempotency_key text UNIQUE
  );
  CREATE INDEX IF NOT EXISTS transfers_from_id ON transfers (from_id, id);
  CREATE INDEX IF NOT EXISTS transfers_to_id ON transfers (to_id, id);
`)

const TRANSFER = 'id, from_id AS "from", to_id AS "to", amount, created_at'
const CURRENCIES = ['USD', 'EUR', 'GBP']

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

const newAccount = {
  body: { type: 'object', required: ['owner', 'currency'], properties: { owner: { type: 'string' }, currency: { enum: CURRENCIES } } },
}
const amount = { body: { type: 'object', required: ['amount'], properties: { amount: { type: 'integer', minimum: 1 } } } }
const newTransfer = {
  body: {
    type: 'object',
    required: ['from', 'to', 'amount'],
    properties: { from: { type: 'integer' }, to: { type: 'integer' }, amount: { type: 'integer', minimum: 1 } },
  },
}
const page = {
  querystring: {
    type: 'object',
    properties: { limit: { type: 'integer', minimum: 1, maximum: 100, default: 20 }, before: { type: 'integer' } },
  },
}

async function account(sql, params) {
  const { rows } = await pool.query(sql, params)
  if (!rows.length) throw httpError(404, 'account not found')
  return rows[0]
}

app.post('/accounts', { schema: newAccount }, async (req, reply) => {
  const { owner, currency } = req.body
  if (!owner.trim()) return reply.code(400).send('owner is required')
  return reply.code(201).send(await account('INSERT INTO accounts (owner, currency) VALUES ($1, $2) RETURNING *', [owner, currency]))
})

app.get('/accounts/:id', async (req) => account('SELECT * FROM accounts WHERE id = $1', [Number(req.params.id) || 0]))

app.post('/accounts/:id/deposit', { schema: amount }, async (req) =>
  account('UPDATE accounts SET balance = balance + $2 WHERE id = $1 RETURNING *', [Number(req.params.id) || 0, req.body.amount]))

// Same-key requests are serialized by an advisory lock on the key; the two
// accounts are locked in id order, so crossing transfers cannot deadlock.
app.post('/transfers', { schema: newTransfer }, async (req, reply) => {
  const { from, to, amount } = req.body
  if (from === to) return reply.code(400).send('accounts must be different')
  const key = req.headers['idempotency-key']
  if (key !== undefined && (key === '' || [...key].length > 64)) return reply.code(400).send('Idempotency-Key must be 1-64 characters')
  const transfer = await transaction(async (db) => {
    if (key !== undefined) {
      await db.query('SELECT pg_advisory_xact_lock(hashtextextended($1, 0))', [key])
      const { rows: [done] } = await db.query(`SELECT ${TRANSFER} FROM transfers WHERE idempotency_key = $1`, [key])
      if (done) {
        if (done.from !== from || done.to !== to || done.amount !== amount) throw httpError(422, 'Idempotency-Key was used with a different request')
        return done
      }
    }
    const { rows } = await db.query('SELECT * FROM accounts WHERE id IN ($1, $2) ORDER BY id FOR UPDATE', [from, to])
    const source = rows.find((a) => a.id === from)
    const target = rows.find((a) => a.id === to)
    if (!source || !target) throw httpError(404, 'account not found')
    if (source.currency !== target.currency) throw httpError(422, 'accounts have different currencies')
    if (source.balance < amount) throw httpError(409, 'insufficient funds')
    await db.query('UPDATE accounts SET balance = balance - $2 WHERE id = $1', [from, amount])
    await db.query('UPDATE accounts SET balance = balance + $2 WHERE id = $1', [to, amount])
    const { rows: [t] } = await db.query(
      `INSERT INTO transfers (from_id, to_id, amount, idempotency_key) VALUES ($1, $2, $3, $4) RETURNING ${TRANSFER}`,
      [from, to, amount, key ?? null])
    return t
  })
  return reply.code(201).send(transfer)
})

app.get('/accounts/:id/transfers', { schema: page }, async (req) => {
  const id = Number(req.params.id) || 0
  const { limit, before = Number.MAX_SAFE_INTEGER } = req.query
  await account('SELECT id FROM accounts WHERE id = $1', [id])
  const { rows } = await pool.query(
    `SELECT ${TRANSFER} FROM transfers WHERE (from_id = $1 OR to_id = $1) AND id < $2 ORDER BY id DESC LIMIT $3`,
    [id, before, limit])
  return rows
})

app.get('/stats', async () => {
  const { rows: [s] } = await pool.query(`
    SELECT count(*) AS accounts, (SELECT count(*) FROM transfers) AS transfers,
      coalesce(sum(balance) FILTER (WHERE currency = 'USD'), 0)::bigint AS usd,
      coalesce(sum(balance) FILTER (WHERE currency = 'EUR'), 0)::bigint AS eur,
      coalesce(sum(balance) FILTER (WHERE currency = 'GBP'), 0)::bigint AS gbp
    FROM accounts`)
  return { accounts: s.accounts, transfers: s.transfers, balances: { USD: s.usd, EUR: s.eur, GBP: s.gbp } }
})

await app.listen({ port: Number(process.env.PORT ?? 8080), host: '0.0.0.0' })
