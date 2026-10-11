-- Strict JSON decoder: objects, arrays, strings (with escapes including
-- surrogate pairs), numbers, true/false/null and whitespace, with trailing
-- garbage rejected. Deliberately dependency-free, in the same spirit as
-- toml.lua, dotenv.lua and csv.lua, and used the same way: only ever through
-- the nil, message return of M.decode.
local M = {}

-- A remote payload that nests without bound must not be able to blow the Lua
-- stack and take the cron job down with it.
local MAX_DEPTH = 100

local Parser = {}
Parser.__index = Parser

function M.decode(text)
  if type(text) ~= "string" then
    return nil, "expected a string to decode"
  end
  local self = setmetatable({ text = text, pos = 1, depth = 0 }, Parser)
  local ok, err = pcall(self.run, self)
  if not ok then
    return nil, err
  end
  return self.value
end

function Parser:fail(message)
  error(message, 0)
end

function Parser:eof()
  return self.pos > #self.text
end

function Parser:peek()
  return self.text:sub(self.pos, self.pos)
end

function Parser:skip_whitespace()
  while not self:eof() do
    local char = self:peek()
    if char == " " or char == "\t" or char == "\n" or char == "\r" then
      self.pos = self.pos + 1
    else
      return
    end
  end
end

function Parser:enter()
  self.depth = self.depth + 1
  if self.depth > MAX_DEPTH then
    self:fail("nesting too deep")
  end
end

function Parser:leave()
  self.depth = self.depth - 1
end

function Parser:parse_value()
  self:skip_whitespace()
  local char = self:peek()
  if char == "{" then
    return self:parse_object()
  elseif char == "[" then
    return self:parse_array()
  elseif char == '"' then
    return self:parse_string()
  elseif self.text:sub(self.pos, self.pos + 3) == "true" then
    self.pos = self.pos + 4
    return true
  elseif self.text:sub(self.pos, self.pos + 4) == "false" then
    self.pos = self.pos + 5
    return false
  elseif self.text:sub(self.pos, self.pos + 3) == "null" then
    self.pos = self.pos + 4
    return nil
  end
  return self:parse_number()
end

function Parser:parse_object()
  self:enter()
  self.pos = self.pos + 1
  local out = {}
  self:skip_whitespace()
  if self:peek() == "}" then
    self.pos = self.pos + 1
    self:leave()
    return out
  end
  while true do
    self:skip_whitespace()
    if self:peek() ~= '"' then
      self:fail(string.format("expected an object key, got %q", self:peek()))
    end
    local key = self:parse_string()
    self:skip_whitespace()
    if self:peek() ~= ":" then
      self:fail(string.format("expected ':' after object key, got %q", self:peek()))
    end
    self.pos = self.pos + 1
    out[key] = self:parse_value()
    self:skip_whitespace()
    local char = self:peek()
    if char == "," then
      self.pos = self.pos + 1
    elseif char == "}" then
      self.pos = self.pos + 1
      self:leave()
      return out
    else
      self:fail(string.format("expected ',' or '}' in object, got %q", char))
    end
  end
end

function Parser:parse_array()
  self:enter()
  self.pos = self.pos + 1
  local out = {}
  self:skip_whitespace()
  if self:peek() == "]" then
    self.pos = self.pos + 1
    self:leave()
    return out
  end
  while true do
    out[#out + 1] = self:parse_value()
    self:skip_whitespace()
    local char = self:peek()
    if char == "," then
      self.pos = self.pos + 1
    elseif char == "]" then
      self.pos = self.pos + 1
      self:leave()
      return out
    else
      self:fail(string.format("expected ',' or ']' in array, got %q", char))
    end
  end
end

local ESCAPES = {
  ['"'] = '"',
  ["\\"] = "\\",
  ["/"] = "/",
  b = "\b",
  f = "\f",
  n = "\n",
  r = "\r",
  t = "\t",
}

function Parser:parse_hex4()
  local hex = self.text:sub(self.pos, self.pos + 3)
  if #hex ~= 4 or not hex:match("^%x%x%x%x") then
    self:fail("invalid unicode escape")
  end
  self.pos = self.pos + 4
  return tonumber(hex, 16)
end

function Parser:parse_string()
  -- self.pos sits on the opening quote.
  self.pos = self.pos + 1
  local out = {}
  while true do
    if self:eof() then
      self:fail("unterminated string")
    end
    local char = self:peek()
    if char == '"' then
      self.pos = self.pos + 1
      return table.concat(out)
    elseif char == "\\" then
      self.pos = self.pos + 1
      local esc = self:peek()
      if esc == "u" then
        self.pos = self.pos + 1
        local code = self:parse_hex4()
        if code >= 0xD800 and code <= 0xDBFF then
          -- A high surrogate is only meaningful paired with a low one.
          if self.text:sub(self.pos, self.pos + 1) ~= "\\u" then
            self:fail("high surrogate is not followed by a low surrogate")
          end
          self.pos = self.pos + 2
          local low = self:parse_hex4()
          if low < 0xDC00 or low > 0xDFFF then
            self:fail("low surrogate out of range")
          end
          out[#out + 1] = utf8.char(0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00))
        elseif code >= 0xDC00 and code <= 0xDFFF then
          self:fail("lone low surrogate")
        else
          out[#out + 1] = utf8.char(code)
        end
      elseif ESCAPES[esc] then
        out[#out + 1] = ESCAPES[esc]
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

function Parser:parse_number()
  -- Anchored finds against the whole text, not self.text:sub(self.pos): slicing
  -- the remaining body once per number copies the whole payload each time, which
  -- is quadratic on a large document.
  local start = self.pos
  local s, e = self.text:find("^%-?%d+", start)
  if not s then
    self:fail("invalid number")
  end
  local negative = self.text:sub(s, s) == "-"
  local digits = negative and self.text:sub(s + 1, e) or self.text:sub(s, e)
  if #digits > 1 and digits:sub(1, 1) == "0" then
    self:fail("invalid number")
  end
  local pos = e + 1
  local tail = self.text:sub(pos, pos)
  if tail == "." then
    local frac_start, frac_end = self.text:find("^%.%d+", pos)
    if not frac_start then
      self:fail("invalid number")
    end
    pos = frac_end + 1
    tail = self.text:sub(pos, pos)
  end
  if tail == "e" or tail == "E" then
    local exp_start, exp_end = self.text:find("^[eE][%+%-]?%d+", pos)
    if not exp_start then
      self:fail("invalid number")
    end
    pos = exp_end + 1
  end
  local text = self.text:sub(start, pos - 1)
  local value = tonumber(text)
  if not value then
    self:fail(string.format("invalid number %q", text))
  end
  self.pos = pos
  return value
end

function Parser:run()
  self:skip_whitespace()
  if self:eof() then
    self:fail("empty input")
  end
  self.value = self:parse_value()
  self:skip_whitespace()
  if not self:eof() then
    self:fail("trailing garbage after the JSON value")
  end
end

return M
