-- bookings, ветка 1 (70 %): расписание комнаты на день
dofile(os.getenv("LOAD_DIR") .. "/common.lua")
function request()
  local room, day = math.random(1, 20), math.random(1, 28)
  return wrk.format("GET", string.format("/rooms/%d/bookings?date=2026-11-%02d", room, day))
end
