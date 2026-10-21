-- Случайные id 1..1000 на каждый запрос.
math.randomseed(os.time())
request = function()
  return wrk.format("GET", "/quote?id=" .. math.random(1, 1000))
end
