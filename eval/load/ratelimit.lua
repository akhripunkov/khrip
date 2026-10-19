-- Запросы 200 тысяч разных ключей: почти все укладываются в лимит.
dofile(os.getenv("LOAD_DIR") .. "/common.lua")
function request()
  local path = "/api/ping"
  if math.random() < 0.1 then path = "/api/time" end
  return wrk.format("GET", path, { ["X-API-Key"] = "key" .. math.random(1, 200000) })
end
