# Общее для проверок: check, field. Сервер уже запущен на $U.
U=${U:-http://127.0.0.1:8080}
fails=0
total=0
LAST=
J=(-H 'Content-Type: application/json')

# JSON без пробелов между лексемами (решения могут печатать JSON с отступами).
compact() {
	python3 -c 'import sys, json
t = sys.stdin.read()
try:
    print(json.dumps(json.loads(t), separators=(",", ":"), ensure_ascii=False))
except Exception:
    print(t, end="")'
}

# check <название> <код> <образцы> <аргументы curl...>
# Код — шаблон bash ('4[0-9][0-9]'). Образцы — расширенные регулярные выражения через
# « && », все должны найтись; образец «H:...» ищется в заголовках без учёта регистра,
# остальные — в теле. Тело последнего ответа остаётся в LAST.
check() {
	local name=$1 want=$2 pattern=$3
	shift 3
	total=$((total + 1))
	local hdr out code body ok=1 rest p
	hdr=$(mktemp)
	out=$(curl -s --max-time 10 -D "$hdr" -w '\n%{http_code}' "$@")
	code=${out##*$'\n'}
	body=$(printf '%s' "${out%$'\n'*}" | compact)
	LAST=$body
	[[ "$code" == $want ]] || ok=0
	rest=$pattern
	while [[ -n "$rest" ]]; do
		p=${rest%% && *}
		if [[ "$p" == "$rest" ]]; then rest=""; else rest=${rest#* && }; fi
		if [[ $p == H:* ]]; then
			tr -d '\r' <"$hdr" | grep -qiE -- "${p#H:}" || ok=0
		else
			grep -qE -- "$p" <<<"$body" || ok=0
		fi
	done
	rm -f "$hdr"
	if [[ $ok -eq 0 ]]; then
		echo "FAIL $name: $code ${body:0:300}"
		fails=$((fails + 1))
	fi
}

# field <имя> — значение поля из тела последнего ответа (первое вхождение).
field() {
	grep -oE "\"$1\":(\"[^\"]*\"|[-0-9.eE+]+|true|false)" <<<"$LAST" | head -1 | sed -E 's/^"[^"]*"://; s/^"//; s/"$//'
}

# jtest <название> <выражение Python над j — разобранным JSON последнего ответа>
jtest() {
	total=$((total + 1))
	python3 -c 'import sys, json
j = json.loads(sys.argv[1])
sys.exit(0 if eval(sys.argv[2]) else 1)' "$LAST" "$2" 2>/dev/null || {
		echo "FAIL $1: ${LAST:0:300}"
		fails=$((fails + 1))
	}
}

# jval <выражение Python над j> — значение из последнего ответа (например, id).
jval() {
	python3 -c 'import sys, json
try:
    print(eval(sys.argv[2], {"j": json.loads(sys.argv[1])}))
except Exception:
    print("?")' "$LAST" "$1"
}

# race <сколько> <параллельно> <путь> <аргументы curl...> — одновременные
# запросы, поровну к обеим копиям сервера ($U и $U2, если она есть); печатает
# коды ответов с числом: « 30 201; 30 409;».
race() {
	local n=$1 p=$2 path=$3
	shift 3
	seq "$n" | xargs -P "$p" -I{} bash -c 'if (( {} % 2 )); then u=$0; else u=$1; fi
curl -s -o /dev/null --max-time 30 -w "%{http_code}\n" "${@:3}" "$u$2"' "$U" "${U2:-$U}" "$path" "$@" |
		sort | uniq -c | tr -s ' ' | tr '\n' ';'
}

# same <название> <получено> <ожидалось>
same() {
	total=$((total + 1))
	if [[ "$2" != "$3" ]]; then
		echo "FAIL $1: «$2», ожидалось «$3»"
		fails=$((fails + 1))
	fi
}

# Итог: число проверок и проваленных; код возврата 1 при провалах.
finish() {
	echo "passed $((total - fails))/$total"
	[[ $fails -eq 0 ]]
}

ISO='"20[0-9]{2}-[01][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-6][0-9](\.[0-9]+)?(Z|\+00:00)"'
