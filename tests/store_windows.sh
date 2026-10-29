#!/usr/bin/env bash
# Места, где отпускается блокировка store (docs/design/v0.13-store-gc.md
# §6.5–6.6). Посреди работы store отпускает только __store_release_keep, и
# только в проверенных местах: новое место должно пройти проверку правил окна
# W1–W3 и попасть в список ниже. Отпускание без записи — только внутри API
# блокировки (lib/rt.kh). Вызовы ищутся в коде без комментариев и строк (кроме
# подстановок {...} в строках — это код), с точностью до функции.
#
#   tests/store_windows.sh [корень]  — без вывода и с кодом 0, если всё на
#   месте; иначе — что нашлось где, код 1. Вызывается из tests/run.sh, там же
#   — проверка самой проверки на копиях библиотеки с подложенными нарушениями.
set -uo pipefail
cd "${1:-.}" || exit 2

# файл:функция, где разрешён вызов (определение — тоже вызов; «-» — вне
# функций, «*» — любая функция файла). «=» — список мест ровно такой
# (переименованное место тоже ошибка), «<» — не шире. __store_rw — блок
# блокировки: кроме API блокировки его трогают только замки других слов блока
# (постоянная память, счётчик арен, таблицы символов, корни сертификатов, кэш
# схем ClickHouse) и проверка владельца (lib/gc_verify.kh).
rules=(
	"= __store_release_keep( lib/rt.kh:__store_release_keep lib/rt.kh:__co_wait lib/fetch.kh:__fetch lib/crypto.kh:__pbkdf2_unlocked lib/mongo.kh:mongo_command lib/clickhouse.kh:__ch_run"
	"= __store_unlock_raw( lib/rt.kh:__store_unlock_raw lib/rt.kh:__store_release_keep lib/rt.kh:__store_release_final lib/gc.kh:__pin_self_fallback"
	"= __store_write_unlock( lib/rt.kh:__store_write_unlock lib/rt.kh:__store_unlock_raw lib/rt.kh:__store_unlock_gc"
	"< __store_unlock_gc( lib/rt.kh:__store_unlock_gc lib/gc.kh:* lib/gc_verify.kh:__gc_window_cycle tests/api/gc_records.kh:*"
	"< __store_unlock_marker( lib/rt.kh:__store_unlock_marker lib/gc.kh:* tests/api/gc_records.kh:*"
	"< __store_rw lib/rt.kh:- lib/rt.kh:__store_rw_init lib/rt.kh:__store_lock lib/rt.kh:__store_unlock_raw lib/rt.kh:__store_lock_gc lib/rt.kh:__store_unlock_gc lib/rt.kh:__store_lock_marker lib/rt.kh:__store_unlock_marker lib/rt.kh:__perm_alloc lib/rt.kh:__arena_take lib/text.kh:__chars lib/x509.kh:__roots lib/x509.kh:__roots_from lib/clickhouse.kh:__ch_schema_block lib/gc_verify.kh:__gc_check_owner tests/api/gc_records.kh:*"
)

files=$(find lib src tests eval examples docs bench tools bootstrap -name '*.kh' 2>/dev/null | sort)
calls=$(mktemp)
trap 'rm -f "$calls"' EXIT
# Строки «файл функция код»: код без комментариев, строковых и символьных
# литералов (подстановки {...} в "..." остаются); функция — fn, а для блоков
# test и route — test и route. Сырые строки `...` бывают многострочными.
# shellcheck disable=SC2086
awk '
function strip(line,   out, i, n, c, j, top) {
	out = ""
	n = length(line)
	i = 1
	while (i <= n) {
		c = substr(line, i, 1)
		top = mode[sp]
		if (top == "R") {
			if (c == "`") {
				sp--
			}
			out = out " "
			i++
			continue
		}
		if (top == "S") {
			if (c == "\\") {
				out = out "  "
				i += 2
			} else if (c == "\"") {
				sp--
				out = out " "
				i++
			} else if (c == "{") {
				sp++
				mode[sp] = "C"
				depth[sp] = 0
				out = out " "
				i++
			} else {
				out = out " "
				i++
			}
			continue
		}
		if (c == "/" && substr(line, i + 1, 1) == "/") {
			break
		}
		if (c == "\"") {
			sp++
			mode[sp] = "S"
			out = out " "
			i++
			continue
		}
		if (c == "`") {
			sp++
			mode[sp] = "R"
			out = out " "
			i++
			continue
		}
		if (c == "\047") {
			j = i + 1
			if (substr(line, j, 1) == "\\") {
				j += 2
			}
			while (j <= n && substr(line, j, 1) != "\047") {
				j++
			}
			out = out " "
			i = j + 1
			continue
		}
		if (c == "{") {
			depth[sp]++
		} else if (c == "}") {
			if (sp > 0 && depth[sp] == 0 && mode[sp - 1] == "S") {
				sp--
				out = out " "
				i++
				continue
			}
			depth[sp]--
		}
		out = out c
		i++
	}
	# строка "..." кончается в своей строке файла (иначе это ошибка компилятора)
	for (j = 1; j <= sp; j++) {
		if (mode[j] == "S") {
			sp = j - 1
			break
		}
	}
	return out
}
FNR == 1 {
	f = "-"
	sp = 0
	mode[0] = "C"
	depth[0] = 0
}
{
	if (sp == 0 || mode[sp] != "R") {
		if ($0 ~ /^fn [A-Za-z_0-9]+\(/) {
			f = $2
			sub(/\(.*/, "", f)
		} else if ($0 ~ /^test /) {
			f = "test"
		} else if ($0 ~ /^route /) {
			f = "route"
		} else if ($0 ~ /^(var|const|type|store) /) {
			f = "-"
		}
	}
	code = strip($0)
	if (code ~ /__store/) {
		print FILENAME " " f " " code
	}
	# конец функции или блока
	if ($0 ~ /^}/ && (sp == 0 || mode[sp] != "R")) {
		f = "-"
	}
}' $files >"$calls"

bad=0
for rule in "${rules[@]}"; do
	read -r kind token allowed <<<"$rule"
	# где встречается: файл:функция (без повторов)
	# имя целиком: __store_rw — не __store_rw_init
	re=${token//(/[(]}
	[[ "$token" != *"(" ]] && re="$re([^A-Za-z0-9_]|\$)"
	found=$(awk -v re="(^|[^A-Za-z0-9_])$re" '{ code = $0; sub(/^[^ ]+ [^ ]+ /, "", code) } code ~ re { print $1 ":" $2 }' "$calls" | sort -u)
	want=$(tr ' ' '\n' <<<"$allowed" | sort -u)
	extra=""
	for site in $found; do
		ok=0
		for a in $want; do
			if [[ "$site" == "$a" || ( "$a" == *":*" && "${site%%:*}" == "${a%%:*}" ) ]]; then
				ok=1
				break
			fi
		done
		[[ $ok -eq 0 ]] && extra="$extra $site"
	done
	missing=""
	if [[ "$kind" == "=" ]]; then
		for a in $want; do
			grep -qxF "$a" <<<"$found" || missing="$missing $a"
		done
	fi
	if [[ -n "$extra$missing" ]]; then
		echo "$token: not audited:${extra:- -}; audited site missing:${missing:- -}"
		bad=1
	fi
done
exit $bad
