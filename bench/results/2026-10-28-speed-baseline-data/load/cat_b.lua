-- catalog, ветка 2 (30 %): поиск по слову, цена от и до, сортировка по цене
dofile(os.getenv("LOAD_DIR") .. "/common.lua")
local words = { "apple", "steel", "green", "pro", "mini", "ultra", "classic", "smart", "eco", "max" }
function request()
  local lo = math.random(1, 400)
  return wrk.format("GET", "/products?q=" .. words[math.random(#words)] .. "&min_price=" .. lo ..
    "&max_price=" .. (lo + 100) .. "&sort=price")
end
