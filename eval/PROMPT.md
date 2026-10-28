# Prompt for one attempt

The same messages go to the model for every language; only `{LANGUAGE}`, `{FILE}`,
`{RULES}` and the task change. `eval/blind.py` builds exactly these messages and
runs the conversation; this file is its description.

The system prompt is `{RULES}`. It is the same for every task of a language, so
a model API can cache it, but only above the provider's per-model minimum for a
cached prefix (1024 to 4096 tokens at the time of writing): the Khrip core
alone (about 3000 tokens) falls below it on some models, and the one-line rules
of the other languages always do. In an agent session the core sits inside a
larger cached prefix (tools, instructions), so it is cached there. The cost
comes from the provider's usage of every call, not from this assumption
(`eval/blind.py`). The first user message is:

---

You are writing a small HTTP API in {LANGUAGE}.

Write the whole program as one file: `{FILE}`. Answer with the file only, in one
code block. Do not explain.

The task:

{TASK}

---

`{LANGUAGE}`, `{FILE}`, `{RULES}`:

| Language | File | Rules |
|---|---|---|
| Khrip | `main.kh` | the Khrip skill: the line below, then the whole of `skill/khrip/SKILL.md` |
| Go | `main.go` | Go 1.24, standard library only (`net/http` with method patterns). |
| C# | `Program.cs` | .NET 10 minimal API, no extra packages; the project file is given. |
| Python | `main.py` | Python 3.12, FastAPI and Pydantic 2; the app object is `app` (run by uvicorn). |

The line before the skill core:

> You write Khrip with the skill below: its core, SKILL.md, follows. Its chapters
> are not included. To read one, answer with the single line `READ <file>` (for
> example `READ postgresql.md`) and nothing else; the file comes in the next
> message. Read a chapter only when the task needs it.

A `READ <file>` answer is not an attempt, also with several such lines or inside
a code block: the next user message is the text of the chapters asked for (and
the list of chapters, for a name that is not one). An attempt that the checks
do not finish in 15 minutes fails. The
model reads chapters only by asking; nothing else of the repository is given.

Tasks with a database (`ledger`, `shop`, `tracker`; the task directory has a
`db` file) keep their data in PostgreSQL, so the other languages get the usual
driver:

| Language | Rules for tasks with a database |
|---|---|
| Khrip | the same skill (the model reads `postgresql.md` when it needs it) |
| Go | Go 1.25, standard library and `github.com/jackc/pgx/v5` (`pgxpool`); the `go.mod` is given. |
| C# | .NET 10 minimal API with Npgsql and Dapper; the project file is given. |
| Python | Python 3.12, FastAPI, Pydantic 2 and asyncpg; the app object is `app` (run by uvicorn). |

"Given" project files are copied from `eval/solutions/<task>/<language>/` next to
the model's file.

After a failed attempt, the model gets a second message and answers with the
whole file again:

---

Your program does not pass yet. {OUTPUT}

Fix it. Answer with the whole file only.

---

`{OUTPUT}` is either the compiler output and what the server printed when it
did not build or start ("It does not build or start: ..."), or the lines
`FAIL ...` from `eval/run.sh` ("The checks failed: ..."). Paths in compiler
output are relative to the attempt (`main.kh:3:5`). At most 5 attempts.

Before the skill (v0.13), `{RULES}` for Khrip was the whole of `docs/KHRIP.md`,
inside the first user message.
