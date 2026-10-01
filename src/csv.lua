-- Small RFC 4180-ish reader: quoted fields, doubled quotes as escapes,
-- # comment lines, blank lines skipped, optional UTF-8 BOM.
local M = {}

local function parse_line(line)
  local fields = {}
  local index = 1
  local position = 1
  local length = #line
  while true do
    local field = {}
    local quoted = false
    while position <= length and line:sub(position, position) == " " do
      position = position + 1
    end
    if line:sub(position, position) == '"' then
      quoted = true
      position = position + 1
      while position <= length do
        local char = line:sub(position, position)
        if char == '"' then
          if line:sub(position + 1, position + 1) == '"' then
            field[#field + 1] = '"'
            position = position + 2
          else
            position = position + 1
            break
          end
        else
          field[#field + 1] = char
          position = position + 1
        end
      end
    else
      while position <= length do
        local char = line:sub(position, position)
        if char == "," then
          break
        end
        field[#field + 1] = char
        position = position + 1
      end
    end
    fields[index] = (table.concat(field):gsub("%s+$", ""))
    index = index + 1
    if line:sub(position, position) == "," then
      position = position + 1
    else
      return fields, quoted
    end
  end
end

M.parse_line = parse_line

function M.read(path)
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
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")

  local header
  local rows = {}
  local number = 0
  for line in (text .. "\n"):gmatch("(.-)\n") do
    number = number + 1
    if line:match("^%s*$") == nil and line:sub(1, 1) ~= "#" then
      local fields = parse_line(line)
      if not header then
        header = {}
        for column, name in ipairs(fields) do
          header[column] = name:lower():gsub("%s+", "_")
        end
      else
        local row = {}
        row.__line = number
        for column, name in ipairs(header) do
          row[name] = fields[column] or ""
        end
        rows[#rows + 1] = row
      end
    end
  end
  if not header then
    return nil, string.format("%s has no header row", path)
  end
  return { header = header, rows = rows }
end

return M