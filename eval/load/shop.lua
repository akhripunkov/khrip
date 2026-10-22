-- 40% поиска с фильтрами и сортировкой, 30% карточек товара, 25% заказов,
-- 5% сводки по категориям.
dofile(os.getenv("LOAD_DIR") .. "/common.lua")
local sorts = { "price", "-price", "name" }
local tags = { "apple", "steel", "green", "pro", "mini", "ultra", "classic", "smart", "eco", "max" }
function request()
  local r = math.random()
  if r < 0.4 then
    local q = "/products?category_id=" .. math.random(1, 10) .. "&sort=" .. sorts[math.random(1, 3)]
      .. "&page=" .. math.random(1, 3)
    if math.random() < 0.5 then q = q .. "&tag=" .. tags[math.random(1, 10)] end
    return wrk.format("GET", q)
  end
  if r < 0.7 then
    return wrk.format("GET", "/products/" .. math.random(1, 500))
  end
  if r < 0.95 then
    local lines = {}
    for i = 1, math.random(1, 3) do
      lines[#lines + 1] = '{"product_id":' .. math.random(1, 500) .. ',"qty":' .. math.random(1, 3) .. '}'
    end
    return wrk.format("POST", "/orders", json_headers,
      '{"customer":"buyer' .. math.random(1, 1000) .. '@example.com","lines":[' .. table.concat(lines, ",") .. ']}')
  end
  return wrk.format("GET", "/stats/categories")
end
