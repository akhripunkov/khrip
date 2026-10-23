#!/usr/bin/env bash
# Сверка таблиц Unicode (lib/text_tables.kh) с Python unicodedata — вручную,
# после tools/unicode_tables.kh; tests/run.sh её не запускает.
#
#   tools/unicode_check.sh путь/к/UnicodeData.txt
#
# Программа на Khrip выводит для каждого кода то, что отвечает рантайм:
# простые отображения регистра (__case_map), \w (__cp_is_word) и White_Space
# (__cp_is_space). Python сравнивает это со своей unicodedata (Python 3.13 —
# Unicode 15.1) только там, где у кода в обеих версиях одна общая категория
# (её для новой версии берём из того же UnicodeData.txt, что и генератор):
#   - регистр — с str.lower()/str.upper(), когда они дают один символ (иначе это
#     полное отображение из SpecialCasing, у нас его нет: ß → SS);
#     расхождение, где наш ответ — код, которого в старой версии ещё нет
#     (U+0264 → U+A7CB появилось в Unicode 16), объясняет версия;
#   - \w — с категориями L, M, Nd, Pc по unicodedata.category;
#   - White_Space — с str.isspace(): у Python это другое свойство, и коды
#     U+001C–001F (разделители информации) ожидаемо расходятся.
# Код выхода 1, если есть необъяснённые расхождения.
set -euo pipefail
cd "$(dirname "$0")/.."
KHC=${KHC:-build/khc}
data=${1:?usage: tools/unicode_check.sh UnicodeData.txt}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/dump.kh" <<'EOF'
// Коды, у которых есть отображение регистра, \w или пробел: «код нижний верхний
// \w пробел», числа — десятичные.
fn main() -> int {
    var lines: [str] = []
    for cp in 0..0x110000 {
        let lo = __case_map(cp, false)
        let up = __case_map(cp, true)
        let w = __cp_is_word(cp)
        let sp = __cp_is_space(cp)
        if lo != cp || up != cp || w || sp {
            var wv = 0
            if w {
                wv = 1
            }
            var sv = 0
            if sp {
                sv = 1
            }
            lines.push("{cp} {lo} {up} {wv} {sv}")
        }
    }
    write(lines.join("\n") + "\n")
    return 0
}
EOF
"$KHC" -o "$tmp/dump" "$tmp/dump.kh"
"$tmp/dump" >"$tmp/maps.txt"

python3 -I - "$data" "$tmp/maps.txt" <<'PY'
import sys, unicodedata

cat_new = {}
first = None
for line in open(sys.argv[1], encoding="utf-8"):
    f = line.split(";")
    cp, name, cat = int(f[0], 16), f[1], f[2]
    if name.endswith(", First>"):
        first = cp
        continue
    lo = first if name.endswith(", Last>") else cp
    for c in range(lo, cp + 1):
        cat_new[c] = cat

maps = {}
for line in open(sys.argv[2]):
    cp, lo, up, w, sp = map(int, line.split())
    maps[cp] = (lo, up, w == 1, sp == 1)

old = unicodedata.unidata_version
same = skipped = full = 0
case_ok = case_new = word_ok = 0
bad = []
space_diff = []
for cp in range(0x110000):
    c = chr(cp)
    cat = unicodedata.category(c)
    if cat != cat_new.get(cp, "Cn"):
        skipped += 1
        continue
    same += 1
    lo, up, w, sp = maps.get(cp, (cp, cp, False, False))
    for what, ours, py in (("lower", lo, c.lower()), ("upper", up, c.upper())):
        if len(py) != 1:
            full += 1
        elif ord(py) == ours:
            case_ok += 1
        elif unicodedata.category(chr(ours)) == "Cn":
            case_new += 1
        else:
            bad.append("U+%04X %s: ours U+%04X, Python U+%04X" % (cp, what, ours, ord(py)))
    if w == (cat[0] in "LM" or cat in ("Nd", "Pc")):
        word_ok += 1
    else:
        bad.append("U+%04X \\w: ours %s, category %s" % (cp, w, cat))
    if sp != c.isspace():
        space_diff.append(cp)

print("Python unicodedata %s vs the tables: %d code points with the same category, %d skipped (category differs)" % (old, same, skipped))
print("case: %d mappings agree, %d differ by a character new after %s, %d full mappings skipped" % (case_ok, case_new, old, full))
print("\\w: %d agree" % word_ok)
print("White_Space vs isspace(): differ at %s" % " ".join("U+%04X" % c for c in space_diff))
for b in bad:
    print("MISMATCH " + b)
expected_space = [0x1C, 0x1D, 0x1E, 0x1F]
if bad or space_diff != expected_space:
    print("FAILED")
    sys.exit(1)
print("ok")
PY
