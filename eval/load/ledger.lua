-- 70% переводов между случайными счетами, 20% чтений счёта, 10% истории.
dofile(os.getenv("LOAD_DIR") .. "/common.lua")
function request()
  local a = math.random(1, 100)
  local r = math.random()
  if r < 0.7 then
    local b = math.random(1, 99)
    if b >= a then b = b + 1 end
    return wrk.format("POST", "/transfers", json_headers,
      '{"from":' .. a .. ',"to":' .. b .. ',"amount":' .. math.random(1, 1000) .. '}')
  end
  if r < 0.9 then
    return wrk.format("GET", "/accounts/" .. a)
  end
  return wrk.format("GET", "/accounts/" .. a .. "/transfers?limit=20")
end
