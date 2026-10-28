#!/usr/bin/env python3
"""Слепая проверка по eval/PROMPT.md: одна задача, один язык, одна модель.

    eval/blind.py run TASK LANG DIR --model-cmd CMD [--model NAME]
    eval/blind.py start TASK LANG DIR [--model NAME]    # по шагам: первые сообщения
    eval/blind.py reply DIR FILE                        # ответ модели → следующее сообщение
    eval/blind.py tokens DIR                            # токены и стоимость → DIR/result.json
    eval/blind.py summary DIR...                        # таблица по result.json

LANG — khrip, go, csharp, python. CMD получает на stdin JSON
{"system": "...", "messages": [{"role": "user" | "assistant", "content": "..."}]}
и печатает ответ модели (адаптер поставщика пишет тот, кто запускает проверку).

Протокол (eval/PROMPT.md): system — правила языка (у Khrip — ядро скилла
skill/khrip/SKILL.md и строка о главах), первое сообщение — задача. Ответ —
либо строка «READ <глава>» (главу пришлёт следующее сообщение; не попытка),
либо файл в блоке кода: он проверяется eval/run.sh, и при неудаче модель
получает вывод компилятора или строки FAIL. Не больше 5 попыток.

Состояние — DIR/state.json, все сообщения — DIR/messages/, попытки —
DIR/attempt-N/. Токены o200k считает eval/tokens/count.mjs --raw (node и
gpt-tokenizer: eval/tokens/run.sh ставит его сам).
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKILL = os.path.join(ROOT, 'skill', 'khrip')
MAX_ATTEMPTS = 5
WEIGHTS = (0.02, 0.2)

LANGS = {
    'khrip': ('Khrip', 'main.kh'),
    'go': ('Go', 'main.go'),
    'csharp': ('C#', 'Program.cs'),
    'python': ('Python', 'main.py'),
}

# Правила других языков — как в eval/PROMPT.md (без базы, с базой).
RULES = {
    'go': ('Go 1.24, standard library only (`net/http` with method patterns).',
           'Go 1.25, standard library and `github.com/jackc/pgx/v5` (`pgxpool`); the `go.mod` is given.'),
    'csharp': ('.NET 10 minimal API, no extra packages; the project file is given.',
               '.NET 10 minimal API with Npgsql and Dapper; the project file is given.'),
    'python': ('Python 3.12, FastAPI and Pydantic 2; the app object is `app` (run by uvicorn).',
               'Python 3.12, FastAPI, Pydantic 2 and asyncpg; the app object is `app` (run by uvicorn).'),
}

KHRIP_INTRO = (
    'You write Khrip with the skill below: its core, SKILL.md, follows. Its chapters '
    'are not included. To read one, answer with the single line `READ <file>` (for '
    'example `READ postgresql.md`) and nothing else; the file comes in the next '
    'message. Read a chapter only when the task needs it.\n\n'
)

READ_LINE = re.compile(r'^\s*`?READ\s+([A-Za-z0-9_.-]+)`?\s*$')
FENCE = re.compile(r'^```[^\n]*\n(.*?)^```', re.S | re.M)


def chapters():
    return sorted(f for f in os.listdir(SKILL) if f.endswith('.md') and f != 'SKILL.md')


def system_text(lang, db):
    if lang == 'khrip':
        with open(os.path.join(SKILL, 'SKILL.md'), encoding='utf-8') as f:
            return KHRIP_INTRO + f.read()
    return RULES[lang][1 if db else 0]


def first_message(lang, task):
    name, file = LANGS[lang]
    with open(os.path.join(ROOT, 'eval', 'tasks', task, 'task.md'), encoding='utf-8') as f:
        text = f.read().strip()
    return (f'You are writing a small HTTP API in {name}.\n\n'
            f'Write the whole program as one file: `{file}`. Answer with the file only, '
            f'in one code block. Do not explain.\n\nThe task:\n\n{text}\n')


def feedback(output):
    return f'Your program does not pass yet. {output}\n\nFix it. Answer with the whole file only.\n'


def load(d):
    with open(os.path.join(d, 'state.json'), encoding='utf-8') as f:
        return json.load(f)


def save(d, st):
    with open(os.path.join(d, 'state.json'), 'w', encoding='utf-8') as f:
        json.dump(st, f, ensure_ascii=False, indent=1)


def add(d, st, role, kind, content):
    n = len(st['messages']) + 1
    path = os.path.join(d, 'messages', f'{n:02d}-{role}-{kind}.txt')
    with open(path, 'w', encoding='utf-8') as f:
        f.write(content)
    st['messages'].append({'role': role, 'kind': kind, 'file': os.path.relpath(path, d)})
    return path


def text_of(d, m):
    with open(os.path.join(d, m['file']), encoding='utf-8') as f:
        return f.read()


def start(task, lang, d, model):
    if lang not in LANGS:
        raise SystemExit(f'unknown language {lang}: {", ".join(LANGS)}')
    if os.path.exists(os.path.join(d, 'state.json')):
        raise SystemExit(f'{d} already holds a run')
    os.makedirs(os.path.join(d, 'messages'), exist_ok=True)
    db = os.path.exists(os.path.join(ROOT, 'eval', 'tasks', task, 'db'))
    st = {'task': task, 'lang': lang, 'model': model, 'db': db, 'attempts': 0,
          'passed': False, 'done': False, 'chapters': [], 'messages': []}
    with open(os.path.join(d, 'system.txt'), 'w', encoding='utf-8') as f:
        f.write(system_text(lang, db))
    path = add(d, st, 'user', 'task', first_message(lang, task))
    save(d, st)
    return os.path.join(d, 'system.txt'), path


def check(st, d, code):
    """Попытка: файл и данные проекта → eval/run.sh. → (прошло, вывод для модели)."""
    st['attempts'] += 1
    adir = os.path.join(d, f'attempt-{st["attempts"]}')
    os.makedirs(adir, exist_ok=True)
    ref = os.path.join(ROOT, 'eval', 'solutions', st['task'], st['lang'])
    file = LANGS[st['lang']][1]
    # данные проекта (go.mod, go.sum, App.csproj) — как в условии: «the project file is given»
    for f in os.listdir(ref) if os.path.isdir(ref) else []:
        if f != file and os.path.isfile(os.path.join(ref, f)):
            shutil.copy(os.path.join(ref, f), adir)
    with open(os.path.join(adir, file), 'w', encoding='utf-8') as f:
        f.write(code)
    p = subprocess.run([os.path.join(ROOT, 'eval', 'run.sh'), st['task'], st['lang'], adir],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=900)
    # пути попытки модели ни к чему: main.kh:3:5, а не /tmp/.../attempt-1/main.kh:3:5
    out = p.stdout.decode('utf-8', 'replace').replace(os.path.abspath(adir) + os.sep, '')
    with open(os.path.join(adir, 'check.log'), 'w', encoding='utf-8') as f:
        f.write(out)
    if p.returncode == 0:
        return True, ''
    fails = [l for l in out.splitlines() if l.startswith('FAIL ')]
    if fails:
        return False, 'The checks failed:\n\n' + '\n'.join(fails)
    # окружение, а не программа: проверку надо повторить, а не тратить попытку
    for infra in ('уже занят', 'нет PostgreSQL'):
        if infra in out:
            raise SystemExit(f'eval/run.sh: {out.strip()}')
    lines = [l for l in out.splitlines() if not l.startswith('== ')]
    text = '\n'.join(lines).strip()
    text = text.replace('вторая копия сервера не запустилась', 'The second copy of the server did not start.')
    text = text.replace('сервер не запустился после перезапуска', 'The server did not start after a restart.')
    text = text.replace('сервер не запустился', 'The server did not start.')
    return False, ('It does not build or start:\n\n' + text) if text else 'It does not build or start.'


def reply(d, text):
    """Ответ модели → следующее сообщение (путь) или итог: PASS, FAIL."""
    st = load(d)
    if st['done']:
        raise SystemExit(f'{d}: the run is over')
    blocks = FENCE.findall(text)
    lines = [l for l in text.strip().splitlines() if l.strip()]
    m = READ_LINE.match(lines[0]) if len(lines) == 1 else None
    if m and not blocks:
        add(d, st, 'assistant', 'read', text)
        name = m.group(1)
        if name in chapters():
            st['chapters'].append(name)
            with open(os.path.join(SKILL, name), encoding='utf-8') as f:
                path = add(d, st, 'user', 'chapter', f.read())
        else:
            path = add(d, st, 'user', 'feedback', f'There is no chapter {name}. Chapters: {", ".join(chapters())}.\n')
        save(d, st)
        return path
    add(d, st, 'assistant', 'answer', text)
    code = blocks[0] if blocks else text
    ok, out = check(st, d, code)
    if ok:
        st['passed'] = st['done'] = True
        save(d, st)
        return 'PASS'
    if st['attempts'] >= MAX_ATTEMPTS:
        st['done'] = True
        with open(os.path.join(d, 'last-output.txt'), 'w', encoding='utf-8') as f:
            f.write(out)
        save(d, st)
        return 'FAIL'
    path = add(d, st, 'user', 'feedback', feedback(out))
    save(d, st)
    return path


def count(texts):
    """Токены o200k каждого текста (eval/tokens/count.mjs --raw)."""
    here = os.path.join(ROOT, 'eval', 'tokens')
    if not os.path.isdir(os.path.join(here, 'node_modules', 'gpt-tokenizer')):
        subprocess.run(['npm', 'install', '--prefix', here, '--silent', '--no-audit', '--no-fund'], check=True)
    with tempfile.TemporaryDirectory() as t:
        files = []
        for i, s in enumerate(texts):
            files.append(os.path.join(t, f'{i}.txt'))
            with open(files[-1], 'w', encoding='utf-8') as f:
                f.write(s)
        out = subprocess.run(['node', os.path.join(here, 'count.mjs'), '--raw', *files],
                             stdout=subprocess.PIPE, check=True).stdout.decode()
    return [int(l.split('\t')[0]) for l in out.splitlines()]


def tokens(d):
    st = load(d)
    with open(os.path.join(d, 'system.txt'), encoding='utf-8') as f:
        system = f.read()
    ms = st['messages']
    n = count([system] + [text_of(d, m) for m in ms])
    s, per = n[0], n[1:]
    calls = sum(1 for m in ms if m['role'] == 'assistant')
    part = lambda kind: sum(t for m, t in zip(ms, per) if m['kind'] == kind)
    res = {
        'task': st['task'], 'lang': st['lang'], 'model': st['model'],
        'passed': st['passed'], 'attempts': st['attempts'], 'calls': calls,
        'chapters_read': st['chapters'],
        'tokens': {
            'system': s, 'task': part('task'), 'chapters': part('chapter'),
            'answers': part('answer') + part('read'), 'feedback': part('feedback'),
        },
    }
    t = res['tokens']
    # стоимость в выходных токенах: system в кэше при каждом вызове (вес w),
    # главы, ответы и сообщения о неудаче — полным весом; текст задачи у всех
    # языков один и не входит (он записан отдельно)
    for w in WEIGHTS:
        res[f'cost_w{w}'] = round(calls * w * s + t['chapters'] + t['answers'] + t['feedback'], 1)
    with open(os.path.join(d, 'result.json'), 'w', encoding='utf-8') as f:
        json.dump(res, f, ensure_ascii=False, indent=1)
    return res


def summary(dirs):
    rows = []
    for top in dirs:
        for root, _, files in os.walk(top):
            if 'result.json' in files:
                with open(os.path.join(root, 'result.json'), encoding='utf-8') as f:
                    rows.append(json.load(f))
    by = {}
    for r in rows:
        by.setdefault((r['model'], r['lang']), []).append(r)
    print('| model | language | solved | attempts (solved) | tokens per solved task, w = 0.02 | w = 0.2 |')
    print('|---|---|---:|---:|---:|---:|')
    for (model, lang), rs in sorted(by.items()):
        ok = [r for r in rs if r['passed']]
        avg = lambda k: f'{sum(r[k] for r in ok) / len(ok):.0f}' if ok else '—'
        att = f'{sum(r["attempts"] for r in ok) / len(ok):.1f}' if ok else '—'
        print(f'| {model} | {lang} | {len(ok)}/{len(rs)} | {att} | {avg("cost_w0.02")} | {avg("cost_w0.2")} |')


def run(task, lang, d, cmd, model):
    start(task, lang, d, model)
    while True:
        st = load(d)
        with open(os.path.join(d, 'system.txt'), encoding='utf-8') as f:
            request = {'system': f.read(),
                       'messages': [{'role': m['role'], 'content': text_of(d, m)} for m in st['messages']]}
        calls = sum(1 for m in st['messages'] if m['role'] == 'assistant')
        if calls >= MAX_ATTEMPTS + len(chapters()) + 2:
            st['done'] = True
            save(d, st)
            break
        p = subprocess.run(cmd, shell=True, input=json.dumps(request).encode(), stdout=subprocess.PIPE, check=True)
        nxt = reply(d, p.stdout.decode('utf-8', 'replace'))
        if nxt in ('PASS', 'FAIL'):
            break
    res = tokens(d)
    print(json.dumps(res, ensure_ascii=False))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    for name in ('run', 'start'):
        p = sub.add_parser(name)
        p.add_argument('task')
        p.add_argument('lang')
        p.add_argument('dir')
        p.add_argument('--model', default='model')
        if name == 'run':
            p.add_argument('--model-cmd', required=True)
    p = sub.add_parser('reply')
    p.add_argument('dir')
    p.add_argument('file')
    p = sub.add_parser('tokens')
    p.add_argument('dir')
    p = sub.add_parser('summary')
    p.add_argument('dirs', nargs='+')
    a = ap.parse_args()
    if a.cmd == 'run':
        run(a.task, a.lang, a.dir, a.model_cmd, a.model)
    elif a.cmd == 'start':
        for path in start(a.task, a.lang, a.dir, a.model):
            print(path)
    elif a.cmd == 'reply':
        with open(a.file, encoding='utf-8') if a.file != '-' else sys.stdin as f:
            print(reply(a.dir, f.read()))
    elif a.cmd == 'tokens':
        print(json.dumps(tokens(a.dir), ensure_ascii=False))
    else:
        summary(a.dirs)


if __name__ == '__main__':
    main()
