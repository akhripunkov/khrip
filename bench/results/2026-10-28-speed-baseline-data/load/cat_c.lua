-- catalog, ветка 3 (10 %): карточка товара
dofile(os.getenv("LOAD_DIR") .. "/common.lua")
function request()
  return wrk.format("GET", "/products/" .. math.random(1, 2000))
end
