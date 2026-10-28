-- bookings.lua с подсчётом ответов по коду: сколько 201, 409 и прочих у POST и GET
dofile(os.getenv("LOAD_DIR") .. "/common.lua")
local threads_list = {}
local base_setup = setup
function setup(thread)
  base_setup(thread)
  table.insert(threads_list, thread)
end
local last_post = false
local counts = {}
function request()
  local room, day = math.random(1, 20), math.random(1, 28)
  if math.random() < 0.7 then
    last_post = false
    return wrk.format("GET", string.format("/rooms/%d/bookings?date=2026-11-%02d", room, day))
  end
  last_post = true
  local hour = math.random(0, 21)
  return wrk.format("POST", "/bookings", json_headers, string.format(
    '{"room_id":%d,"title":"Load","start":"2026-11-%02dT%02d:30:00Z","end":"2026-11-%02dT%02d:30:00Z"}',
    room, day, hour, day, hour + 1))
end
function response(status, headers, body)
  local k = tostring(status)
  counts[k] = (counts[k] or 0) + 1
  st = ""
  for key, v in pairs(counts) do st = st .. key .. "=" .. v .. " " end
end
function done(summary, latency, requests)
  for _, t in ipairs(threads_list) do
    io.write("поток: " .. tostring(t:get("st")) .. "\n")
  end
end
