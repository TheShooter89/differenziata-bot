-- Reader for the .env format: KEY=value, optional quotes, an optional `export`
-- prefix, # comments and blank lines. Deliberately dependency-free, in the same
-- spirit as toml.lua and csv.lua.
local util = require("util")

local M = {}

M.DEFAULT_ENV_PATH = ".env"
M.ENV_PATH_VARIABLE = "DIFFERENZIATA_ENV"

-- The :line suffix matches what editors and other tools expect from a parse
-- error, and the tests assert on that exact shape.
local function line_error(path, number, message)
  return string.format("%s line %d: %s", path, number, message)
end

-- A leading # in an unquoted value is a comment; inside quotes it is data. This
-- reads the quote first, because stripping comments from `"has # hash"` before
-- knowing it is quoted would truncate the value.
local function parse_value(text, path, number)
  local quote = text:sub(1, 1)
  if quote == '"' or quote == "'" then
    local body = util.trim(text)
    if #body >= 2 and body:sub(-1) == quote then
      return body:sub(2, #body - 1)
    end
    -- An opening quote with no partner on the same line is a typo worth
    -- reporting rather than silently storing a value with a stray quote in it.
    return nil, line_error(path, number, string.format("unterminated %s quote", quote))
  end
  local hash = text:find("#")
  if hash then
    text = text:sub(1, hash - 1)
  end
  return util.trim(text)
end

function M.parse(text, path)
  path = path or M.DEFAULT_ENV_PATH
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  if text:sub(1, 3) == "\239\187\191" then
    text = text:sub(4)
  end

  local values = {}
  local number = 0
  -- gmatch yields the lines directly; ipairs would be indexing the iterator
  -- function itself, and the line number has to be counted by hand anyway.
  for line in (text .. "\n"):gmatch("(.-)\n") do
    number = number + 1
    local trimmed = util.trim(line)
    if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
      -- `export KEY=value` is valid in a shell and common in hand-written .env
      -- files, so accept it even though we never run these through a shell.
      local body = trimmed:gsub("^export%s+", "", 1)
      local key, value = body:match("^([%w_%.%-]+)%s*=%s*(.*)$")
      if not key then
        return nil, line_error(path, number, "expected KEY=value")
      end
      local parsed, err = parse_value(util.trim(value), path, number)
      if parsed == nil then
        return nil, err
      end
      values[key] = parsed
    end
  end
  return values
end

-- A missing .env is not an error: the token may legitimately come from the
-- environment or from config.toml instead.
function M.load(path)
  if not util.file_exists(path) then
    return {}, nil
  end
  local text = util.read_file(path)
  if not text then
    return nil, string.format("cannot read %s", path)
  end
  return M.parse(text, path)
end

return M