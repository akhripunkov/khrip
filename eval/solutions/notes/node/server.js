import Fastify from 'fastify'
import { pbkdf2, randomBytes, timingSafeEqual } from 'node:crypto'
import { promisify } from 'node:util'

const app = Fastify()
const hash = (password, salt) => promisify(pbkdf2)(password, salt, 100_000, 32, 'sha256')
const users = new Map()
const sessions = new Map()
const notes = new Map()
let lastNote = 0

const now = () => new Date().toISOString().replace(/\.\d+Z$/, 'Z')

const credentials = {
  body: {
    type: 'object',
    required: ['username', 'password'],
    properties: {
      username: { type: 'string', minLength: 3, maxLength: 32 },
      password: { type: 'string', minLength: 8 },
    },
  },
}
const login = {
  body: {
    type: 'object',
    required: ['username', 'password'],
    properties: { username: { type: 'string' }, password: { type: 'string' } },
  },
}
const newNote = {
  body: { type: 'object', required: ['title'], properties: { title: { type: 'string' }, text: { type: 'string', default: '' } } },
}

function currentUser(req) {
  const auth = req.headers.authorization
  return auth?.startsWith('Bearer ') ? sessions.get(auth.slice(7)) : undefined
}

app.post('/register', { schema: credentials }, async (req, reply) => {
  const { username, password } = req.body
  const salt = randomBytes(16)
  const hashed = await hash(password, salt)
  if (users.has(username)) return reply.code(409).send('username is taken')
  const user = { id: users.size + 1, username, salt, hash: hashed }
  users.set(username, user)
  return reply.code(201).send({ id: user.id, username })
})

app.post('/login', { schema: login }, async (req, reply) => {
  const { username, password } = req.body
  const user = users.get(username)
  if (!user || !timingSafeEqual(await hash(password, user.salt), user.hash)) return reply.code(401).send('invalid credentials')
  const token = randomBytes(24).toString('hex')
  sessions.set(token, username)
  return { token }
})

app.post('/notes', { schema: newNote }, async (req, reply) => {
  const owner = currentUser(req)
  if (!owner) return reply.code(401).send('unauthorized')
  if (!req.body.title.trim()) return reply.code(400).send('title is required')
  const note = { id: ++lastNote, title: req.body.title, text: req.body.text, created_at: now() }
  notes.set(note.id, { note, owner })
  return reply.code(201).send(note)
})

app.get('/notes', async (req, reply) => {
  const owner = currentUser(req)
  if (!owner) return reply.code(401).send('unauthorized')
  return [...notes.values()].filter((n) => n.owner === owner).map((n) => n.note)
})

app.get('/notes/:id', async (req, reply) => {
  const owner = currentUser(req)
  if (!owner) return reply.code(401).send('unauthorized')
  const entry = notes.get(Number(req.params.id))
  return entry?.owner === owner ? entry.note : reply.code(404).send('note not found')
})

app.delete('/notes/:id', async (req, reply) => {
  const owner = currentUser(req)
  if (!owner) return reply.code(401).send('unauthorized')
  const id = Number(req.params.id)
  if (notes.get(id)?.owner !== owner) return reply.code(404).send('note not found')
  notes.delete(id)
  return reply.code(204).send()
})

await app.listen({ port: Number(process.env.PORT ?? 8080), host: '0.0.0.0' })
