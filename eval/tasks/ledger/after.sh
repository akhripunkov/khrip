#!/usr/bin/env bash
# После перезапуска: данные в базе. $STATE — номера из check.sh.
. "$(dirname "$0")/../../lib.sh"
read -r a b t3 <"$STATE"
check "kept account" 200 "\"id\":$a && \"owner\":\"ann\" && \"balance\":750" $U/accounts/$a
check "kept history" 200 '' "$U/accounts/$a/transfers?limit=1"
jtest "kept newest" "[t['id'] for t in j] == [$t3]"
check "kept key" 201 "\"id\":$t3" "${J[@]}" -H 'Idempotency-Key: k-1' -X POST $U/transfers -d "{\"from\":$a,\"to\":$b,\"amount\":50}"
check "kept stats" 200 '' $U/stats
jtest "kept totals" "j['accounts'] == 5 and j['balances']['GBP'] == 600"
finish
