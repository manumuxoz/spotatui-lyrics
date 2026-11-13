-- Test runner. Usage: lua tests/run.lua
-- No external dependencies; works with Lua 5.4 and the spotatui Lua runtime.

local root = os.getenv("SPOTATUI_LYRICS_ROOT") or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local tests = {}
local failures = 0
local assertions = 0

function test(name, fn)
  tests[#tests + 1] = { name = name, fn = fn }
end

local function format_value(value)
  if type(value) == "string" then
    return string.format("%q", value)
  end
  return tostring(value)
end

function assert_true(value, message)
  assertions = assertions + 1
  if not value then
    error(message or ("expected truthy, got " .. format_value(value)), 2)
  end
end

function assert_false(value, message)
  assertions = assertions + 1
  if value then
    error(message or ("expected falsey, got " .. format_value(value)), 2)
  end
end

function assert_eq(actual, expected, message)
  assertions = assertions + 1
  if actual ~= expected then
    error((message or "values differ") .. "\n  expected: " .. format_value(expected)
      .. "\n  actual:   " .. format_value(actual), 2)
  end
end

function assert_near(actual, expected, tolerance, message)
  assertions = assertions + 1
  tolerance = tolerance or 0.001
  if math.abs(actual - expected) > tolerance then
    error((message or "values differ") .. "\n  expected: " .. tostring(expected)
      .. "\n  actual:   " .. tostring(actual), 2)
  end
end

function assert_contains(haystack, needle, message)
  assertions = assertions + 1
  if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
    error((message or "substring not found") .. "\n  needle: " .. tostring(needle)
      .. "\n  haystack: " .. tostring(haystack), 2)
  end
end

function assert_not_nil(value, message)
  assertions = assertions + 1
  if value == nil then
    error(message or "expected a value, got nil", 2)
  end
end

function assert_nil(value, message)
  assertions = assertions + 1
  if value ~= nil then
    error((message or "expected nil") .. ", got " .. format_value(value), 2)
  end
end

local test_files = {
  "tests/test_util.lua",
  "tests/test_metadata.lua",
  "tests/test_lrc.lua",
  "tests/test_score.lua",
  "tests/test_providers.lua",
  "tests/test_engine.lua",
  "tests/test_plugin.lua",
}

for _, path in ipairs(test_files) do
  local full = root .. "/" .. path
  local chunk, err = loadfile(full)
  if not chunk then
    io.stderr:write("cannot load " .. path .. ": " .. tostring(err) .. "\n")
    failures = failures + 1
  else
    local ok, load_err = pcall(chunk)
    if not ok then
      io.stderr:write("error loading " .. path .. ": " .. tostring(load_err) .. "\n")
      failures = failures + 1
    end
  end
end

for _, case in ipairs(tests) do
  local ok, err = pcall(case.fn)
  if ok then
    io.write("ok   " .. case.name .. "\n")
  else
    failures = failures + 1
    io.write("FAIL " .. case.name .. "\n  " .. tostring(err) .. "\n")
  end
end

io.write(string.format("\n%d tests, %d assertions, %d failures\n", #tests, assertions, failures))
if failures > 0 then
  os.exit(1)
end
