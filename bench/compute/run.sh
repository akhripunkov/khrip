#!/usr/bin/env bash
# Скорость вычислений: одинаковые задачи на Khrip, Go и C# (JIT и Native AOT).
# Время — от запуска процесса до выхода, лучшее из RUNS прогонов; проверяется,
# что все печатают одинаковый ответ.
set -euo pipefail
cd "$(dirname "$0")"
RUNS=${RUNS:-5}
B=build
mkdir -p "$B"

(cd ../.. && ./build.sh >/dev/null && build/khc -o bench/compute/$B/khrip bench/compute/khrip/compute.kh)
(cd go && go build -o "../$B/go" .)
dotnet publish csharp -c Release -o "$B/csharp" --nologo -v q >/dev/null
dotnet publish csharp -c Release -p:PublishAot=true -o "$B/csharp-aot" --nologo -v q >/dev/null

best_ms() {
	local best=999999999 out start end ms i
	for i in $(seq "$RUNS"); do
		start=$(date +%s%N)
		out=$("$@")
		end=$(date +%s%N)
		ms=$(( (end - start) / 1000000 ))
		(( ms < best )) && best=$ms
	done
	echo "$best $out"
}

echo "| Задача | Khrip | Go 1.24 | C# .NET 10 (JIT) | C# .NET 10 (AOT) | Ответ |"
echo "|---|---:|---:|---:|---:|---:|"
for task in fib sieve; do
	read -r k ka <<<"$(best_ms taskset -c 0 "$B/khrip" "$task")"
	read -r g ga <<<"$(best_ms taskset -c 0 "$B/go" "$task")"
	read -r c ca <<<"$(best_ms taskset -c 0 "$B/csharp/Compute" "$task")"
	read -r a aa <<<"$(best_ms taskset -c 0 "$B/csharp-aot/Compute" "$task")"
	if [[ "$ka" != "$ga" || "$ka" != "$ca" || "$ka" != "$aa" ]]; then
		echo "ответы различаются на $task: $ka $ga $ca $aa" >&2
		exit 1
	fi
	echo "| $task | $k мс | $g мс | $c мс | $a мс | $ka |"
done
