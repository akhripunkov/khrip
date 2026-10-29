import Fastify from 'fastify'

const app = Fastify()
const polls = []
const voters = []

const newPoll = {
  body: {
    type: 'object',
    required: ['question', 'options'],
    properties: {
      question: { type: 'string' },
      options: { type: 'array', minItems: 2, maxItems: 10, uniqueItems: true, items: { type: 'string' } },
    },
  },
}
const vote = { body: { type: 'object', required: ['option'], properties: { option: { type: 'integer' } } } }
const filter = { querystring: { type: 'object', properties: { open: { type: 'boolean' } } } }

app.post('/polls', { schema: newPoll }, async (req, reply) => {
  const { question, options } = req.body
  if (!question.trim() || options.some((o) => !o.trim())) return reply.code(400).send('question and 2-10 different options are required')
  const poll = { id: polls.length + 1, question, options: options.map((text) => ({ text, votes: 0 })), closed: false }
  polls.push(poll)
  voters.push(new Set())
  return reply.code(201).send(poll)
})

app.get('/polls/:id', async (req, reply) => polls[req.params.id - 1] ?? reply.code(404).send('not found'))

app.get('/polls', { schema: filter }, async (req) => {
  const { open } = req.query
  return polls.filter((p) => open === undefined || p.closed !== open)
})

app.post('/polls/:id/votes', { schema: vote }, async (req, reply) => {
  const voter = req.headers['x-voter-id']
  if (!voter) return reply.code(401).send('X-Voter-Id is required')
  const poll = polls[req.params.id - 1]
  if (!poll) return reply.code(404).send('not found')
  if (poll.closed) return reply.code(403).send('poll is closed')
  const option = poll.options[req.body.option]
  if (!option) return reply.code(400).send('no such option')
  const seen = voters[poll.id - 1]
  if (seen.has(voter)) return reply.code(409).send('already voted')
  seen.add(voter)
  option.votes++
  return poll
})

app.post('/polls/:id/close', async (req, reply) => {
  const poll = polls[req.params.id - 1]
  if (!poll) return reply.code(404).send('not found')
  poll.closed = true
  return poll
})

app.get('/polls/:id/results', async (req, reply) => {
  const poll = polls[req.params.id - 1]
  if (!poll) return reply.code(404).send('not found')
  const total = poll.options.reduce((s, o) => s + o.votes, 0)
  const results = poll.options
    .map(({ text, votes }) => ({ text, votes, percent: total ? Math.round((votes * 1000) / total) / 10 : 0 }))
    .sort((a, b) => b.votes - a.votes)
  return { total, results }
})

await app.listen({ port: Number(process.env.PORT ?? 8080), host: '0.0.0.0' })
