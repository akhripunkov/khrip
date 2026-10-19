-- 90% переходов по коротким ссылкам, 10% новых ссылок.
dofile(os.getenv("LOAD_DIR") .. "/common.lua")
function request()
  if math.random() < 0.9 then
    return wrk.format("GET", "/code" .. math.random(0, 999))
  end
  return wrk.format("POST", "/links", json_headers, '{"url":"https://example.com/new/' .. math.random(1e9) .. '"}')
end
