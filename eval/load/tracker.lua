-- 40% чтений задачи, 20% изменений, 20% новых задач (нумерация без пропусков),
-- 20% сводки проекта.
dofile(os.getenv("LOAD_DIR") .. "/common.lua")
local projects = { "API", "WEB", "OPS", "DATA", "MOB" }
local statuses = { "open", "in_progress", "done" }
function request()
  local p = projects[math.random(1, 5)]
  local r = math.random()
  if r < 0.4 then
    return wrk.format("GET", "/issues/" .. p .. "-" .. math.random(1, 200))
  end
  if r < 0.6 then
    return wrk.format("PATCH", "/issues/" .. p .. "-" .. math.random(1, 200), json_headers,
      '{"status":"' .. statuses[math.random(1, 3)] .. '","assignee_id":' .. math.random(1, 50) .. '}')
  end
  if r < 0.8 then
    return wrk.format("POST", "/projects/" .. p .. "/issues", json_headers,
      '{"title":"Load issue ' .. math.random(1, 1000000) .. '","priority":"high"}')
  end
  return wrk.format("GET", "/projects/" .. p .. "/summary")
end
