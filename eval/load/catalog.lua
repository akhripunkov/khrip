-- Поиск по 2000 товаров: фильтры, сортировки, страницы; карточка; категории.
dofile(os.getenv("LOAD_DIR") .. "/common.lua")
local words = { "apple", "steel", "green", "pro", "mini", "ultra", "classic", "smart", "eco", "max" }
local sorts = { "price", "-price", "name" }
function request()
  local r = math.random()
  if r < 0.5 then
    return wrk.format("GET", "/products?category=cat" .. math.random(0, 19) .. "&sort=" .. sorts[math.random(3)] ..
      "&page=" .. math.random(1, 3) .. "&per_page=20")
  elseif r < 0.8 then
    local lo = math.random(1, 400)
    return wrk.format("GET", "/products?q=" .. words[math.random(#words)] .. "&min_price=" .. lo ..
      "&max_price=" .. (lo + 100) .. "&sort=price")
  elseif r < 0.9 then
    return wrk.format("GET", "/products/" .. math.random(1, 2000))
  end
  return wrk.format("GET", "/categories")
end
