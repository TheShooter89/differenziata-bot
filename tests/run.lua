local dir = (arg[0] or ""):match("^(.*)/[^/]*$") or "."
local root = dir == "tests" and "." or dir:match("^(.*)/tests$") or dir
package.path = table.concat({
  root .. "/src/?.lua",
  root .. "/tests/?.lua",
  package.path,
}, ";")

local helpers = require("helpers")

local MODULES = {
  "test_date",
  "test_toml",
  "test_dotenv",
  "test_csv",
  "test_json",
  "test_schedule",
  "test_reminders",
  "test_state",
  "test_config",
  "test_plan",
  "test_commands",
}

local passed, failed = 0, 0
local failures = {}

for _, name in ipairs(MODULES) do
  local ok, tests = pcall(require, name)
  if not ok then
    failed = failed + 1
    failures[#failures + 1] = string.format("%s: could not load: %s", name, tostring(tests))
    io.write(string.format("E%-6s %s\n", "", name))
  else
    io.write(string.format("%-12s", name))
    for _, test in ipairs(tests) do
      local success, err = pcall(test.run)
      if success then
        passed = passed + 1
        io.write(".")
      else
        failed = failed + 1
        failures[#failures + 1] = string.format("%s :: %s\n    %s", name, test.name, tostring(err))
        io.write("F")
      end
      io.flush()
    end
    io.write("\n")
  end
end

if #failures > 0 then
  io.write("\nfailures:\n")
  for _, failure in ipairs(failures) do
    io.write("  " .. failure .. "\n")
  end
end

helpers.cleanup()
io.write(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)