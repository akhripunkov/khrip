#!/usr/bin/env bash
# Раскрутка компилятора Khrip из исходников, без Go, C и других компиляторов:
#
#   bootstrap/khc0.asm --nasm--> khc0       зерно на ассемблере
#   src/khc.kh         --khc0--> khc1       компилятор на Khrip, собранный зерном
#   src/khc.kh         --khc1--> khc2       компилятор собирает сам себя
#   src/khc.kh         --khc2--> khc3       и ещё раз
#
# khc2 и khc3 обязаны совпасть побайтно: это доказывает, что компилятор
# воспроизводит сам себя. Итог — build/khc.
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p build
nasm -f elf64 bootstrap/khc0.asm -o build/khc0.o
ld build/khc0.o -o build/khc0

build/khc0 -o build/khc1 src/khc.kh
build/khc1 -o build/khc2 src/khc.kh
build/khc2 -o build/khc3 src/khc.kh

if ! cmp -s build/khc2 build/khc3; then
	echo "ошибка: khc2 и khc3 различаются — компилятор не воспроизводит сам себя" >&2
	exit 1
fi
cp build/khc3 build/khc

size=$(stat -c %s build/khc)
hash=$(sha256sum build/khc | cut -c1-16)
echo "ok: khc собрал сам себя, поколения совпадают ($size байт, sha256 $hash…)"
