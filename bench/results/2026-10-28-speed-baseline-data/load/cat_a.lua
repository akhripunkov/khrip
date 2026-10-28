-- catalog, ветка 1 (50 % смеси): категория, сортировка, страница по 20
dofile(os.getenv("LOAD_DIR") .. "/common.lua")
local sorts = { "price", "-price", "name" }
function request()
  return wrk.format("GET", "/products?category=cat" .. math.random(0, 19) .. "&sort=" .. sorts[math.random(3)] ..
    "&page=" .. math.random(1, 3) .. "&per_page=20")
end
