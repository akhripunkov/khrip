#!/usr/bin/env python3
# Анализ чтения на сгенерированных программах: много коротких маршрутов, в
# каждом значение из store (или из параметра со значением store) доходит до
# локальной через ?? (и через перевод строки), скобки, if и match как
# значения, литералы списков, свежие словари, присваивания (и через ;), а
# рядом — приманки: локальные с именем store или параметра во вложенном
# блоке, второе объявление того же имени, параметр лямбды с тем же именем,
# объявления без значения (var z: [int]; m[k] = c), своя функция с именем
# copy. Потом локальную меняют (или кладут в store прямо). Ни один такой
# маршрут не должен получить read (khc check --locks): ложное read — гонка
# данных.
# Маршруты только со свежими значениями — для счёта (их read не обязателен).
#
#   tests/rw_gen.py khc dir [seed] → 0, если ложных read нет
import random
import re
import subprocess
import sys

KHC, DIR = sys.argv[1], sys.argv[2]
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else 1

D = 'Cat { name: "", count: 0, ids: [] }'
NL = "\n        "

HEAD = '''type Cat { name: str, count: int, ids: [int] }
type Shape = Circle { c: Cat } | Empty
type Holder { cats: [Cat] }

store groups: map[str, Cat]
store clists: map[str, [Cat]]
store holder: Holder = Holder { cats: [] }

fn touch(c: Cat) {
    c.count += 1
}
'''

# своя функция с именем метода, который возвращает новый список
NAMED = '''
fn copy(h: Holder) -> [Cat] {
    return h.cats
}
'''


class Gen:
    def __init__(self, rnd, named):
        self.r = rnd
        self.named = named

    def nl(self, ok):
        # ?? или [0] на следующей строке — то же выражение (но не в блоке
        # if-значения: там значение — последняя строка блока)
        if ok and self.r.random() < 0.5:
            return NL
        return ""

    def opt(self, src):
        # значение Cat?: (текст, из store ли)
        forms = [('seen["a"]', False), ('cats["a"]', False)]
        if src:
            forms += [(src + '["a"]', True)] * 3
        return self.r.choice(forms)

    def qq(self, ok):
        n = self.nl(ok)
        return n + "?? " if n else " ?? "

    def cat(self, depth, src, ok):
        # значение Cat: (текст, из store ли); ok — можно переносить строку
        r = self.r
        k = r.randrange(8 if depth < 2 else 2)
        if k == 0:
            return D, False
        if k == 1:
            o, s = self.opt(src)
            return o + self.qq(ok) + D, s
        if k in (2, 3):
            o, s1 = self.opt(src)
            e, s2 = self.cat(depth + 1, src, ok)
            return o + self.qq(ok) + e, s1 or s2
        if k == 4:
            e, s = self.cat(depth + 1, src, ok)
            return "(" + e + ")", s
        if k == 5:
            a, s1 = self.cat(depth + 1, src, False)
            b, s2 = self.cat(depth + 1, src, False)
            return "if flag { " + a + " } else { " + b + " }", s1 or s2
        if k == 6:
            e, s = self.cat(depth + 1, src, ok)
            return "[" + e + "]" + self.nl(ok) + "[0]", s
        a, s1 = self.cat(depth + 1, src, ok)
        b, s2 = self.cat(depth + 1, src, ok)
        return "match sh {" + NL + "Circle x => " + a + NL + "Empty => " + b + "\n    }", s1 or s2

    def write(self, name):
        return self.r.choice([
            name + ".count += 1",
            name + ".ids.push(1)",
            name + '.name = "x"',
            name + ".ids.clear()",
            "touch(" + name + ")",
        ])

    def decoys(self, src):
        r = self.r
        out = []
        for _ in range(r.randrange(3)):
            k = r.randrange(6)
            if k == 0 and src:
                # локальная с именем store или параметра во вложенном блоке (без
                # записи в неё: m[k] = v анализ и так считал бы записью)
                out.append("if flag {\n        var " + src + ": map[str, Cat] = {}\n        let n = " + src + ".len()\n    }")
            elif k == 1:
                out.append("if flag {\n        let c = " + D + "\n        c.count += 1\n    }")
            elif k == 2:
                out.append("let n" + str(r.randrange(1000)) + " = groups.values().filter(c => c.count > 0).len()")
            elif k == 3:
                out.append("if flag {\n        var c = " + D + "\n        c = " + D + "\n    }")
            elif k == 4:
                # объявление без значения: = после него — уже другой оператор
                out.append("var z" + str(r.randrange(1000)) + ": " + r.choice(["[int]", "map[str, [Cat]]", "Cat?", "[[str]]"]))
            else:
                out.append('let q' + str(r.randrange(1000)) + ' = Cat { name: "c", count: 0, ids: [] }')
        return out

    def body(self, src):
        # операторы, которые доводят значение до c и меняют c → (текст, из
        # store ли значение c)
        r = self.r
        pre = ["var seen: map[str, Cat] = {}", "var cats: map[str, Cat] = {}", "let flag = groups.len() > 1000000", "let sh: Shape = Empty", 'let kb = "b"']
        e, s = self.cat(0, src, True)
        k = r.randrange(6)
        if k == 0:
            st = ["let c = " + e]
        elif k == 1:
            st = ["var c = " + D, "c = " + e]
        elif k == 2:
            # через свежий словарь: кладут e, читают обратно
            st = ['var box: map[str, Cat] = {}', 'box["a"] = ' + e, 'let c = box["a"]' + self.qq(True) + D]
        elif k == 3:
            st = ["let cs = [" + e + "]", "let c = cs[0]"]
        elif k == 4 and src:
            st = ["let c = " + src + '["a"] else {\n        return 0\n    }']
            s = True
        else:
            st = ["var c = " + D, "if flag {\n        c = " + D + "\n    } else {\n        c = " + e + "\n    }"]
        if src and r.random() < 0.2:
            # запись в store прямо: m[k] = c, иногда через ; после объявления
            # без значения
            w = src + "[kb] = c"
            if r.random() < 0.5:
                w = "var z: " + r.choice(["[int]", "map[str, [Cat]]", "Cat?", "[[str]]"]) + "; " + w
            st.append(w)
            s = True
        else:
            st.append(self.write("c"))
        lines = pre + st
        d = self.decoys(src)
        for x in d:
            lines.insert(r.randrange(len(pre), len(lines) + 1), x)
        return self.join(lines), s

    def join(self, lines):
        # ; вместо перевода строки (лексер её отбрасывает) — после однострочного
        # let или var (после x.f(...) парсер принял бы строку за присваивание)
        text = lines[0]
        for i in range(1, len(lines)):
            prev = lines[i - 1]
            if "\n" not in prev and "\n" not in lines[i] and prev.startswith(("let ", "var ")) and self.r.random() < 0.4:
                text += "; " + lines[i]
            else:
                text += "\n    " + lines[i]
        return text

    def list_body(self):
        # списки store: копия свежая, сам список — нет
        r = self.r
        src = r.choice(['clists["a"] ?? []', '(clists["a"] ?? [])', 'clists["a"]' + self.qq(True) + "holder.cats.copy()", "holder.cats", "holder.copy()" if self.named else "holder.cats"])
        # копия свежая (но не x ?? y.copy(): там свежая только правая часть)
        fresh = r.random() < 0.3 and src != "holder.copy()" and "??" not in src
        if fresh:
            src = src + ".copy()"
        k = r.randrange(3)
        if k == 0:
            st = ["let xs = " + src]
        elif k == 1:
            st = ["var cache: map[str, [Cat]] = {}", 'cache["a"] = ' + src, 'let xs = cache["a"]' + self.qq(True) + "[]"]
        else:
            st = ["var xs: [Cat] = []", "let t = 1", "xs = " + src]
        if r.random() < 0.3:
            st.append("var z: [Cat]")
        if r.random() < 0.2:
            st.append('clists["b"] = xs')
            fresh = False
        else:
            st.append(r.choice(["xs.push(" + D + ")", "xs.clear()", "xs.reverse()", "xs.sort_by(c => c.count)"]))
        return self.join(st), not fresh


def program(seed, named, n):
    rnd = random.Random(seed)
    g = Gen(rnd, named)
    parts = [HEAD]
    if named:
        parts.append(NAMED)
    want = {}
    for i in range(n):
        path = "/r" + str(i)
        k = rnd.randrange(4)
        if k == 0:
            # через параметр функции
            b, s = g.body("g")
            parts.append("\nfn h" + str(i) + "(g: map[str, Cat]) -> int {\n    " + b + "\n    return 1\n}\n")
            parts.append('\nroute GET "' + path + '" -> int {\n    return h' + str(i) + "(groups)\n}\n")
        elif k == 1:
            b, s = g.list_body()
            parts.append('\nroute GET "' + path + '" -> int {\n    ' + b + "\n    return 1\n}\n")
        else:
            b, s = g.body("groups")
            parts.append('\nroute GET "' + path + '" -> int {\n    ' + b + "\n    return 1\n}\n")
        want["GET " + path] = s
    return "".join(parts), want


def main():
    bad = 0
    reads = 0
    total = 0
    for p in range(6):
        named = p % 2 == 1
        src, want = program(SEED * 100 + p, named, 60)
        path = DIR + "/rw_gen" + str(p) + ".kh"
        open(path, "w").write(src)
        out = subprocess.run([KHC, "check", "--locks", path], capture_output=True, text=True)
        if out.returncode != 0:
            print("не скомпилировалось: " + path + "\n" + out.stdout + out.stderr)
            return 1
        got = dict(re.findall(r"^(GET /r\d+): (read|write)$", out.stdout, re.M))
        for route, store in want.items():
            total += 1
            if got.get(route) is None:
                print("нет маршрута " + route + " в " + path)
                bad += 1
            elif got[route] == "read":
                reads += 1
                if store:
                    print("ложное read: " + route + " в " + path)
                    bad += 1
    print("маршрутов " + str(total) + ", read " + str(reads) + ", ложных read " + str(bad))
    return 1 if bad else 0


sys.exit(main())
