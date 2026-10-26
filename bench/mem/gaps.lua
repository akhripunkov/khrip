-- Обёртка сценария eval/load для wrk2 (bench/mem/long.sh): щели в отправке
-- запросов у каждого потока wrk2. Поток шлёт следующий запрос соединения
-- только после ответа на прошлый, поэтому щель дольше GAPS_MS у потока с
-- десятками соединений — это либо пауза сервера (не отвечает никому), либо
-- пауза самого wrk2. Строки «мс CLOCK_MONOTONIC начала щели<TAB>длина, мс» —
-- в GAPS_OUT.<номер потока>; сценарий — GAPS_SCENARIO.
local ffi = require("ffi")
ffi.cdef [[
typedef struct { long tv_sec; long tv_nsec; } gaps_timespec;
int clock_gettime(int clk, gaps_timespec *ts);
]]
local ts = ffi.new("gaps_timespec")
local function now()
  ffi.C.clock_gettime(1, ts)
  return tonumber(ts.tv_sec) * 1000 + tonumber(ts.tv_nsec) / 1e6
end

dofile(os.getenv("GAPS_SCENARIO"))
local inner_request, inner_init = request, init
local limit = tonumber(os.getenv("GAPS_MS") or "50")
local out, last

function init(args)
  if inner_init then inner_init(args) end
  out = io.open((os.getenv("GAPS_OUT") or "/dev/null") .. "." .. tostring(thread_no or 0), "a")
end

function request()
  local t = now()
  if last and t - last > limit then
    out:write(string.format("%.1f\t%.1f\n", last, t - last))
    out:flush()
  end
  last = t
  return inner_request()
end
