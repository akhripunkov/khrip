-- Только обновления: новое имя и цена у случайного из 2000 товаров. Данных не
-- прибавляется — видно, возвращает ли сервер память от старых значений.
dofile(os.getenv("LOAD_DIR") .. "/common.lua")
function request()
  return wrk.format("PATCH", "/products/" .. math.random(1, 2000), json_headers,
    '{"name":"Renamed product ' .. math.random(1e9) .. '","price":' .. math.random(1, 500) .. '.5}')
end
