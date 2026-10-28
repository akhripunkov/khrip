#!/usr/bin/env bash
# После итоговой партии: проверка 409 (Khrip против C#) и модель переходов callgrind.
set -uo pipefail
S=/tmp/claude-0/-home-user-khrip/c69287a0-5c25-565c-bc10-daebb195400d/scratchpad/sp1
R=/tmp/claude-0/-home-user-khrip/c69287a0-5c25-565c-bc10-daebb195400d/scratchpad/par/speed1
D=$R/bench/results/2026-10-28-speed-baseline-data
V=$S/var
E=$R/eval
echo "== 409: Khrip b0 против C#"
PORT=21701 $V/b0_base 2>/dev/null & P0=$!
ASPNETCORE_URLS=http://127.0.0.1:21702 Logging__LogLevel__Default=Warning dotnet $S/ab-cs-bookings/App.dll >/dev/null & P1=$!
for _ in $(seq 300); do curl -s -o /dev/null --max-time 1 http://127.0.0.1:21702/ && break; sleep 0.1; done
(cd $E && SEED_PORT=21701 python3 load/seed.py seed bookings; SEED_PORT=21702 python3 load/seed.py seed bookings)
python3 $D/conflicts.py 21701 21702 20000
python3 $V/../count_bookings.py 21701; python3 $V/../count_bookings.py 21702
kill $P0 $P1; wait $P0 $P1 2>/dev/null
echo "== переходы: b1 и b1+liby, GET при 11 000"
CG_FLAGS=--branch-sim=yes INSTR_OFF=1 $D/cg.sh $V/b1_loop.kh bookings $V/cgb_b1 fill:11000 book_get:12 2>&1 | grep -v символов
KHRIP_LIB=$S/liby CG_FLAGS=--branch-sim=yes INSTR_OFF=1 $D/cg.sh $V/b1_loop.kh bookings $V/cgb_b1y fill:11000 book_get:12 2>&1 | grep -v символов
python3 $D/cachesum.py $V/cgb_b1/cg.1.book_get 8
python3 $D/cachesum.py $V/cgb_b1y/cg.1.book_get 8
echo after-batch-finished
