"""Собирает docs/TUTORIAL.md из шаблона TUTORIAL.tpl.md.

    python3 docs/tutorial/build.py

{{file:путь}} — код файла, {{out:путь}} — вывод khc run, {{test:путь}} —
вывод khc test, {{tail:путь}} — часть файла после «// --- ответ ---».
Урок 7 работает с PostgreSQL: его тесты идут на базе из
KHRIP_TEST_DATABASE_URL (каждый — в своей временной схеме).
Вывод снимается с настоящих запусков, поэтому код в учебнике всегда
компилируется. Сессия curl (curl-session.txt) снята вручную с урока 4.
"""
import os
import re
import subprocess

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.dirname(os.path.dirname(here))
khc = os.path.join(root, "build", "khc")


def block(text, lang=""):
    return f"```{lang}\n{text.rstrip()}\n```"


def khc_run(*args):
    r = subprocess.run([khc, *args], capture_output=True, text=True, cwd=root)
    # строка о миграции (в stderr) — не часть вывода тестов
    err = "".join(l for l in r.stderr.splitlines(True) if not l.startswith("khrip: applied migration"))
    return (r.stdout + err).rstrip()


def tail(path):
    s = open(os.path.join(root, path)).read()
    return s[s.index("// --- ответ ---"):].replace("// --- ответ ---\n\n", "")


t = open(os.path.join(here, "TUTORIAL.tpl.md")).read()
t = re.sub(r"\{\{file:([^}]+)\}\}", lambda m: block(open(os.path.join(root, m.group(1))).read(), "khrip"), t)
t = re.sub(r"\{\{out:([^}]+)\}\}", lambda m: block(khc_run("run", m.group(1))), t)
t = re.sub(r"\{\{test:([^}]+)\}\}", lambda m: block(khc_run("test", m.group(1))), t)
t = re.sub(r"\{\{tail:([^}]+)\}\}", lambda m: block(tail(m.group(1)), "khrip"), t)
t = t.replace("CURL_SESSION", open(os.path.join(here, "curl-session.txt")).read().rstrip())
mistakes = os.path.join(here, "mistakes.kh.txt")
t = t.replace("SQL_MISTAKES_SOURCE", open(os.path.join(here, "db", "mistakes_sql.kh.txt")).read().rstrip())
sql_mistakes = os.path.join(here, "db", "mistakes_sql.kh.txt")
t = t.replace("SQL_MISTAKES_OUTPUT", khc_run("check", sql_mistakes).replace(sql_mistakes, "mistakes.kh"))
t = t.replace("MISTAKES_SOURCE", open(mistakes).read().rstrip())
out = khc_run("check", mistakes).replace(mistakes, "mistakes.kh")
t = t.replace("MISTAKES_OUTPUT", out)
open(os.path.join(root, "docs", "TUTORIAL.md"), "w").write(t)
print("docs/TUTORIAL.md:", len(t.splitlines()), "строк")
