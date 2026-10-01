local M = {}

function M.count(tbl)
  local total = 0
  for _ in pairs(tbl) do
    total = total + 1
  end
  return total
end

local function stringify(value)
  if type(value) == "string" then
    return string.format("%q", value)
  end
  if type(value) == "table" then
    local parts = {}
    for key, item in pairs(value) do
      parts[#parts + 1] = string.format("%s=%s", tostring(key), stringify(item))
    end
    table.sort(parts)
    return "{" .. table.concat(parts, ", ") .. "}"
  end
  return tostring(value)
end

local function deep_equal(left, right)
  if type(left) ~= "table" or type(right) ~= "table" then
    return left == right
  end
  for key, value in pairs(left) do
    if not deep_equal(value, right[key]) then
      return false
    end
  end
  for key in pairs(right) do
    if left[key] == nil then
      return false
    end
  end
  return true
end

M.deep_equal = deep_equal

function M.eq(expected, actual, note)
  if not deep_equal(expected, actual) then
    error(string.format(
      "expected %s but got %s%s",
      stringify(expected), stringify(actual), note and (" (" .. note .. ")") or ""
    ), 2)
  end
end

function M.truthy(value, note)
  if not value then
    error("expected a truthy value, got " .. stringify(value) .. (note and (" (" .. note .. ")") or ""), 2)
  end
end

function M.falsy(value, note)
  if value then
    error("expected a falsy value, got " .. stringify(value) .. (note and (" (" .. note .. ")") or ""), 2)
  end
end

-- Plain substring search. Lua patterns are not accepted here on purpose: error
-- messages contain characters like '-' that are pattern magic, and a literal
-- substring assertion is what these tests actually mean.
function M.matches(needle, text, note)
  if type(text) ~= "string" or not text:find(needle, 1, true) then
    error(string.format(
      "expected %s to contain %q%s", stringify(text), needle, note and (" (" .. note .. ")") or ""
    ), 2)
  end
end

function M.errors(fn, expected_pattern, note)
  local ok, err = pcall(fn)
  if ok then
    error("expected an error, but the call succeeded" .. (note and (" (" .. note .. ")") or ""), 2)
  end
  if expected_pattern and not tostring(err):find(expected_pattern) then
    error(string.format(
      "expected error to match %q, got %q", expected_pattern, tostring(err)
    ), 2)
  end
  return err
end

local counter = 0
local created = {}

-- Every scratch path is remembered so cleanup can remove it. Without this the
-- suite leaves hundreds of files behind in /tmp on every run.
local function scratch(suffix)
  counter = counter + 1
  local path = string.format(
    "%s/differenziata-test-%d-%d%s",
    os.getenv("TMPDIR") or "/tmp", os.time() % 100000, counter, suffix or ""
  )
  created[#created + 1] = path
  return path
end

function M.tmp_file(contents, suffix)
  local path = scratch(suffix)
  local handle = assert(io.open(path, "wb"))
  handle:write(contents)
  handle:close()
  return path
end

function M.read(path)
  local handle = assert(io.open(path, "rb"))
  local text = handle:read("a")
  handle:close()
  return text
end

-- A scratch directory for tests that need more than one file side by side, which
-- is how the .env-beside-config resolution gets exercised.
function M.tmp_dir()
  local path = scratch(".d")
  os.execute(string.format("mkdir -p %q", path))
  return path
end

function M.write(path, contents)
  local handle = assert(io.open(path, "wb"))
  handle:write(contents)
  handle:close()
  return path
end

function M.cleanup()
  for _, path in ipairs(created) do
    os.execute(string.format("rm -rf %q", path))
  end
  created = {}
end

return M