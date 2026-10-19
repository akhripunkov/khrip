# Сборка и запуск решения; подключается из run.sh и perf.sh.
#   build_solution <язык> <папка решения> <папка сборки>
#   start_solution <язык> <папка решения> <папка сборки>  → $pid
#   wait_up  — ждать, пока сервер на :8080 ответит хоть что-нибудь
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
	local lang=$1 dir=$2 out=$3
	case $lang in
	khrip) $PIN "$out/server" 2>"$out/log" & ;;
	go) $PIN "$out/server" & ;;
	csharp) $PIN dotnet "$out/cs/$(basename "$(ls "$dir"/*.csproj)" .csproj).dll" >/dev/null & ;;
	python) (cd "$dir" && exec $PIN python3 -m uvicorn main:app --port 8080 --log-level error) & ;;
	*) (cd "$dir" && exec $PIN bash -c "$START") & ;;
	esac
	pid=$!
}

wait_up() {
	local i
	for i in $(seq 3000); do
		curl -s -o /dev/null --max-time 1 http://127.0.0.1:8080/ && return 0
		kill -0 "$pid" 2>/dev/null || return 1
		sleep 0.002
	done
	return 1
}

port_busy() {
	curl -s -o /dev/null --max-time 1 http://127.0.0.1:8080/
}
