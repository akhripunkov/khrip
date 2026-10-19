-- 80% переводов между случайными счетами, 20% чтений счёта.
dofile(os.getenv("LOAD_DIR") .. "/common.lua")
function request()
  local a = math.random(1, 100)
  if math.random() < 0.8 then
    local b = math.random(1, 99)
    if b >= a then b = b + 1 end
    return wrk.format("POST", "/transfers", json_headers,
      '{"from_id":' .. a .. ',"to_id":' .. b .. ',"amount":' .. math.random(1, 1000) .. '}')
  end
  return wrk.format("GET", "/accounts/" .. a)
end
