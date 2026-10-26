#!/usr/bin/env python3
"""Строки stdin — в stdout с временем прихода: «мс CLOCK_MONOTONIC<TAB>строка»
(журнал сборщика Khrip, GODEBUG=gctrace=1 у Go; bench/mem/long.sh)."""
import sys
import time

for line in sys.stdin:
    sys.stdout.write(f"{time.monotonic() * 1000:.1f}\t{line}")
    sys.stdout.flush()
