#!/usr/bin/env bash
# cgslope.sh <tree> <scenario> [warm secs] [secs] [port] -> user instructions per request
# (callgrind, THREADS=1): after seeding, a warm-up run, then a measured run whose
# counters are dumped on their own (callgrind_control -d zeroes them)
S=/tmp/claude-0/-home-user-khrip/c69287a0-5c25-565c-bc10-daebb195400d/scratchpad/par
T=$1; sc=$2; warm=${3:-5}; secs=${4:-15}; port=${5:-21480}
task=$sc; [[ $sc == patch ]] && task=catalog; [[ $sc == login ]] && task=notes
D=$S/m3data/cg/slope-$(basename $T)-$sc-$$
mkdir -p $D
$T/build/khc -o $D/server $T/eval/solutions/$task/khrip/main.kh || exit 1
PORT=$port THREADS=1 valgrind --tool=callgrind --callgrind-out-file=$D/run.%p $D/server 2>/dev/null &
P=$!
for i in $(seq 300); do curl -s -o /dev/null --max-time 1 http://127.0.0.1:$port/ && break; sleep 0.1; done
(cd $T/eval && SEED_PORT=$port python3 load/seed.py seed $sc >/dev/null)
run() { (cd $T/eval && LOAD_DIR=$T/eval/load WINDOW_SECONDS=1 taskset -c 2,3 wrk -t2 -c64 -d${1}s -s load/$sc.lua http://127.0.0.1:$port 2>&1) | awk '/requests in/ {print $1}'; }
run $warm >/dev/null
callgrind_control -d $P >/dev/null 2>&1
reqs=$(run $secs)
callgrind_control -d $P >/dev/null 2>&1
sleep 1
kill $P; wait $P 2>/dev/null
f=$(ls -t $D/run.*.2 2>/dev/null | head -1)
ir=$(grep -h '^totals:' $f | awk '{print $2}')
echo "$(basename $T) $sc reqs $reqs ir/req $((ir / reqs))"
rm -rf "${D:?}"
