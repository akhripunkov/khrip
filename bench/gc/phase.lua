-- bench/gc/phase.sh: замены по CHURN_N записей с разных мест store.
local n = tonumber(os.getenv("CHURN_N") or "1000")
local total = tonumber(os.getenv("CHURN_TOTAL") or "2000000")
local counter = 0
function request()
  counter = counter + 1
  return wrk.format("POST", "/churn/" .. ((counter * 7919 * n) % total) .. "/" .. n)
end
