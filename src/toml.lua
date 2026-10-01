-- Minimal TOML reader: tables, dotted keys, strings (basic and literal),
-- integers, floats, booleans, arrays, arrays of tables, inline tables.
-- Anything outside that surface is reported as an error instead of being
-- silently ignored, so a typo in config.toml fails loudly.
local M = {}

local ESCAPES = {
  b = "\b",
  t = "\t",
  n = "\n",
  f = "\f",
  r = "\r",
  ['"'] = '"',
  ["\\"] = "\\",
}

-- Counts newlines strictly before pos, so a position sitting on a line's own
-- newline still reports the line it terminates rather than the next one.
local function line_of(text, pos)
  local line = 1
  for i = 1, pos - 1 do
    if text:sub(i, i) == "\n" then
      line = line + 1
    end
  end
  return line
end

local function snippet(text, pos)
  local raw = text:sub(pos, pos + 7)
  raw = raw:gsub("\n", "\\n"):gsub("\t", "\\t"):gsub("\r", "\\r")
  return raw
end

local Parser = {}
Parser.__index = Parser

function M.parse(text)
  if type(text) ~= "string" then
    error("toml: expected a string to parse", 0)
  end
  local self = setmetatable({ text = text, pos = 1, root = {} }, Parser)
  local ok, err = pcall(self.run, self)
  if not ok then
    error(err, 0)
  end
  return self.root
end

function Parser:fail(message, pos)
  local at = line_of(self.text, pos or self.pos)
  error(string.format("toml: line %d: %s", at, message), 0)
end

function Parser:eof()
  return self.pos > #self.text
end

function Parser:peek(offset)
  return self.text:sub(self.pos + (offset or 0), self.pos + (offset or 0))
end

function Parser:skip_inline()
  while not self:eof() do
    local char = self:peek()
    if char == " " or char == "\t" then
      self.pos = self.pos + 1
    else
      return
    end
  end
end

function Parser:skip_to_content()
  while not self:eof() do
    local char = self:peek()
    if char == " " or char == "\t" or char == "\r" or char == "\n" then
      self.pos = self.pos + 1
    elseif char == "#" then
      while not self:eof() and self:peek() ~= "\n" do
        self.pos = self.pos + 1
      end
    else
      return
    end
  end
end

function Parser:expect(char)
  if self:peek() ~= char then
    self:fail(string.format("expected %q, got %q", char, self:peek() or "<eof>"))
  end
  self.pos = self.pos + 1
end

function Parser:expect_end_of_line()
  self:skip_inline()
  if self:eof() then
    return
  end
  local char = self:peek()
  if char == "#" then
    while not self:eof() and self:peek() ~= "\n" do
      self.pos = self.pos + 1
    end
  elseif char ~= "\n" then
    self:fail(string.format("unexpected %q at end of line", char))
  end
end

function Parser:parse_basic_string()
  self:expect('"')
  local out = {}
  while true do
    if self:eof() then
      self:fail("unterminated string")
    end
    local char = self:peek()
    if char == '"' then
      self.pos = self.pos + 1
      return table.concat(out)
    elseif char == "\n" then
      self:fail("unterminated string")
    elseif char == "\\" then
      self.pos = self.pos + 1
      local esc = self:peek()
      if esc == "u" or esc == "U" then
        local width = esc == "u" and 4 or 8
        local hex = self.text:sub(self.pos + 1, self.pos + width)
        local code = tonumber(hex, 16)
        if #hex ~= width or not code then
          self:fail("invalid unicode escape")
        end
        self.pos = self.pos + 1 + width
        out[#out + 1] = utf8.char(code)
      elseif ESCAPES[esc] then
        out[#out + 1] = ESCAPES[esc]
        -- pos already sits on the escape letter, so one more step consumes it.
        self.pos = self.pos + 1
      else
        self:fail(string.format("unknown escape %q", "\\" .. tostring(esc)))
      end
    else
      out[#out + 1] = char
      self.pos = self.pos + 1
    end
  end
end

function Parser:parse_literal_string()
  self:expect("'")
  local start = self.pos
  local stop = self.text:find("'", start, true)
  if not stop then
    self:fail("unterminated literal string")
  end
  local value = self.text:sub(start, stop - 1)
  self.pos = stop + 1
  return value
end

local BARE_KEY = "^[%a_][%w_%-]*$"

function Parser:parse_key_part()
  local char = self:peek()
  if char == '"' then
    return self:parse_basic_string()
  elseif char == "'" then
    return self:parse_literal_string()
  end
  local bare = self.text:match("^[%a_][%w_%-]*", self.pos)
  if not bare then
    self:fail(string.format("invalid key near %q", snippet(self.text, self.pos)))
  end
  if not bare:match(BARE_KEY) then
    self:fail(string.format("invalid key %q", bare))
  end
  self.pos = self.pos + #bare
  return bare
end

function Parser:parse_key_path()
  local parts = { self:parse_key_part() }
  while true do
    self:skip_inline()
    if self:peek() ~= "." then
      return parts
    end
    self.pos = self.pos + 1
    self:skip_inline()
    parts[#parts + 1] = self:parse_key_part()
  end
end

function Parser:parse_number()
  local rest = self.text:sub(self.pos)
  local hex = rest:match("^0[xX](%x+)")
  if hex then
    self.pos = self.pos + #("0x" .. hex)
    return tonumber(hex, 16)
  end
  local int = rest:match("^[+-]?%d+")
  if not int then
    return nil
  end
  local float = rest:match("^[+-]?%d+%.%d+")
  local exponent = rest:match("^[+-]?%d+%.?%d*[eE][+-]?%d+")
  local text = float or exponent or int
  self.pos = self.pos + #text
  local value = tonumber(text)
  if not value then
    self:fail(string.format("invalid number %q", text))
  end
  return value
end

function Parser:parse_value()
  self:skip_inline()
  local char = self:peek()
  if char == '"' then
    return self:parse_basic_string()
  elseif char == "'" then
    return self:parse_literal_string()
  elseif char == "[" then
    return self:parse_array()
  elseif char == "{" then
    return self:parse_inline_table()
  end
  if self.text:sub(self.pos, self.pos + 3) == "true" then
    self.pos = self.pos + 4
    return true
  end
  if self.text:sub(self.pos, self.pos + 4) == "false" then
    self.pos = self.pos + 5
    return false
  end
  local number = self:parse_number()
  if number then
    return number
  end
  self:fail(string.format("unexpected value near %q", snippet(self.text, self.pos)))
end

function Parser:parse_array()
  self:expect("[")
  local out = {}
  while true do
    self:skip_to_content()
    if self:peek() == "]" then
      self.pos = self.pos + 1
      return out
    end
    out[#out + 1] = self:parse_value()
    self:skip_to_content()
    local char = self:peek()
    if char == "," then
      self.pos = self.pos + 1
    elseif char == "]" then
      self.pos = self.pos + 1
      return out
    else
      self:fail("expected ',' or ']' in array")
    end
  end
end

function Parser:parse_inline_table()
  self:expect("{")
  local out = {}
  self:skip_inline()
  if self:peek() == "}" then
    self.pos = self.pos + 1
    return out
  end
  while true do
    self:skip_inline()
    local path = self:parse_key_path()
    self:skip_inline()
    self:expect("=")
    local target = out
    for i = 1, #path - 1 do
      target[path[i]] = target[path[i]] or {}
      target = target[path[i]]
    end
    target[path[#path]] = self:parse_value()
    self:skip_inline()
    local char = self:peek()
    if char == "," then
      self.pos = self.pos + 1
    elseif char == "}" then
      self.pos = self.pos + 1
      return out
    else
      self:fail("expected ',' or '}' in inline table")
    end
  end
end

local function is_array_table(value)
  return type(value) == "table" and value.__array ~= nil
end

local function mark_array(value)
  value.__array = true
  return value
end

function Parser:descend(root, path, create)
  local node = root
  for i = 1, #path - 1 do
    local key = path[i]
    if node[key] == nil then
      if not create then
        self:fail(string.format("undefined table %q", table.concat(path, ".")))
      end
      node[key] = {}
    elseif type(node[key]) ~= "table" or is_array_table(node[key]) then
      self:fail(string.format("%q is not a table", table.concat(path, ".", 1, i)))
    end
    node = node[key]
  end
  return node
end

function Parser:assign(root, path, value)
  local node = self:descend(root, path, true)
  local key = path[#path]
  if node[key] ~= nil then
    self:fail(string.format("duplicate key %q", table.concat(path, ".")))
  end
  node[key] = value
end

function Parser:run()
  local root = self.root
  local current = root
  while true do
    self:skip_to_content()
    if self:eof() then
      return
    end
    if self:peek() == "[" then
      local array_of_tables = self.text:sub(self.pos, self.pos + 1) == "[["
      self.pos = self.pos + (array_of_tables and 2 or 1)
      local path = self:parse_key_path()
      self:skip_inline()
      if array_of_tables then
        self:expect("]")
        self:expect("]")
      else
        self:expect("]")
      end
      if path[#path] == "" then
        self:fail("empty table name")
      end
      self:expect_end_of_line()
      local parent = self:descend(root, path, true)
      local key = path[#path]
      if array_of_tables then
        if parent[key] == nil then
          parent[key] = mark_array({})
        elseif not is_array_table(parent[key]) then
          self:fail(string.format("%q is not an array of tables", table.concat(path, ".")))
        end
        local entry = {}
        parent[key][#parent[key] + 1] = entry
        current = entry
      else
        if parent[key] ~= nil then
          self:fail(string.format("duplicate table %q", table.concat(path, ".")))
        end
        parent[key] = {}
        current = parent[key]
      end
    else
      local path = self:parse_key_path()
      self:skip_inline()
      self:expect("=")
      local value = self:parse_value()
      self:assign(current, path, value)
      self:expect_end_of_line()
    end
  end
end

function M.load(path)
  local handle, open_error = io.open(path, "rb")
  if not handle then
    return nil, string.format("cannot open %s: %s", path, open_error)
  end
  local text = handle:read("a")
  handle:close()
  if not text then
    return nil, string.format("cannot read %s", path)
  end
  if text:sub(1, 3) == "\239\187\191" then
    text = text:sub(4)
  end
  local ok, result = pcall(M.parse, text)
  if not ok then
    return nil, result
  end
  return result
end

return M