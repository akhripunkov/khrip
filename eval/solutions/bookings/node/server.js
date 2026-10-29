import Fastify from 'fastify'

const app = Fastify()
const rooms = []
const bookings = new Map()
let lastBooking = 0
const HOUR = 3600_000

// Milliseconds of a time like 2026-10-19T15:04:05Z, or NaN when it is not a real time in this form.
function parseTime(s) {
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(s)) return NaN
  const t = new Date(s)
  return !isNaN(t) && t.toISOString() === s.replace('Z', '.000Z') ? t.getTime() : NaN
}

const newRoom = {
  body: { type: 'object', required: ['name', 'capacity'], properties: { name: { type: 'string' }, capacity: { type: 'integer', minimum: 1 } } },
}
const newBooking = {
  body: {
    type: 'object',
    required: ['room_id', 'title', 'start', 'end'],
    properties: { room_id: { type: 'integer' }, title: { type: 'string' }, start: { type: 'string' }, end: { type: 'string' } },
  },
}

app.post('/rooms', { schema: newRoom }, async (req, reply) => {
  const { name, capacity } = req.body
  if (!name.trim()) return reply.code(400).send('name is required')
  const room = { id: rooms.length + 1, name, capacity }
  rooms.push(room)
  return reply.code(201).send(room)
})

app.post('/bookings', { schema: newBooking }, async (req, reply) => {
  const { room_id, title, start, end } = req.body
  const from = parseTime(start)
  const to = parseTime(end)
  if (isNaN(from) || isNaN(to) || to <= from || to - from > 8 * HOUR || !title.trim())
    return reply.code(400).send('need a title and valid start < end, at most 8 hours apart')
  if (!rooms[room_id - 1]) return reply.code(404).send('room not found')
  for (const b of bookings.values()) {
    if (b.room_id === room_id && b.from < to && from < b.to) return reply.code(409).send('the room is booked at that time')
  }
  const booking = { id: ++lastBooking, room_id, title, start, end }
  bookings.set(booking.id, { ...booking, from, to })
  return reply.code(201).send(booking)
})

app.get('/rooms/:id/bookings', async (req, reply) => {
  let from = -Infinity
  let to = Infinity
  const { date } = req.query
  if (date !== undefined) {
    from = /^\d{4}-\d{2}-\d{2}$/.test(date) ? parseTime(`${date}T00:00:00Z`) : NaN
    if (isNaN(from)) return reply.code(400).send('date must look like 2026-10-19')
    to = from + 24 * HOUR
  }
  const id = Number(req.params.id)
  if (!rooms[id - 1]) return reply.code(404).send('room not found')
  return [...bookings.values()]
    .filter((b) => b.room_id === id && b.from < to && from < b.to)
    .sort((a, b) => a.from - b.from)
    .map(({ from, to, ...b }) => b)
})

app.delete('/bookings/:id', async (req, reply) => {
  if (!bookings.delete(Number(req.params.id))) return reply.code(404).send('not found')
  return reply.code(204).send()
})

await app.listen({ port: Number(process.env.PORT ?? 8080), host: '0.0.0.0' })
