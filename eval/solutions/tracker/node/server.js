import Fastify from 'fastify'
import pg from 'pg'

// bigint columns as numbers, times as 2026-10-21T19:37:54Z
pg.types.setTypeParser(20, Number)
const parseTime = pg.types.getTypeParser(1184)
pg.types.setTypeParser(1184, (s) => parseTime(s).toISOString().replace(/\.\d+Z$/, 'Z'))

const app = Fastify()
const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL })

await pool.query(`
  SELECT pg_advisory_xact_lock(hashtext('tracker schema'));
  CREATE TABLE IF NOT EXISTS users (
    id bigserial PRIMARY KEY,
    email text NOT NULL UNIQUE,
    name text NOT NULL
  );
  CREATE TABLE IF NOT EXISTS projects (
    key text PRIMARY KEY,
    name text NOT NULL,
    owner_id bigint NOT NULL REFERENCES users,
    last_number int NOT NULL DEFAULT 0
  );
  CREATE TABLE IF NOT EXISTS issues (
    key text GENERATED ALWAYS AS (project || '-' || number) STORED UNIQUE,
    project text NOT NULL REFERENCES projects,
    number int NOT NULL,
    title text NOT NULL,
    status text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'in_progress', 'done')),
    priority text NOT NULL CHECK (priority IN ('low', 'medium', 'high')),
    assignee_id bigint REFERENCES users,
    created_at timestamptz NOT NULL DEFAULT date_trunc('second', now()),
    updated_at timestamptz NOT NULL DEFAULT date_trunc('second', now()),
    PRIMARY KEY (project, number)
  );
`)

const UNIQUE = '23505'
const FOREIGN_KEY = '23503'
const STATUSES = ['open', 'in_progress', 'done']
const PRIORITIES = ['low', 'medium', 'high']
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

// A foreign key error of a referenced user means an unknown user: 404.
const unknownUser = (what) => (err) => {
  throw err.code === FOREIGN_KEY ? httpError(404, `${what} not found`) : err
}

const title = { type: 'string', maxLength: 200, pattern: '\\S' }
const newUser = {
  body: {
    type: 'object',
    required: ['email', 'name'],
    properties: { email: { type: 'string', pattern: '^[^@\\s]+@[^@\\s]+$' }, name: { type: 'string', pattern: '\\S' } },
  },
}
const newProject = {
  body: {
    type: 'object',
    required: ['key', 'name', 'owner_id'],
    properties: { key: { type: 'string', pattern: '^[A-Z]{2,5}$' }, name: { type: 'string', pattern: '\\S' }, owner_id: { type: 'integer' } },
  },
}
const newIssue = {
  body: {
    type: 'object',
    required: ['title'],
    properties: { title, priority: { enum: PRIORITIES, default: 'medium' }, assignee_id: { type: ['integer', 'null'], default: null } },
  },
}
const patch = {
  body: {
    type: 'object',
    properties: { title, status: { enum: STATUSES }, priority: { enum: PRIORITIES }, assignee_id: { type: ['integer', 'null'] } },
  },
}
const filter = {
  querystring: {
    type: 'object',
    properties: { status: { enum: STATUSES }, assignee_id: { type: 'string', pattern: '^(none|\\d+)$' }, q: { type: 'string' } },
  },
}

app.post('/users', { schema: newUser }, async (req, reply) => {
  const { rows } = await pool.query('INSERT INTO users (email, name) VALUES ($1, $2) ON CONFLICT (email) DO NOTHING RETURNING *',
    [req.body.email.toLowerCase(), req.body.name])
  if (!rows.length) return reply.code(409).send('email exists')
  return reply.code(201).send(rows[0])
})

app.post('/projects', { schema: newProject }, async (req, reply) => {
  const { key, name, owner_id } = req.body
  try {
    await pool.query('INSERT INTO projects (key, name, owner_id) VALUES ($1, $2, $3)', [key, name, owner_id])
  } catch (err) {
    if (err.code === UNIQUE) return reply.code(409).send('project exists')
    unknownUser('owner')(err)
  }
  return reply.code(201).send({ key, name, owner_id })
})

// The project row lock taken by the counter update orders concurrent inserts, and a failed insert
// rolls the counter back, so numbers are neither repeated nor skipped.
app.post('/projects/:key/issues', { schema: newIssue }, async (req, reply) => {
  const { title, priority, assignee_id } = req.body
  const issue = await transaction(async (db) => {
    const { rows } = await db.query('UPDATE projects SET last_number = last_number + 1 WHERE key = $1 RETURNING last_number', [req.params.key])
    if (!rows.length) throw httpError(404, 'project not found')
    const { rows: [issue] } = await db.query(
      'INSERT INTO issues (project, number, title, priority, assignee_id) VALUES ($1, $2, $3, $4, $5) RETURNING *',
      [req.params.key, rows[0].last_number, title, priority, assignee_id]).catch(unknownUser('assignee'))
    return issue
  })
  return reply.code(201).send(issue)
})

app.get('/issues/:key', async (req, reply) => {
  const { rows } = await pool.query('SELECT * FROM issues WHERE key = $1', [req.params.key])
  return rows[0] ?? reply.code(404).send('issue not found')
})

app.patch('/issues/:key', { schema: patch }, async (req, reply) => {
  const { title, status, priority, assignee_id } = req.body
  const { rows } = await pool.query(
    `UPDATE issues SET title = coalesce($2, title), status = coalesce($3, status), priority = coalesce($4, priority),
       assignee_id = CASE WHEN $5 THEN $6::bigint ELSE assignee_id END,
       updated_at = date_trunc('second', now())
     WHERE key = $1
     RETURNING *`,
    [req.params.key, title, status, priority, assignee_id !== undefined, assignee_id]).catch(unknownUser('assignee'))
  return rows[0] ?? reply.code(404).send('issue not found')
})

app.delete('/issues/:key', async (req, reply) => {
  const { rowCount } = await pool.query('DELETE FROM issues WHERE key = $1', [req.params.key])
  return rowCount ? reply.code(204).send() : reply.code(404).send('issue not found')
})

app.get('/projects/:key/issues', { schema: filter }, async (req, reply) => {
  const { status, assignee_id, q } = req.query
  const filters = ['project = $1']
  const params = [req.params.key]
  if (status !== undefined) filters.push(`status = $${params.push(status)}`)
  if (assignee_id === 'none') filters.push('assignee_id IS NULL')
  else if (assignee_id !== undefined) filters.push(`assignee_id = $${params.push(assignee_id)}`)
  if (q !== undefined) filters.push(`strpos(lower(title), lower($${params.push(q)})) > 0`)
  const { rows: [project] } = await pool.query('SELECT 1 FROM projects WHERE key = $1', [req.params.key])
  if (!project) return reply.code(404).send('project not found')
  return (await pool.query(`SELECT * FROM issues WHERE ${filters.join(' AND ')} ORDER BY number`, params)).rows
})

app.get('/projects/:key/summary', async (req, reply) => {
  const { rows: [counts] } = await pool.query(
    `SELECT count(i.number) AS total,
       count(*) FILTER (WHERE i.status = 'open') AS open,
       count(*) FILTER (WHERE i.status = 'in_progress') AS in_progress,
       count(*) FILTER (WHERE i.status = 'done') AS done
     FROM projects p LEFT JOIN issues i ON i.project = p.key
     WHERE p.key = $1
     GROUP BY p.key`, [req.params.key])
  if (!counts) return reply.code(404).send('project not found')
  const { rows: assignees } = await pool.query(
    `SELECT u.id, u.name, count(*) AS active
     FROM issues i JOIN users u ON u.id = i.assignee_id
     WHERE i.project = $1 AND i.status <> 'done'
     GROUP BY u.id
     ORDER BY active DESC, u.id`, [req.params.key])
  return { ...counts, assignees }
})

await app.listen({ port: Number(process.env.PORT ?? 8080), host: '0.0.0.0' })
