-- 70% заказов из двух строк, 30% списка товаров.
dofile(os.getenv("LOAD_DIR") .. "/common.lua")
function request()
  if math.random() < 0.7 then
    return wrk.format("POST", "/orders", json_headers, string.format(
      '{"lines":[{"sku":"SKU-%03d","qty":%d},{"sku":"SKU-%03d","qty":%d}]}',
      math.random(0, 199), math.random(1, 5), math.random(0, 199), math.random(1, 5)))
  end
  return wrk.format("GET", "/items")
end
