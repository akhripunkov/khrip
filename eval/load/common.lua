-- Общее для сценариев: у каждого потока wrk своё зерно случайности.
local counter = 0
local threads = 0

function setup(thread)
  threads = threads + 1
  thread:set("thread_no", threads)
end

function init(args)
  math.randomseed(os.time() * 100 + (thread_no or 0) * 7919)
end

function next_id()
  counter = counter + 1
  return counter
end

json_headers = { ["Content-Type"] = "application/json" }
