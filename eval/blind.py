#!/usr/bin/env python3
"""Слепая проверка по eval/PROMPT.md: одна задача, один язык, одна модель.

    eval/blind.py run TASK LANG DIR --model-cmd CMD --prices JSON [--model NAME]
    eval/blind.py start TASK LANG DIR --prices JSON [--model NAME]
    eval/blind.py reply DIR FILE [--usage JSON]        # ответ модели → следующее сообщение
    eval/blind.py tokens DIR                            # токены и стоимость → DIR/result.json
    eval/blind.py summary DIR...                        # таблицы по result.json

LANG — khrip, go, csharp, python. CMD получает на stdin JSON
{"system": "...", "messages": [{"role": "user" | "assistant", "content": "..."}]}
и печатает JSON {"text": "ответ модели", "usage": {"input": N, "cache_write": N,
"cache_write_1h": N, "cache_read": N, "output": N, "reasoning": N}} — счёт
поставщика за этот вызов (адаптер поставщика пишет тот, кто запускает
проверку). Поля usage не пересекаются: input — входные токены без кэша,
cache_write — записанные в кэш на короткий срок (5 минут), cache_write_1h — на
час, cache_read — прочитанные из кэша, output — выходные без рассуждений,
reasoning — рассуждения (их поставщик берёт как выходные). Например, у
Anthropic: input_tokens, cache_creation.ephemeral_5m_input_tokens,
cache_creation.ephemeral_1h_input_tokens, cache_read_input_tokens,
output_tokens (с рассуждениями, reasoning — 0); у OpenAI: prompt_tokens −
cached_tokens, 0, 0, cached_tokens, completion_tokens − reasoning_tokens,
reasoning_tokens.

Цены (--prices, обязательно) — относительно выходного токена той модели, что
проверяется, со страницы цен поставщика на день прогона, например
'{"input": 0.2, "cache_write": 0.25, "cache_write_1h": 0.4, "cache_read": 0.02,
"output": 1, "reasoning": 1}'. Цены по умолчанию нет: у моделей одного
поставщика они разные (чтение из кэша — 0,1 цены входа, а вход — от 1/4 до 1/8
цены выхода).

Протокол (eval/PROMPT.md): system — правила языка (у Khrip — ядро скилла
skill/khrip/SKILL.md и строка о главах), первое сообщение — задача. Ответ —
либо строки «READ <глава>» (одна или несколько, можно в блоке кода; главы
пришлёт следующее сообщение; не попытка), либо файл в блоке кода: он
проверяется eval/run.sh, и при неудаче модель получает вывод компилятора или
строки FAIL. Не больше 5 попыток; проверка дольше 15 минут — неудачная попытка.

Стоимость — в выходных токенах: каждый вызов модели (и READ, и с повторно
отправленной историей) по usage поставщика × --prices. Вторая, справочная
цифра — токены o200k текстов (eval/tokens/count.mjs --raw): каждый вызов — вся
история; с кэшем новое (прошлый ответ и новое сообщение) пишется в кэш (0,25),
прежнее, и system тоже, читается из него (0,02); system записывает в кэш только
первый прогон языка в пачке (summary добавляет ему разницу, 0,23 × system);
без кэша вход — 0,2.

Состояние — DIR/state.json, все сообщения — DIR/messages/, попытки —
DIR/attempt-N/.
"""
import argparse
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKILL = os.path.join(ROOT, 'skill', 'khrip')
MAX_ATTEMPTS = 5
CHECK_TIMEOUT = 900
USAGE = ('input', 'cache_write', 'cache_write_1h', 'cache_read', 'output', 'reasoning')
# Справочная цифра по o200k: вес входа с кэшем (прочитано, записано) и без
O200K_CACHED = (0.02, 0.25)
O200K_UNCACHED = 0.2

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

READ_LINE = re.compile(r'^\s*`?READ\s+`?([A-Za-z0-9_.-]+)`?\s*$')
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


def prices_of(prices):
    """Цены относительно выходного токена: JSON или файл с ним; все поля USAGE."""
    if not prices:
        raise SystemExit('--prices is required: the prices of the model under test relative to an output token, from its vendor\'s price page, e.g. \'{"input": 0.2, "cache_write": 0.25, "cache_write_1h": 0.4, "cache_read": 0.02, "output": 1, "reasoning": 1}\'')
    p = json.loads(open(prices, encoding='utf-8').read() if os.path.isfile(prices) else prices)
    missing = [k for k in USAGE if not isinstance(p.get(k), (int, float))]
    if missing:
        raise SystemExit(f'prices need numbers for {", ".join(missing)}')
    return {k: p[k] for k in USAGE}


def start(task, lang, d, model, prices):
    if lang not in LANGS:
        raise SystemExit(f'unknown language {lang}: {", ".join(LANGS)}')
    if os.path.exists(os.path.join(d, 'state.json')):
        raise SystemExit(f'{d} already holds a run')
    os.makedirs(os.path.join(d, 'messages'), exist_ok=True)
    db = os.path.exists(os.path.join(ROOT, 'eval', 'tasks', task, 'db'))
    st = {'task': task, 'lang': lang, 'model': model, 'db': db, 'attempts': 0,
          'passed': False, 'done': False, 'chapters': [], 'messages': [], 'calls': [],
          'prices': prices_of(prices), 'started': time.time()}
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
    # своя группа процессов: по тайм-ауту останавливаются и серверы run.sh
    p = subprocess.Popen([os.path.join(ROOT, 'eval', 'run.sh'), st['task'], st['lang'], adir],
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        raw, _ = p.communicate(timeout=CHECK_TIMEOUT)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        raw, _ = p.communicate()
        with open(os.path.join(adir, 'check.log'), 'w', encoding='utf-8') as f:
            f.write(raw.decode('utf-8', 'replace') + f'\n(stopped after {CHECK_TIMEOUT} s)\n')
        return False, f'The checks did not finish in {CHECK_TIMEOUT // 60} minutes.'
    # пути попытки модели ни к чему: main.kh:3:5, а не /tmp/.../attempt-1/main.kh:3:5
    out = raw.decode('utf-8', 'replace').replace(os.path.abspath(adir) + os.sep, '')
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


def read_request(text):
    """Имена глав, если ответ — только строки READ (можно в блоке кода), иначе None."""
    names = []
    for line in text.strip().splitlines():
        if not line.strip() or line.strip().startswith('```'):
            continue
        m = READ_LINE.match(line)
        if not m:
            return None
        names.append(m.group(1))
    return names or None


def check_usage(usage):
    if usage is None:
        return None
    bad = list(USAGE) if not isinstance(usage, dict) else [k for k in USAGE if not isinstance(usage.get(k, 0), int) or usage.get(k, 0) < 0]
    if bad:
        raise SystemExit(f'usage needs non-negative integers for {", ".join(USAGE)}: {usage!r}')
    return {k: usage.get(k, 0) for k in USAGE}


def reply(d, text, usage=None):
    """Ответ модели (и счёт за вызов) → следующее сообщение (путь) или итог: PASS, FAIL."""
    st = load(d)
    if st['done']:
        raise SystemExit(f'{d}: the run is over')
    # вызов видел system и все сообщения до него; его ответ — следующее сообщение
    st.setdefault('calls', []).append({'sent': len(st['messages']), 'usage': check_usage(usage)})
    names = read_request(text)
    if names:
        add(d, st, 'assistant', 'read', text)
        have = [n for n in names if n in chapters()]
        parts = []
        for name in have:
            st['chapters'].append(name)
            with open(os.path.join(SKILL, name), encoding='utf-8') as f:
                parts.append(f.read())
        unknown = [n for n in names if n not in chapters()]
        if unknown:
            parts.append(f'There is no chapter {", ".join(unknown)}. Chapters: {", ".join(chapters())}.\n')
        path = add(d, st, 'user', 'chapter' if have else 'feedback', '\n'.join(parts))
        save(d, st)
        return path
    blocks = FENCE.findall(text)
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
    calls = st.get('calls', [])
    part = lambda kind: sum(t for m, t in zip(ms, per) if m['kind'] == kind)
    # каждый вызов: вход — system и вся история до него, выход — его ответ;
    # новое во входе (ещё не в кэше) — всё после входа прошлого вызова; system
    # уже в кэше (его записал первый прогон языка в пачке — это добавляет
    # summary: system_first_write)
    cached = uncached = 0.0
    prev = 0
    per_call = []
    for i, c in enumerate(calls):
        sent = c['sent']
        inp = s + sum(per[:sent])
        new = inp - (s + sum(per[:prev]))
        out = per[sent] if sent < len(per) else 0
        per_call.append({'input': inp, 'new_input': new, 'output': out})
        cached += O200K_CACHED[0] * (inp - new) + O200K_CACHED[1] * new + out
        uncached += O200K_UNCACHED * inp + out
        prev = sent
    usage = [c['usage'] for c in calls]
    have_usage = bool(usage) and all(u is not None for u in usage)
    total = {k: sum(u[k] for u in usage) for k in USAGE} if have_usage else None
    pr = st['prices']
    res = {
        'task': st['task'], 'lang': st['lang'], 'model': st['model'],
        'passed': st['passed'], 'attempts': st['attempts'], 'calls': len(calls),
        'chapters_read': st['chapters'], 'started': st.get('started', 0),
        'prices': pr,
        'usage': total,
        # главная цифра: счёт поставщика за все вызовы в выходных токенах
        'cost': round(sum(total[k] * pr[k] for k in USAGE), 1) if have_usage else None,
        'o200k': {
            'system': s, 'task': part('task'), 'chapters': part('chapter'),
            'answers': part('answer') + part('read'), 'feedback': part('feedback'),
            'per_call': per_call,
            'cost_cached': round(cached, 1), 'cost_uncached': round(uncached, 1),
            'system_first_write': round((O200K_CACHED[1] - O200K_CACHED[0]) * s, 1),
        },
    }
    with open(os.path.join(d, 'result.json'), 'w', encoding='utf-8') as f:
        json.dump(res, f, ensure_ascii=False, indent=1)
    return res


def summary(dirs):
    """По задаче и языку — все прогоны (решённые или нет) на число решённых;
    итог — только по задачам, которые решил каждый язык. Прогоны одной модели
    должны быть посчитаны по одним ценам."""
    rows = []
    for top in dirs:
        for root, _, files in os.walk(top):
            if 'result.json' in files:
                with open(os.path.join(root, 'result.json'), encoding='utf-8') as f:
                    rows.append(json.load(f))
    prices = {}
    for r in rows:
        key = json.dumps(r.get('prices'), sort_keys=True)
        prices.setdefault(r['model'], set()).add(key)
    mixed = {m: ps for m, ps in prices.items() if len(ps) > 1}
    if mixed:
        raise SystemExit('runs of one model were priced differently: ' + '; '.join(f'{m}: {" / ".join(sorted(ps))}' for m, ps in mixed.items()))
    # system в кэш записывает первый прогон языка в пачке
    first = {}
    for r in rows:
        k = (r['model'], r['lang'])
        if k not in first or r.get('started', 0) < first[k].get('started', 0):
            first[k] = r
    runs = {}
    for r in rows:
        runs.setdefault((r['model'], r['task'], r['lang']), []).append(r)
    keys = ('cost', 'cached', 'uncached')
    val = {
        'cost': lambda r: r['cost'],
        'cached': lambda r: r['o200k']['cost_cached'] + (r['o200k'].get('system_first_write', 0) if first[(r['model'], r['lang'])] is r else 0),
        'uncached': lambda r: r['o200k']['cost_uncached'],
    }
    f = lambda x: '—' if x is None else f'{x:.0f}'
    per = {}
    print('| model | task | language | solved | attempts, all runs | cost per solved (usage) | o200k, cached | o200k, uncached |')
    print('|---|---|---|---:|---:|---:|---:|---:|')
    for (model, task, lang), rs in sorted(runs.items()):
        ok = sum(1 for r in rs if r['passed'])
        cell = {}
        for k in keys:
            vs = [val[k](r) for r in rs]
            cell[k] = sum(vs) / ok if ok and all(v is not None for v in vs) else None
        per[(model, task, lang)] = (ok, cell)
        print(f'| {model} | {task} | {lang} | {ok}/{len(rs)} | {sum(r["attempts"] for r in rs)} | '
              f'{f(cell["cost"])} | {f(cell["cached"])} | {f(cell["uncached"])} |')
    print()
    print('Headline: tasks that every language solved; "solved" counts all runs of all tasks.')
    print()
    print('| model | language | solved | tasks | cost per solved task (usage) | × Khrip | o200k, cached | o200k, uncached |')
    print('|---|---|---:|---:|---:|---:|---:|---:|')
    for model in sorted({m for m, _, _ in per}):
        langs = sorted({l for m, _, l in per if m == model})
        tasks = sorted({t for m, t, _ in per if m == model})
        common = [t for t in tasks if all(per.get((model, t, l), (0, None))[0] > 0 for l in langs)]
        tot = {}
        for l in langs:
            tot[l] = {}
            for k in keys:
                vs = [per[(model, t, l)][1][k] for t in common]
                tot[l][k] = sum(vs) if common and all(v is not None for v in vs) else None
        base = tot.get('khrip', {}).get('cost')
        for l in langs:
            rs = [r for (m, _, rl), group in runs.items() if m == model and rl == l for r in group]
            solved = f'{sum(1 for r in rs if r["passed"])}/{len(rs)}'
            c = tot[l]['cost']
            ratio = f'×{c / base:.2f}' if c is not None and base else '—'
            print(f'| {model} | {l} | {solved} | {len(common)} | {f(c)} | {ratio} | {f(tot[l]["cached"])} | {f(tot[l]["uncached"])} |')


def run(task, lang, d, cmd, model, prices):
    start(task, lang, d, model, prices)
    while True:
        st = load(d)
        with open(os.path.join(d, 'system.txt'), encoding='utf-8') as f:
            request = {'system': f.read(),
                       'messages': [{'role': m['role'], 'content': text_of(d, m)} for m in st['messages']]}
        if len(st.get('calls', [])) >= MAX_ATTEMPTS + len(chapters()) + 2:
            st['done'] = True
            save(d, st)
            break
        p = subprocess.run(cmd, shell=True, input=json.dumps(request).encode(), stdout=subprocess.PIPE, check=True)
        try:
            answer = json.loads(p.stdout.decode('utf-8', 'replace'))
            text, usage = answer['text'], answer.get('usage')
        except (ValueError, KeyError, TypeError):
            raise SystemExit('the adapter must print JSON {"text": "...", "usage": {...}}')
        if usage is None:
            raise SystemExit('the adapter printed no usage: the cost comes from the provider\'s usage')
        nxt = reply(d, text, usage)
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
        p.add_argument('--prices', required=True, help='prices relative to an output token (JSON or a file): ' + ', '.join(USAGE))
        if name == 'run':
            p.add_argument('--model-cmd', required=True)
    p = sub.add_parser('reply')
    p.add_argument('dir')
    p.add_argument('file')
    p.add_argument('--usage', help='the provider usage of this call: JSON or a file with it')
    p = sub.add_parser('tokens')
    p.add_argument('dir')
    p = sub.add_parser('summary')
    p.add_argument('dirs', nargs='+')
    a = ap.parse_args()
    if a.cmd == 'run':
        run(a.task, a.lang, a.dir, a.model_cmd, a.model, a.prices)
    elif a.cmd == 'start':
        for path in start(a.task, a.lang, a.dir, a.model, a.prices):
            print(path)
    elif a.cmd == 'reply':
        usage = None
        if a.usage:
            usage = json.loads(open(a.usage, encoding='utf-8').read() if os.path.isfile(a.usage) else a.usage)
        with open(a.file, encoding='utf-8') if a.file != '-' else sys.stdin as f:
            print(reply(a.dir, f.read(), usage))
    elif a.cmd == 'tokens':
        print(json.dumps(tokens(a.dir), ensure_ascii=False))
    else:
        summary(a.dirs)


if __name__ == '__main__':
    main()
