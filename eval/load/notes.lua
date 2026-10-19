-- 90% чтений своей заметки, 10% новых заметок; запросы с токеном.
dofile(os.getenv("LOAD_DIR") .. "/common.lua")
local auth = { ["Content-Type"] = "application/json", ["Authorization"] = "Bearer " .. os.getenv("TOKEN") }
function request()
  if math.random() < 0.9 then
    return wrk.format("GET", "/notes/" .. math.random(1, 50), auth)
  end
  return wrk.format("POST", "/notes", auth, '{"title":"load","text":"written under load"}')
end
