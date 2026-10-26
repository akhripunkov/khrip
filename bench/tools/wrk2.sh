#!/usr/bin/env bash
# wrk2 (github.com/giltene/wrk2) — нагрузка с постоянной частотой запросов
# (-R) и задержками с поправкой на координированное упущение. Собирается со
# своим LuaJIT в кэше вне репозитория; печатает путь к бинарнику.
#
#   bench/tools/wrk2.sh            — собрать, если ещё нет, и напечатать путь
#   WRK2_CACHE=<папка>             — где держать исходники и бинарник
#                                    (по умолчанию ~/.cache/khrip/wrk2-<коммит>)
#
# Бинарник в репозиторий не попадает. Сценарии eval/load/*.lua работают и под
# wrk2: он поддерживает тот же Lua API (setup, init, request, response, done).
#
# Правка ae.c (суффикс -ae1 у папки кэша): если ближайший таймер цикла событий
# уже просрочен, ae вычислял ожидание epoll как «1000 − просрочка» мс (обнулял
# только секунды) — поток wrk2, у которого ни одного запроса в полёте, спал ≈ 1 с,
# а поправка на координированное упущение записывала это в задержки сервера
# (bench/results/2026-10-26-memory-long.md, «Паузы»). Теперь просроченный таймер —
# ожидание 0.
set -euo pipefail

WRK2_REPO=${WRK2_REPO:-https://github.com/giltene/wrk2}
WRK2_COMMIT=44a94c17d8e6a0bac8559b53da76848e430cb7a7
cache=${WRK2_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/khrip/wrk2-${WRK2_COMMIT:0:12}-ae1}
bin=$cache/wrk

if [[ -x $bin ]]; then
	echo "$bin"
	exit 0
fi

mkdir -p "$cache"
src=$cache/src
if [[ ! -d $src/.git ]]; then
	rm -rf "${src:?}"
	git init -q "$src"
	git -C "$src" remote add origin "$WRK2_REPO"
fi
# сеть может оборваться: три попытки с паузой
for delay in 2 4 8 0; do
	if git -C "$src" fetch -q --depth 1 origin "$WRK2_COMMIT"; then
		break
	fi
	[[ $delay == 0 ]] && { echo "wrk2: не удалось скачать $WRK2_COMMIT" >&2; exit 1; }
	sleep "$delay"
done
git -C "$src" -c advice.detachedHead=false checkout -q --force "$WRK2_COMMIT"
[[ $(git -C "$src" rev-parse HEAD) == "$WRK2_COMMIT" ]] || { echo "wrk2: не тот коммит" >&2; exit 1; }

# просроченный таймер — ожидание 0, а не «1000 − просрочка» мс
fix='if (tvp->tv_sec < 0) { tvp->tv_sec = 0; tvp->tv_usec = 0; }'
if ! grep -qF "$fix" "$src/src/ae.c"; then
	sed -i 's/if (tvp->tv_sec < 0) tvp->tv_sec = 0;/'"$fix"'/' "$src/src/ae.c"
	grep -qF "$fix" "$src/src/ae.c" || { echo "wrk2: правка ae.c не применилась" >&2; exit 1; }
fi

# сборка: свой LuaJIT из deps/, OpenSSL системы; вывод — в журнал
log=$cache/build.log
if ! make -C "$src" -j"$(nproc)" >"$log" 2>&1; then
	tail -30 "$log" >&2
	echo "wrk2: сборка не удалась (журнал: $log)" >&2
	exit 1
fi
cp "$src/wrk" "$bin"
echo "$bin"
