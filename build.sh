#!/usr/bin/env bash
# Раскрутка компилятора Khrip из исходников, без Go, C и других компиляторов:
#
#   bootstrap/khc0.asm  --nasm-->  khc0   зерно на ассемблере (понимает Khrip-0)
#   bootstrap/boot.kh   --khc0-->  boot   загрузчик на Khrip-0 (понимает подмножество Khrip-1)
#   src/*.kh            --boot-->  khc1   компилятор на Khrip-1
#   src/*.kh            --khc1-->  khc2   компилятор собирает сам себя
#   src/*.kh            --khc2-->  khc3   и ещё раз
#
# khc2 и khc3 обязаны совпасть побайтно: компилятор воспроизводит сам себя.
# Исходники компилятора — системный код (--system): строки в них — байты, и
# операции, которые в программах считают символы, — ошибки компиляции.
# Итог — build/khc; стандартная библиотека — lib/ (ищется как ../lib от khc).
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p build
nasm -f elf64 bootstrap/khc0.asm -o build/khc0.o
ld build/khc0.o -o build/khc0
build/khc0 -o build/boot bootstrap/boot.kh
build/boot -o build/khc1 bootstrap/shim.kh lib/core.kh src/*.kh
build/khc1 --system -o build/khc2 src/*.kh
build/khc2 --system -o build/khc3 src/*.kh

if ! cmp -s build/khc2 build/khc3; then
	echo "ошибка: khc2 и khc3 различаются — компилятор не воспроизводит сам себя" >&2
	exit 1
fi
cp build/khc3 build/khc

size=$(stat -c %s build/khc)
hash=$(sha256sum build/khc | cut -c1-16)
echo "ok: khc собрал сам себя, поколения совпадают ($size байт, sha256 $hash…)"
