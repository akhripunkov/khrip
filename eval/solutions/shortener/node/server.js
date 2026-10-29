import Fastify from 'fastify'
import { randomInt } from 'node:crypto'

const app = Fastify()
const links = new Map()
const ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'

function randomCode() {
  let code = ''
  for (let i = 0; i < 7; i++) code += ALPHABET[randomInt(ALPHABET.length)]
  return code
}

const newLink = {
  body: {
    type: 'object',
    required: ['url'],
    properties: {
      url: { type: 'string', pattern: '^https?://' },
      code: { type: 'string', pattern: '^[A-Za-z0-9_-]{3,32}$' },
    },
  },
}

app.post('/links', { schema: newLink }, async (req, reply) => {
  let { url, code } = req.body
  if (code !== undefined && links.has(code)) return reply.code(409).send('code is taken')
  if (code === undefined) {
    do code = randomCode()
    while (links.has(code))
  }
  const link = { code, url, clicks: 0 }
  links.set(code, link)
  return reply.code(201).send(link)
})

app.get('/:code', async (req, reply) => {
  const link = links.get(req.params.code)
  if (!link) return reply.code(404).send('not found')
  link.clicks++
  return reply.redirect(link.url, 302)
})

app.get('/links', async () =>
  [...links.values()].sort((a, b) => b.clicks - a.clicks || (a.code < b.code ? -1 : a.code > b.code ? 1 : 0)))

app.get('/links/:code', async (req, reply) => {
  const link = links.get(req.params.code)
  return link ?? reply.code(404).send('not found')
})

app.delete('/links/:code', async (req, reply) => {
  if (!links.delete(req.params.code)) return reply.code(404).send('not found')
  return reply.code(204).send()
})

await app.listen({ port: Number(process.env.PORT ?? 8080), host: '0.0.0.0' })
