#!/usr/bin/env bash
# Базы данных — с ядер сервера на время замера (этап памяти, часть 2).
#
# ClickHouse и mongod работают в контейнерах без привязки к ядрам и попадают
# на ядра сервера: ClickHouse занимает ≈ 11 % процессора и раз в несколько
# секунд держит ядро 86–220 мс одним потоком — это и были паузы зонда по
# 125–140 мс в 10-минутных прогонах. На время команды скрипт переносит
# запущенные контейнеры Docker и процессы PostgreSQL на ядра нагрузки, а потом
# возвращает прежние ядра.
#
#   bench/tools/quiet.sh [команда [аргументы...]]   на время команды
#   bench/tools/quiet.sh on                         перенести (до off)
#   bench/tools/quiet.sh off                        вернуть сохранённое
#   bench/tools/quiet.sh status                     где сейчас базы
#
# Окружение: QUIET_CPUS — ядра для баз (по умолчанию 2,3: там же нагрузка, а
# сервер — на 0,1), QUIET_CONTAINERS — какие контейнеры (по умолчанию все
# запущенные), QUIET_STATE — файл с прежними ядрами. Без Docker или без
# PostgreSQL скрипт переносит то, что есть.
set -uo pipefail

cpus=${QUIET_CPUS:-2,3}
state=${QUIET_STATE:-${TMPDIR:-/tmp}/khrip-quiet.state}
all="0-$(($(nproc) - 1))"

containers() {
	if [[ -n ${QUIET_CONTAINERS:-} ]]; then
		printf '%s\n' $QUIET_CONTAINERS
	elif command -v docker >/dev/null 2>&1; then
		docker ps --format '{{.Names}}' 2>/dev/null
	fi
}

pg_pids() {
	pgrep -x postgres 2>/dev/null
}

on() {
	if [[ -s $state ]]; then
		echo "quiet.sh: базы уже перенесены ($state); сначала off" >&2
		return 1
	fi
	: >"$state"
	local c p
	for c in $(containers); do
		printf 'container\t%s\t%s\n' "$c" "$(docker inspect -f '{{.HostConfig.CpusetCpus}}' "$c" 2>/dev/null)" >>"$state"
		docker update --cpuset-cpus "$cpus" "$c" >/dev/null || echo "quiet.sh: $c не перенесён" >&2
	done
	for p in $(pg_pids); do
		printf 'pid\t%s\t%s\n' "$p" "$(taskset -pc "$p" 2>/dev/null | awk '{print $NF}')" >>"$state"
		taskset -pc "$cpus" "$p" >/dev/null 2>&1
	done
}

off() {
	[[ -f $state ]] || return 0
	local kind name was
	while IFS=$'\t' read -r kind name was; do
		case $kind in
		container) docker update --cpuset-cpus "${was:-$all}" "$name" >/dev/null || echo "quiet.sh: $name не возвращён" >&2 ;;
		pid) [[ -d /proc/$name ]] && taskset -pc "${was:-$all}" "$name" >/dev/null 2>&1 ;;
		esac
	done <"$state"
	rm -f "$state"
}

status() {
	local c p
	for c in $(containers); do
		echo "$c: ядра [$(docker inspect -f '{{.HostConfig.CpusetCpus}}' "$c" 2>/dev/null)]"
	done
	for p in $(pg_pids); do
		echo "postgres $p: $(taskset -pc "$p" 2>/dev/null | awk '{print $NF}')"
	done
}

case ${1:-} in
on) on ;;
off) off ;;
status) status ;;
"") echo "quiet.sh: команда, on, off или status" >&2; exit 2 ;;
*)
	on || exit 1
	trap off EXIT
	trap 'exit 130' INT TERM
	"$@"
	;;
esac
