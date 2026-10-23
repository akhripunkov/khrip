// Сверка регулярных выражений Khrip (lib/regex.kh) с Go regexp.
//
//	go run tools/regex_go.go          пишет tests/run/regex_go.kh и tests/run/regex_go.out
//	go run tools/regex_go.go -check   ничего не пишет: сверяет эти файлы с тем, что
//	                                  написал бы сейчас (tests/run.sh, если есть go)
//
// Шаблоны: все правильные шаблоны набора tests/run/regex_grammar.kh (ответы
// библиотеки — в tests/run/regex_grammar.out) и свои ниже (semantic). Каждый
// правильный у нас шаблон Go тоже должен принять; неправильный у нас, но
// правильный в Go — это наша строгость, её список печатается для сведения.
//
// Для Go шаблон переводится с тем же смыслом: ^(?s:...)$ — строка целиком, и .
// берёт перевод строки; \w — [\p{L}\p{M}\p{Nd}\p{Pc}] (у Go \w — только ASCII),
// \s — White_Space (у Go \s — [\t\n\f\r ]), \W и \S — их дополнения; классы с
// \W или \S — через (?:...|...). Остальное (\d, \x{...}, ленивые повторы,
// ^ и $ внутри) у Go значит то же самое. Неправильный байт строки у Go — тоже
// отдельный символ U+FFFD.
//
// Каждый шаблон проверяется на общем наборе строк (pool) и своих строках.
// regex_go.kh печатает по строке на шаблон: номер и биты совпадений; так же —
// regex_go.out, посчитанный Go. Программа на Khrip сверяет ещё и литерал (слот
// места вызова) с разбором шаблона в арене и с s.matches(переменная).
package main

import (
	"bytes"
	"flag"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"
)

const (
	grammarKh  = "tests/run/regex_grammar.kh"
	grammarOut = "tests/run/regex_grammar.out"
	outKh      = "tests/run/regex_go.kh"
	outOut     = "tests/run/regex_go.out"
)

// Общий набор строк: ASCII, кириллица, CJK, эмодзи, пробелы Unicode, цифры
// других письменностей, неправильные байты.
var pool = []string{
	"", "a", "b", "c", "x", "aa", "ab", "ba", "abc", "aaa", "aab", "abb", "abab", "xy", "xyz",
	"A", "Z", "z", "Ab", "Ab Cd", "0", "1", "9", "12", "123", "1234", "a1", "_", "-", ".", "@",
	"x@y.z", "ann@x.io", "a b", " ", "  ", "\t", "\n", "\r\n", "\v", "\f",
	"{", "}", "[", "]", "(", ")", "|", "^", "$", "*", "+", "?", "\\", "/", "#a0B1c2",
	"dogs", "cat", "2024-01-15", "aaaaaaaaaaaaaaaaaaaaaaaaab",
	"я", "Я", "яя", "ян", "ё", "Ё", "привет", "Иван_1", "Анна-Мария", "é", "e\U00000301",
	"日本語", "😀", "😀😀", "😂", "١٢", "Ⅻ", "\U000000A0", "\U00002003", "\U00003000", "\U0000200B", "\U0000FEFF",
	"\u0085", "\U00002028", "\x00", "\x1f", "\x7f", "\xff", "\xd0", "\xe2\x82", "a\xffb",
	"\xed\xa0\x80", "\xf4\x90\x80\x80", "\xc0\xaf", "\U0000FFFD", "\U0010ffff", "Ѐ", "ӿ",
}

// Свои шаблоны: символы, классы и \w \s \d вне ASCII; строки к ним — сверх pool.
var semantic = []struct {
	pat string
	in  []string
}{
	{`[а-яё]+`, []string{"привет", "Привет", "ёлка", "ель", "мир!"}},
	{`[^а-я]+`, []string{"abc", "abя", "Я", "ё"}},
	{`[А-ЯЁа-яё\s-]+`, []string{"Анна-Мария", "Ёж ёж", "Ёж\U000000A0ёж", "Ёж_ёж"}},
	{`[А-ЯЁ][а-яё]+(-[А-ЯЁ][а-яё]+)?`, []string{"Анна", "Анна-Мария", "анна", "Анна-", "Ёлка-Ель"}},
	{`\w+`, []string{"Иван_1", "naïve", "日本", "a-b", "x\U00000301", "٣", "a\U0000203Fb", "Ⅻ"}},
	{`\W+`, []string{"!?", " - ", "\U000000A0", "é"}},
	{`\s+`, []string{" \t\n", "\U000000A0\U00002000\U00003000", "\U0000200B", "\U0000FEFF", "\v\f\r"}},
	{`\S+`, []string{"a\U000000A0", "\U0000200B\U0000FEFF", "\xff"}},
	{`\d+`, []string{"0123456789", "١٢", "\U0000FF10"}},
	{`\D+`, []string{"abc", "١٢", "1a"}},
	{`[\w\s]+`, []string{"Иван Петров", "a_b c", "a-b"}},
	{`[\W\d]+`, []string{"1!2", "a1", "١"}},
	{`[\S\s]`, []string{"я", "\U000000A0"}},
	{`[\w\W]+`, []string{"\xff\x00я"}},
	{`[^\w]`, []string{"я", "!", "\U000000A0"}},
	{`[^\s]`, []string{"я", "\U00003000", "\U0000200B"}},
	{`[^\d]`, []string{"5", "٥"}},
	{`[^\D]`, []string{"5", "٥"}},
	{`[\S\d]+`, []string{"a1", " 1"}},
	{`.`, nil},
	{`..`, nil},
	{`.{2,3}`, []string{"ябв", "я\xff"}},
	{`\x{FFFD}`, nil},
	{`[\x{FFFD}]+`, []string{"\xff\xfe", "\U0000FFFD\xff"}},
	{`[^\x{FFFD}]`, nil},
	{`[\x80-\x{10FFFF}]+`, []string{"яё😀", "яa"}},
	{`[\x00-\x7F]+`, []string{"abc\x7f", "ab\x80"}},
	{`[^\x00-\x7F]+`, []string{"яё😀", "\xff\xfe"}},
	{`😀+`, nil},
	{`[😀-🙏]+`, []string{"😀😂🙏", "😀🚀"}},
	{`(я|ян)+`, []string{"яяян", "янян", "ня"}},
	{`(?:ab|a)*b?`, []string{"abab", "aab", "abbb"}},
	{`(a|b)*abb`, []string{"aabb", "babb", "abab"}},
	{`(a?){5}a{5}`, []string{"aaaaa", "aaaaaaaaaa", "aaaaaaaaaaa"}},
	{`a{2,3}b{0,2}`, []string{"aab", "aaabb", "aaaabb", "abbb"}},
	{`x*y*z*`, []string{"xxyyzz", "xzy"}},
	{`(x|y|z)*`, []string{"xzy", "xzya"}},
	{`^a|b$`, nil},
	{`a$|^b`, nil},
	{`(^|a)b`, []string{"b", "ab", "aab"}},
	{`a(b|$)`, []string{"a", "ab", "abb"}},
	{`$^`, nil},
	{`^^a$$`, nil},
	{`(a$)?b`, nil},
	{`a\x{301}?`, []string{"a\U00000301", "á"}},
	{`[а-я]{2}`, []string{"яя", "я", "яяя", "яa"}},
	{`[^@\s]+@[^@\s]+`, []string{"ann@x.io", "ан@пример.рф", "a b@c", "a@b@c", "a\U000000A0b@c"}},
	{`[A-Za-z0-9_-]{3,32}`, []string{"user_1", "юзер", "ab"}},
	{`[\x{400}-\x{4FF}]+`, []string{"Ѐӿ", "Ԁ"}},
}

func check(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "regex_go:", err)
		os.Exit(1)
	}
}

// Набор шаблонов tests/run/regex_grammar.kh и ответы библиотеки на них.
func grammar() (pats []string, ok []bool) {
	src, err := os.ReadFile(grammarKh)
	check(err)
	in := false
	for _, line := range strings.Split(string(src), "\n") {
		t := strings.TrimSpace(line)
		if t == "// набор" {
			in = true
			continue
		}
		if t == "// конец набора" {
			break
		}
		if in {
			if !strings.HasPrefix(t, "`") || !strings.HasSuffix(t, "`,") {
				check(fmt.Errorf("%s: not a pattern line: %q", grammarKh, line))
			}
			pats = append(pats, t[1:len(t)-2])
		}
	}
	out, err := os.ReadFile(grammarOut)
	check(err)
	lines := strings.Split(strings.TrimRight(string(out), "\n"), "\n")
	if len(lines) != len(pats) {
		check(fmt.Errorf("%s: %d lines for %d patterns", grammarOut, len(lines), len(pats)))
	}
	for i, l := range lines {
		ok = append(ok, l == fmt.Sprintf("%d: ok", i))
	}
	return
}

const goWord = `\p{L}\p{M}\p{Nd}\p{Pc}`
const goSpace = `\t\n\v\f\r \x{85}\x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}`

// Код экранирования в rs[i] == '\\' (не \d \w \s и т. п.) и индекс после него.
func escape(rs []rune, i int) (rune, int) {
	e := rs[i+1]
	switch e {
	case 'n':
		return '\n', i + 2
	case 't':
		return '\t', i + 2
	case 'r':
		return '\r', i + 2
	case 'f':
		return '\f', i + 2
	case 'v':
		return '\v', i + 2
	case 'x':
		if rs[i+2] == '{' {
			j := i + 3
			for rs[j] != '}' {
				j++
			}
			v, err := strconv.ParseInt(string(rs[i+3:j]), 16, 32)
			check(err)
			return rune(v), j + 1
		}
		v, err := strconv.ParseInt(string(rs[i+2:i+4]), 16, 32)
		check(err)
		return rune(v), i + 4
	}
	return e, i + 2
}

// Класс rs[i] == '[' в синтаксисе Go → текст и индекс после ]; ok = false, если
// перевести нельзя ([^...] с \W или \S).
func class(rs []rune, i int) (string, int, bool) {
	i++
	neg := false
	if rs[i] == '^' {
		neg = true
		i++
	}
	var items strings.Builder
	var alts []string
	first := true
	for {
		c := rs[i]
		if c == ']' && !first {
			i++
			break
		}
		first = false
		var lo rune
		if c == '\\' {
			switch rs[i+1] {
			case 'd':
				items.WriteString(`\d`)
				i += 2
				continue
			case 'D':
				items.WriteString(`\D`)
				i += 2
				continue
			case 'w':
				items.WriteString(goWord)
				i += 2
				continue
			case 's':
				items.WriteString(goSpace)
				i += 2
				continue
			case 'W':
				alts = append(alts, "[^"+goWord+"]")
				i += 2
				continue
			case 'S':
				alts = append(alts, "[^"+goSpace+"]")
				i += 2
				continue
			}
			lo, i = escape(rs, i)
		} else {
			lo = c
			i++
		}
		hi := lo
		if rs[i] == '-' && i+1 < len(rs) && rs[i+1] != ']' {
			i++
			if rs[i] == '\\' {
				hi, i = escape(rs, i)
			} else {
				hi = rs[i]
				i++
			}
		}
		fmt.Fprintf(&items, `\x{%X}-\x{%X}`, lo, hi)
	}
	if len(alts) == 0 {
		if neg {
			return "[^" + items.String() + "]", i, true
		}
		return "[" + items.String() + "]", i, true
	}
	if neg {
		return "", i, false
	}
	if items.Len() > 0 {
		alts = append(alts, "["+items.String()+"]")
	}
	return "(?:" + strings.Join(alts, "|") + ")", i, true
}

// Шаблон Khrip (правильный) → шаблон Go с тем же смыслом.
func translate(p string) (string, bool) {
	rs := []rune(p)
	rs = append(rs, 0, 0, 0, 0)
	n := len(rs) - 4
	var b strings.Builder
	for i := 0; i < n; {
		c := rs[i]
		if c == '[' {
			s, j, ok := class(rs, i)
			if !ok {
				return "", false
			}
			b.WriteString(s)
			i = j
			continue
		}
		if c == '\\' {
			switch rs[i+1] {
			case 'w':
				b.WriteString("[" + goWord + "]")
			case 'W':
				b.WriteString("[^" + goWord + "]")
			case 's':
				b.WriteString("[" + goSpace + "]")
			case 'S':
				b.WriteString("[^" + goSpace + "]")
			case 'd', 'D':
				b.WriteString(string(rs[i : i+2]))
			default:
				v, j := escape(rs, i)
				fmt.Fprintf(&b, `\x{%X}`, v)
				i = j
				continue
			}
			i += 2
			continue
		}
		b.WriteRune(c)
		i++
	}
	return "^(?s:" + b.String() + ")$", true
}

// Строка как литерал Khrip: обычная строка, если в ней только печатные
// символы без \ " { }, иначе — unhex("...").
func khStr(s string) string {
	plain := utf8.ValidString(s)
	for _, r := range s {
		if r < 0x20 || r == 0x7f || r == '\\' || r == '"' || r == '{' || r == '}' || (r >= 0x80 && r < 0xa0) || r == 0xfeff || r == 0x200b || r == 0x2028 || r == 0x301 {
			plain = false
		}
	}
	if plain {
		return `"` + s + `"`
	}
	return fmt.Sprintf(`unhex("%x")`, s)
}

func khList(xs []string) string {
	parts := make([]string, len(xs))
	for i, x := range xs {
		parts[i] = khStr(x)
	}
	return "[" + strings.Join(parts, ", ") + "]"
}

// Тяжёлые шаблоны (большие повторы, глубокая вложенность) в сверку строк не
// идут: их разбор проверяет regex_grammar.
var heavy = regexp.MustCompile(`\{[0-9]*[0-9]{3}`)

func main() {
	checkOnly := flag.Bool("check", false, "compare with the committed files instead of writing them")
	flag.Parse()

	pats, ok := grammar()
	var strict []string
	type item struct {
		pat string
		in  []string
	}
	var items []item
	seen := map[string]int{}
	bad := 0
	limits := 0
	for i, p := range pats {
		if !ok[i] {
			if _, err := regexp.Compile(`^(?s:` + p + `)$`); err == nil {
				strict = append(strict, p)
			}
			continue
		}
		g, tr := translate(p)
		if tr {
			if _, err := regexp.Compile(g); err != nil {
				// пределы Go строже наших: произведение вложенных повторов не
				// больше 1000 и 1000 уровней вложенности вместе с (?s:...); у
				// нас — 100 000 инструкций программы и 1000 групп
				msg := err.Error()
				if strings.Contains(msg, "invalid repeat count") || strings.Contains(msg, "nests too deeply") {
					limits++
					continue
				}
				fmt.Fprintf(os.Stderr, "regex_go: %d %q: accepted by Khrip, rejected by Go: %v\n", i, p, err)
				bad++
				continue
			}
		}
		if _, dup := seen[p]; !tr || dup || len(p) > 200 || heavy.MatchString(p) {
			continue
		}
		seen[p] = len(items)
		items = append(items, item{p, nil})
	}
	for _, s := range semantic {
		if k, dup := seen[s.pat]; dup {
			items[k].in = append(items[k].in, s.in...)
			continue
		}
		seen[s.pat] = len(items)
		items = append(items, item{s.pat, s.in})
	}
	if bad > 0 {
		os.Exit(1)
	}

	var kh, out bytes.Buffer
	kh.WriteString(`// Создано tools/regex_go.go — не править руками: поменяйте генератор и
// запустите go run tools/regex_go.go. Сверка с Go regexp: каждый шаблон — на
// общем наборе строк и своих строках; строка вывода — номер шаблона и биты
// совпадений (1 — строка целиком подходит). regex_go.out посчитал Go.
// Литерал в s.matches — программа в слоте места вызова; ответы сверяются с
// программой, разобранной в арене (__rx_program), и с s.matches(переменная).

fn unhex(h: str) -> str {
    let b = buf_new(h.byte_len() / 2 + 1)
    var i = 0
    while i + 1 < h.byte_len() {
        buf_byte(b, hexd(h.byte(i)) * 16 + hexd(h.byte(i + 1)))
        i += 2
    }
    return buf_str(b)
}

fn hexd(c: int) -> int {
    if c >= 'a' {
        return c - 'a' + 10
    }
    return c - '0'
}

fn cat(a: [str], b: [str]) -> [str] {
    var r: [str] = []
    for s in a {
        r.push(s)
    }
    for s in b {
        r.push(s)
    }
    return r
}

fn bit(v: bool) -> str {
    if v {
        return "1"
    }
    return "0"
}

// Ответы литерала got сверяются с программой в арене и с s.matches(pat).
fn report(i: int, pat: str, ins: [str], got: str) {
    let prog = __rx_program(pat, false)
    var arena = ""
    var dyn = ""
    for s in ins {
        arena += bit(__rx_exec(prog, s))
        dyn += bit(s.matches(pat))
    }
    if arena != got || dyn != got {
        print("{i} {got} literal/arena/dynamic differ: {arena} {dyn}")
        return
    }
    print("{i} {got}")
}

fn main() {
`)
	fmt.Fprintf(&kh, "    let pool = %s\n", khList(pool))
	for i, it := range items {
		g, _ := translate(it.pat)
		re := regexp.MustCompile(g)
		ins := append(append([]string{}, pool...), it.in...)
		var bits strings.Builder
		for _, s := range ins {
			if re.MatchString(s) {
				bits.WriteByte('1')
			} else {
				bits.WriteByte('0')
			}
		}
		fmt.Fprintf(&out, "%d %s\n", i, bits.String())
		fmt.Fprintf(&kh, "    // %d\n", i)
		if len(it.in) > 0 {
			fmt.Fprintf(&kh, "    let x%d = %s\n", i, khList(it.in))
			fmt.Fprintf(&kh, "    let in%d = cat(pool, x%d)\n", i, i)
		} else {
			fmt.Fprintf(&kh, "    let in%d = pool\n", i)
		}
		fmt.Fprintf(&kh, "    var m%d = \"\"\n", i)
		fmt.Fprintf(&kh, "    for s in in%d {\n        m%d += bit(s.matches(`%s`))\n    }\n", i, i, it.pat)
		fmt.Fprintf(&kh, "    report(%d, `%s`, in%d, m%d)\n", i, it.pat, i, i)
	}
	kh.WriteString("}\n")

	if len(strict) > 0 {
		fmt.Fprintf(os.Stderr, "regex_go: %d patterns rejected by Khrip but accepted by Go (stricter grammar)\n", len(strict))
	}
	if limits > 0 {
		fmt.Fprintf(os.Stderr, "regex_go: %d patterns over the Go size or nesting limits\n", limits)
	}
	if *checkOnly {
		for _, f := range []struct {
			path string
			data []byte
		}{{outKh, kh.Bytes()}, {outOut, out.Bytes()}} {
			old, err := os.ReadFile(f.path)
			check(err)
			if !bytes.Equal(old, f.data) {
				check(fmt.Errorf("%s is out of date: run go run tools/regex_go.go", f.path))
			}
		}
		fmt.Printf("regex_go: %d patterns agree with Go regexp\n", len(items))
		return
	}
	check(os.WriteFile(outKh, kh.Bytes(), 0o644))
	check(os.WriteFile(outOut, out.Bytes(), 0o644))
	fmt.Printf("regex_go: %d patterns written\n", len(items))
}
