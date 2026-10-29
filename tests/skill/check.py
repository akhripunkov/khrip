#!/usr/bin/env python3
# Скилл Khrip (skill/khrip/*.md) сходится с языком.
#
#   python3 -I tests/skill/check.py <khc> <временная папка>
#
# 1. Каждый блок кода скилла компилируется. Все блоки — «```khrip» с меткой:
#    без метки — целая программа (khc check; с блоками test и без баз — ещё и
#    khc test); «top» — объявления верхнего уровня, «body» — операторы в теле
#    маршрута: блок встаёт на место строки BLOCK в tests/skill/wrap/<метка>.kh
#    (у «top» без fn main, route и every добавляется пустой fn main). Блок без
#    метки khrip или с неизвестной меткой — ошибка, как и ограда ~~~ и ограда с
#    отступом: так ни один пример не уходит из проверки.
# 2. Примеры глав работают: tests/skill/run/<глава>.kh дописывается к первой
#    целой программе главы и идёт через khc test на настоящей базе
#    (PostgreSQL — SKILL_PG, его задаёт tests/run.sh, если база отвечает;
#    MongoDB — MONGODB_URI, база "app" примера заменяется на khrip_skill_test;
#    ClickHouse — CLICKHOUSE_URL с CLICKHOUSE_USER и CLICKHOUSE_PASSWORD); без
#    базы — строка SKIP.
# 3. Ключевые правила: tests/skill/rules/*.kh. «// in: файл» и «// rule: текст»
#    — текст правила, который должен быть в этом файле скилла (пробелы и
#    переводы строк сравниваются как один пробел); дальше одно из: файл .err —
#    программа не компилируется, и вывод khc check совпадает с ним целиком (с
#    местами: так и «правильная половина» правила не уходит из проверки);
#    «// compiles» — khc check без ошибок (запросы sql — по миграциям, без
#    базы); файл .out — вывод khc run совпадает с ним; блоки test — проходят
#    (khc test). Файл без всего этого — ошибка, а не пустой успех.
#
# 0. Формат скилла агента: SKILL.md начинается с frontmatter из name (= имя
#    папки: строчные буквы, цифры, дефис, до 64) и description (до 1024).
#
# Печатает FAIL и SKIP, последняя строка — «skill: <прошло> <провалено>».
import os
import re
import subprocess
import sys

khc, tmp = sys.argv[1], sys.argv[2]
skill = 'skill/khrip'
here = 'tests/skill'
passed = 0
failed = 0
db_words = re.compile(r'^\s*(migration|table|clickhouse)\b|\bsql\s*[`"]|\bch\s*[`"]|\bmongo_|\bMongo\b', re.M)


def fail(name, why):
    global failed
    failed += 1
    print(f'FAIL {name}: {why}')


def ok():
    global passed
    passed += 1


def run(args, env=None):
    e = dict(os.environ)
    if env:
        e.update(env)
    p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=e, timeout=600)
    return p.returncode, p.stdout.decode('utf-8', 'replace')


def wrap(label, block):
    text = open(f'{here}/wrap/{label}.kh', encoding='utf-8').read()
    if text.count('// BLOCK\n') != 1:
        raise SystemExit(f'{here}/wrap/{label}.kh: needs one line "// BLOCK"')
    text = text.replace('// BLOCK\n', block)
    if label == 'top' and not re.search(r'^(fn main\b|route |every )', block, re.M):
        text += 'fn main() {\n}\n'
    return text


def blocks(md):
    """(строка, метка, текст) каждого блока кода файла."""
    lines = open(f'{skill}/{md}', encoding='utf-8').read().split('\n')
    out = []
    i = 0
    while i < len(lines):
        if re.match(r'^\s*~~~', lines[i]) or re.match(r'^\s+```', lines[i]):
            fail(f'{skill}/{md}:{i + 1}', 'code fences are ``` at the start of a line (no ~~~, no indent): the block would not be checked')
            i += 1
            continue
        m = re.match(r'^```(.*)$', lines[i])
        if not m:
            i += 1
            continue
        j = i + 1
        while j < len(lines) and lines[j] != '```':
            j += 1
        if j == len(lines):
            fail(f'{skill}/{md}:{i + 1}', 'unclosed code block')
            break
        out.append((i + 1, m.group(1).strip(), '\n'.join(lines[i + 1:j]) + '\n'))
        i = j + 1
    return out


# 0. Frontmatter
head = re.match(r'---\nname: ([^\n]*)\ndescription: ([^\n]*)\n---\n', open(f'{skill}/SKILL.md', encoding='utf-8').read())
if not head:
    fail(f'{skill}/SKILL.md', 'must start with ---, name:, description:, ---')
elif head.group(1) != os.path.basename(skill) or not re.fullmatch(r'[a-z0-9-]{1,64}', head.group(1)):
    fail(f'{skill}/SKILL.md', f'name {head.group(1)!r} must be the folder name, lowercase letters, digits and -')
elif not 0 < len(head.group(2)) <= 1024 or ': ' in head.group(2):
    fail(f'{skill}/SKILL.md', 'description must be 1-1024 characters, a plain YAML scalar (no ": ")')
else:
    ok()

# 1. Блоки кода
first_program = {}
mds = sorted(f for f in os.listdir(skill) if f.endswith('.md'))
for md in mds:
    for line, info, text in blocks(md):
        name = f'{skill}/{md}:{line}'
        words = info.split()
        if not words or words[0] != 'khrip' or len(words) > 2:
            fail(name, f'a code block must be ```khrip, ```khrip top or ```khrip body, found ```{info}')
            continue
        label = words[1] if len(words) == 2 else ''
        if label not in ('', 'top', 'body'):
            fail(name, f'unknown label {label}')
            continue
        src = f'{tmp}/{md[:-3]}_{line}.kh'
        program = wrap(label, text) if label else text
        with open(src, 'w', encoding='utf-8') as f:
            f.write(program)
        code, out = run([khc, 'check', src])
        if code != 0:
            fail(name, f'khc check:\n{out}')
            continue
        if not label:
            first_program.setdefault(md, text)
            if re.search(r'^test "', text, re.M) and not db_words.search(text):
                code, out = run([khc, 'test', src])
                if code != 0:
                    fail(name, f'khc test:\n{out}')
                    continue
        ok()

# 2. Примеры глав на настоящих базах
pg = os.environ.get('SKILL_PG', '')
ch_env = {}
if os.environ.get('CLICKHOUSE_URL'):
    ch_env = {'KHRIP_TEST_CLICKHOUSE_URL': os.environ['CLICKHOUSE_URL']}
    for k in ('USER', 'PASSWORD'):
        if os.environ.get(f'CLICKHOUSE_{k}'):
            ch_env[f'KHRIP_TEST_CLICKHOUSE_{k}'] = os.environ[f'CLICKHOUSE_{k}']
needs = {
    'postgresql': ('PostgreSQL', {'KHRIP_TEST_DATABASE_URL': pg} if pg else None),
    'mongodb': ('MongoDB', {} if os.environ.get('MONGODB_URI') else None),
    'clickhouse': ('ClickHouse', ch_env or None),
}
for f in sorted(os.listdir(f'{here}/run')):
    if not f.endswith('.kh'):
        continue
    chapter = f[:-3]
    name = f'{here}/run/{f}'
    md = f'{chapter}.md'
    if md not in first_program:
        fail(name, f'{skill}/{md} has no whole program to run')
        continue
    what, env = needs.get(chapter, ('', {}))
    if env is None:
        print(f'SKIP {name}: no {what} (see tests/skill/check.py)')
        continue
    src = f'{tmp}/run_{chapter}.kh'
    program = first_program[md] + '\n' + open(name, encoding='utf-8').read()
    if chapter == 'mongodb':
        # своя база тестов, а не app того, кто задал MONGODB_URI
        program = program.replace('"app"', '"khrip_skill_test"')
    with open(src, 'w', encoding='utf-8') as out_file:
        out_file.write(program)
    code, out = run([khc, 'test', src], env)
    if code != 0:
        fail(name, f'khc test:\n{out}')
        continue
    ok()

# 3. Ключевые правила
texts = {md: ' '.join(open(f'{skill}/{md}', encoding='utf-8').read().split()) for md in mds}
for f in sorted(os.listdir(f'{here}/rules')):
    if not f.endswith('.kh'):
        continue
    src = f'{here}/rules/{f}'
    head = open(src, encoding='utf-8').read()
    where = re.findall(r'^// in: *(.+)$', head, re.M)
    rules = re.findall(r'^// rule: *(.+)$', head, re.M)
    err = src[:-3] + '.err'
    if len(where) != 1 or where[0] not in texts or not rules:
        fail(src, 'needs one "// in: <skill file>" and at least one "// rule: <text>"')
        continue
    missing = [r for r in rules if ' '.join(r.split()) not in texts[where[0]]]
    if missing:
        fail(src, f'{skill}/{where[0]} no longer says: {missing[0]}')
        continue
    if re.search(r'^// expect:', head, re.M):
        fail(src, '"// expect:" matches anywhere in the output: put the whole output in a .err file')
        continue
    if os.path.exists(err):
        code, out = run([khc, 'check', src])
        want = open(err, encoding='utf-8').read()
        if code == 0 or out != want:
            fail(src, f'khc check gave (exit {code}), not {err}:\n{out}')
            continue
    elif re.search(r'^// compiles$', head, re.M):
        code, out = run([khc, 'check', src])
        if code != 0:
            fail(src, f'khc check:\n{out}')
            continue
    elif os.path.exists(src[:-3] + '.out'):
        code, out = run([khc, 'run', src])
        want = open(src[:-3] + '.out', encoding='utf-8').read()
        if code != 0 or out != want:
            fail(src, f'khc run gave (exit {code}):\n{out}')
            continue
    elif re.search(r'^test "', head, re.M):
        code, out = run([khc, 'test', src])
        if code != 0:
            fail(src, f'khc test:\n{out}')
            continue
    else:
        fail(src, 'checks nothing: add a .err or .out file, "// compiles" or test blocks')
        continue
    ok()

print(f'skill: {passed} {failed}')
