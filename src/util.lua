local M = {}

local MONTH_NAMES = {
  "gennaio", "febbraio", "marzo", "aprile", "maggio", "giugno",
  "luglio", "agosto", "settembre", "ottobre", "novembre", "dicembre",
}

local WEEKDAY_NAMES = {
  "lunedì", "martedì", "mercoledì", "giovedì", "venerdì", "sabato", "domenica",
}

local WEEKDAY_ARTICLES = { [1] = "il", [2] = "il", [3] = "il", [4] = "il", [5] = "il", [6] = "il", [7] = "la" }

M.VERBOSE = false

local function stamp()
  return os.date("%Y-%m-%d %H:%M:%S")
end

function M.log(format, ...)
  local message = select("#", ...) > 0 and string.format(format, ...) or format
  io.stderr:write(string.format("[%s] %s\n", stamp(), message))
end

function M.debug(format, ...)
  if M.VERBOSE then
    M.log(format, ...)
  end
end

function M.trim(text)
  return (tostring(text):gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.split(text, separator)
  local parts = {}
  local pattern = string.format("([^%s]+)", separator:gsub("(%W)", "%%%1"))
  for part in tostring(text):gmatch(pattern) do
    parts[#parts + 1] = part
  end
  return parts
end

-- Single-quote wrapping is the only shell quoting form that cannot be
-- broken by any input, including newlines and emoji.
function M.shell_quote(text)
  return "'" .. tostring(text):gsub("'", "'\\''") .. "'"
end

function M.read_file(path)
  local handle = io.open(path, "rb")
  if not handle then
    return nil, string.format("cannot open %s", path)
  end
  local text = handle:read("a")
  handle:close()
  return text
end

-- Write-then-rename: a crash mid-write leaves the old file intact instead of a
-- truncated one. For state.tsv that is the difference between a duplicate
-- reminder and a lost sent-record.
function M.write_file(path, text)
  local tmp = path .. ".tmp"
  local handle, open_error = io.open(tmp, "wb")
  if not handle then
    return nil, string.format("cannot write %s: %s", tmp, open_error)
  end
  local ok, write_error = handle:write(text)
  if not ok then
    handle:close()
    os.remove(tmp)
    return nil, string.format("cannot write %s: %s", tmp, write_error)
  end
  handle:flush()
  handle:close()
  local renamed, rename_error = os.rename(tmp, path)
  if not renamed then
    os.remove(tmp)
    return nil, string.format("cannot replace %s: %s", path, rename_error)
  end
  return true
end

function M.ensure_dir(path)
  if os.execute(string.format("mkdir -p %s", M.shell_quote(path))) ~= 0 then
    return nil, string.format("cannot create %s", path)
  end
  return true
end

function M.file_exists(path)
  local handle = io.open(path, "rb")
  if handle then
    handle:close()
    return true
  end
  return false
end

function M.weekday_name(index)
  return WEEKDAY_NAMES[index]
end

function M.weekday_article(index)
  return WEEKDAY_ARTICLES[index]
end

function M.month_name(index)
  return MONTH_NAMES[index]
end

function M.join(values, separator)
  return table.concat(values, separator or ", ")
end

return M