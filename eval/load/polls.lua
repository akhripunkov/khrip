-- 60% голосов новых участников, 30% результатов, 10% опросов.
dofile(os.getenv("LOAD_DIR") .. "/common.lua")
local prefix = nil
function request()
  prefix = prefix or ("v" .. math.random(1, 1e9) .. "-")
  local poll = math.random(1, 100)
  local r = math.random()
  if r < 0.6 then
    return wrk.format("POST", "/polls/" .. poll .. "/votes",
      { ["Content-Type"] = "application/json", ["X-Voter-Id"] = prefix .. next_id() },
      '{"option":' .. math.random(0, 4) .. '}')
  elseif r < 0.9 then
    return wrk.format("GET", "/polls/" .. poll .. "/results")
  end
  return wrk.format("GET", "/polls/" .. poll)
end
