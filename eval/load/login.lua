-- Только вход: стоимость проверки пароля (PBKDF2).
dofile(os.getenv("LOAD_DIR") .. "/common.lua")
local body = '{"username":"bench","password":"bench-password"}'
function request()
  return wrk.format("POST", "/login", json_headers, body)
end
