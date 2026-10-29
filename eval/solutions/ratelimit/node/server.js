import Fastify from 'fastify'

const app = Fastify()
const LIMIT = 5
const WINDOW_MS = 1000 * Number(process.env.WINDOW_SECONDS ?? 60)
const windows = new Map()

function active(key, now) {
  const w = windows.get(key)
  return w && now - w.start < WINDOW_MS ? w : undefined
}

const secondsLeft = (w, now) => Math.ceil((w.start + WINDOW_MS - now) / 1000)

app.decorateRequest('remaining', 0)

app.register(
  async (api) => {
    api.addHook('onRequest', async (req, reply) => {
      const key = req.headers['x-api-key']
      if (!key) return reply.code(401).send('missing X-API-Key')
      const now = Date.now()
      let w = active(key, now)
      if (!w) windows.set(key, (w = { start: now, used: 0 }))
      if (w.used >= LIMIT) return reply.code(429).header('Retry-After', secondsLeft(w, now)).send('too many requests')
      w.used++
      req.remaining = LIMIT - w.used
    })
    api.get('/ping', async (req) => ({ pong: true, remaining: req.remaining }))
    api.get('/time', async () => ({ time: new Date().toISOString().replace(/\.\d+Z$/, 'Z') }))
  },
  { prefix: '/api' },
)

app.get('/limits/:key', async (req) => {
  const now = Date.now()
  const w = active(req.params.key, now)
  const used = w ? w.used : 0
  return { key: req.params.key, used, remaining: LIMIT - used, reset_in: w ? secondsLeft(w, now) : 0 }
})

await app.listen({ port: Number(process.env.PORT ?? 8080), host: '0.0.0.0' })
