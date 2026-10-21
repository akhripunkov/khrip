# Сборка и запуск решения; подключается из run.sh и perf.sh.
#   build_solution <язык> <папка решения> <папка сборки>
#   start_solution <язык> <папка решения> <папка сборки> [порт]  → $pid
#   wait_up [порт]  — ждать, пока сервер (по умолчанию :8080) ответит хоть что-нибудь
#   db_reset <задача>  — пустая база eval_<задача> → $DATABASE_URL
# PIN — префикс команды запуска (например, «taskset -c 0,1»).
# Для языка other сервер запускает команда из START.

PIN=${PIN:-}
eval_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Как сервер настроили бы для работы: C# без журнала каждого запроса
# (appsettings.json из шаблона), Python с uvloop и httptools (uvicorn[standard]).
export ASPNETCORE_URLS=http://127.0.0.1:8080 Logging__LogLevel__Default=Warning

build_solution() {
	local lang=$1 dir=$2 out=$3
	case $lang in
	khrip) "$eval_root/build/khc" -o "$out/server" "$dir/main.kh" ;;
	go) (cd "$dir" && go build -o "$out/server" .) ;;
	csharp) dotnet publish "$dir" -c Release -o "$out/cs" --nologo -v q >/dev/null ;;
	*) true ;;
	esac
}

start_solution() {
	local lang=$1 dir=$2 out=$3 port=${4:-8080}
	case $lang in
	khrip) PORT=$port $PIN "$out/server" 2>>"$out/log" & ;;
	go) PORT=$port $PIN "$out/server" & ;;
	csharp) ASPNETCORE_URLS=http://127.0.0.1:$port $PIN dotnet "$out/cs/$(basename "$(ls "$dir"/*.csproj)" .csproj).dll" >/dev/null & ;;
	python) (cd "$dir" && exec $PIN python3 -m uvicorn main:app --port "$port" --log-level error) & ;;
	*) (cd "$dir" && PORT=$port exec $PIN bash -c "$START") & ;;
	esac
	pid=$!
}

wait_up() {
	local i port=${1:-8080}
	for i in $(seq 3000); do
		curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$port/" && return 0
		kill -0 "$pid" 2>/dev/null || return 1
		sleep 0.002
	done
	return 1
}

port_busy() {
	curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${1:-8080}/"
}

# Задачи с базой (файл tasks/<задача>/db): PostgreSQL из EVAL_PG (адрес
# служебной базы), для решения — новая пустая база eval_<задача>.
EVAL_PG=${EVAL_PG:-postgres://postgres:khrip@127.0.0.1:5432/postgres?sslmode=disable}
PSQL=${PSQL:-$(command -v psql || ls /usr/lib/postgresql/*/bin/psql 2>/dev/null | sort -V | tail -1)}

db_reset() {
	local name=eval_$1
	"$PSQL" -q "$EVAL_PG" -c "set client_min_messages = warning" -c "drop database if exists $name with (force)" -c "create database $name" >/dev/null || return 1
	local base=${EVAL_PG%%\?*}
	export DATABASE_URL=${base%/*}/$name?sslmode=disable
}
