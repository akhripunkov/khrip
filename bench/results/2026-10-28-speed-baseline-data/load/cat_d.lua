-- catalog, ветка 4 (10 %): категории
dofile(os.getenv("LOAD_DIR") .. "/common.lua")
function request()
  return wrk.format("GET", "/categories")
end
