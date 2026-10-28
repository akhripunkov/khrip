-- bookings, ветка 2 (30 %): попытка брони (при заполненном store — почти всегда 409)
dofile(os.getenv("LOAD_DIR") .. "/common.lua")
function request()
  local room, day = math.random(1, 20), math.random(1, 28)
  local hour = math.random(0, 21)
  return wrk.format("POST", "/bookings", json_headers, string.format(
    '{"room_id":%d,"title":"Load","start":"2026-11-%02dT%02d:30:00Z","end":"2026-11-%02dT%02d:30:00Z"}',
    room, day, hour, day, hour + 1))
end
