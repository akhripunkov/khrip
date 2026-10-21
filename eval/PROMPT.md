# Prompt for one attempt

The same text goes to the model for every language; only `{LANGUAGE}`, `{RULES}`
and the task change. `{RULES}` for Khrip is the whole of `docs/KHRIP.md`; for the
other languages it is one line (below). The model answers with one file.

---

You are writing a small HTTP API in {LANGUAGE}.

{RULES}

Write the whole program as one file: `{FILE}`. Answer with the file only, in one
code block. Do not explain.

The task:

{TASK}

---

`{LANGUAGE}`, `{FILE}`, `{RULES}`:

| Language | File | Rules |
|---|---|---|
| Khrip | `main.kh` | the text of `docs/KHRIP.md` |
| Go | `main.go` | Go 1.24, standard library only (`net/http` with method patterns). |
| C# | `Program.cs` | .NET 10 minimal API, no extra packages; the project file is given. |
| Python | `main.py` | Python 3.12, FastAPI and Pydantic 2; the app object is `app` (run by uvicorn). |

Tasks with a database (`ledger`, `shop`, `tracker`; the task directory has a
`db` file) keep their data in PostgreSQL, so the other languages get the usual
driver:

| Language | Rules for tasks with a database |
|---|---|
| Khrip | the text of `docs/KHRIP.md` |
| Go | Go 1.25, standard library and `github.com/jackc/pgx/v5` (`pgxpool`); the `go.mod` is given. |
| C# | .NET 10 minimal API with Npgsql and Dapper; the project file is given. |
| Python | Python 3.12, FastAPI, Pydantic 2 and asyncpg; the app object is `app` (run by uvicorn). |

After a failed attempt, the model gets a second message and answers with the
whole file again:

---

Your program does not pass yet. {OUTPUT}

Fix it. Answer with the whole file only.

---

`{OUTPUT}` is either the compiler output (when the program does not build) or the
lines `FAIL ...` from `eval/run.sh` (when it builds but checks fail).
