#!/usr/bin/env bash
# Собрать, запустить и проверить решение:
#   eval/run.sh <задача> <язык> [папка решения]
# Язык: khrip (main.kh), go (модуль), csharp (проект), python (main.py, FastAPI app);
# для любого другого языка — START="команда запуска" eval/run.sh <задача> other <папка>.
# Папка по умолчанию — eval/solutions/<задача>/<язык>. Сервер слушает порт 8080.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/server.sh"
task=$1
lang=$2
dir=$(cd "${3:-$here/solutions/$task/$lang}" && pwd) || exit 2
tmp=$(mktemp -d)
pid=
pid2=
trap '[[ -n $pid ]] && kill $pid 2>/dev/null; [[ -n $pid2 ]] && kill $pid2 2>/dev/null; wait 2>/dev/null; rm -rf "$tmp"' EXIT

# EVAL_PORT — другой порт (и следующий за ним для второй копии), чтобы
# проверять несколько решений одновременно.
port=${EVAL_PORT:-8080}
export U=http://127.0.0.1:$port
if port_busy "$port"; then
	echo "порт $port уже занят" >&2
	exit 2
fi
export WINDOW_SECONDS=2
build_solution "$lang" "$dir" "$tmp" || exit 2

# Задача с базой: пустая база, две копии сервера на 8080 и 8081 — состояние
# должно жить в базе, а не в памяти процесса; после проверок сервер
# перезапускается, и after.sh проверяет, что данные сохранились.
db=0
if [[ -f "$here/tasks/$task/db" ]]; then
	db=1
	db_reset "${task}_$lang" || {
		echo "нет PostgreSQL ($EVAL_PG)" >&2
		exit 2
	}
fi
start_solution "$lang" "$dir" "$tmp" "$port"
wait_up "$port" || {
	echo "сервер не запустился" >&2
	exit 2
}
if [[ $db == 1 ]]; then
	first=$pid
	start_solution "$lang" "$dir" "$tmp" $((port + 1))
	pid2=$pid
	pid=$first
	wait_up $((port + 1)) || {
		echo "вторая копия сервера не запустилась" >&2
		exit 2
	}
	export U2=http://127.0.0.1:$((port + 1))
fi
echo "== $task / $lang"
# check.sh может оставить номера для after.sh
export STATE=$tmp/state
bash "$here/tasks/$task/check.sh"
status=$?
if [[ $db == 1 && -f "$here/tasks/$task/after.sh" ]]; then
	kill $pid $pid2 2>/dev/null
	wait $pid $pid2 2>/dev/null
	pid2=
	start_solution "$lang" "$dir" "$tmp" "$port"
	wait_up "$port" || {
		echo "сервер не запустился после перезапуска" >&2
		exit 2
	}
	echo "== после перезапуска"
	bash "$here/tasks/$task/after.sh" || status=1
fi
exit $status
