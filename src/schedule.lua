local csv = require("csv")
local date = require("date")
local util = require("util")

local M = {}

local REQUIRED = { "name", "weekday", "every_n_weeks", "anchor_date" }

local function normalize_weekday(value, line)
  local key = util.trim(value):lower()
  local index = date.WEEKDAY_INDEX[key]
  if not index and tonumber(key) then
    index = date.WEEKDAY_INDEX[tostring(tonumber(key))]
  end
  if not index then
    return nil, string.format(
      "line %d: unknown weekday %q (use monday..sunday or 1..7)", line, value
    )
  end
  return index
end

function M.load(path)
  local data, err = csv.read(path)
  if not data then
    return nil, err
  end
  for _, name in ipairs(REQUIRED) do
    local found = false
    for _, column in pairs(data.header) do
      if column == name then
        found = true
      end
    end
    if not found then
      return nil, string.format("%s: missing required column %q", path, name)
    end
  end

  local rows = {}
  for _, record in ipairs(data.rows) do
    local line = record.__line
    local name = util.trim(record.name)
    if name ~= "" then
      local weekday, weekday_error = normalize_weekday(record.weekday, line)
      if not weekday then
        return nil, string.format("%s: %s", path, weekday_error)
      end
      local every = tonumber(util.trim(record.every_n_weeks))
      if not every or every < 1 or every % 1 ~= 0 then
        return nil, string.format(
          "line %d: every_n_weeks must be a whole number >= 1, got %q", line, record.every_n_weeks
        )
      end
      local anchor, anchor_error = date.parse_parts(util.trim(record.anchor_date))
      if not anchor then
        return nil, string.format("line %d: %s", line, anchor_error)
      end
      local year, month, day = anchor[1], anchor[2], anchor[3]
      if date.weekday(year, month, day) ~= weekday then
        return nil, string.format(
          "line %d: anchor_date %s is a %s but weekday is %s",
          line, date.format(year, month, day), date.WEEKDAY_NAMES[date.weekday(year, month, day)],
          date.WEEKDAY_NAMES[weekday]
        )
      end
      rows[#rows + 1] = {
        name = name,
        emoji = util.trim(record.emoji),
        weekday = weekday,
        every_n_weeks = every,
        anchor_date = date.format(year, month, day),
        anchor_days = date.to_days(year, month, day),
        notes = util.trim(record.notes),
        line = line,
      }
    end
  end
  if #rows == 0 then
    return nil, string.format("%s: no usable rows", path)
  end
  table.sort(rows, function(a, b)
    if a.name == b.name then
      return a.weekday < b.weekday
    end
    return a.name < b.name
  end)
  return rows
end

function M.matches(row, days)
  if date.weekday_of_days(days) ~= row.weekday then
    return false
  end
  local weeks = (days - row.anchor_days) / 7
  return weeks % row.every_n_weeks == 0
end

function M.next_on_or_after(row, from_days)
  local start_weekday = date.weekday_of_days(from_days)
  local days = from_days + (row.weekday - start_weekday) % 7
  if days < row.anchor_days then
    local weeks = math.ceil((row.anchor_days - days) / 7)
    days = days + 7 * weeks
  end
  local weeks = (days - row.anchor_days) / 7
  local remainder = weeks % row.every_n_weeks
  if remainder ~= 0 then
    days = days + 7 * (row.every_n_weeks - remainder)
  end
  return days
end

-- Pickup days grouped by calendar day, sorted, within [from_days, from_days + horizon].
function M.upcoming(rows, from_days, horizon)
  local by_day = {}
  for _, row in ipairs(rows) do
    local days = M.next_on_or_after(row, from_days)
    while days <= from_days + horizon do
      by_day[days] = by_day[days] or {}
      local bucket = by_day[days]
      local known = false
      for _, item in ipairs(bucket) do
        if item.name == row.name then
          known = true
        end
      end
      if not known then
        bucket[#bucket + 1] = row
      end
      days = days + 7 * row.every_n_weeks
    end
  end
  local result = {}
  for days, bucket in pairs(by_day) do
    table.sort(bucket, function(a, b)
      return a.name < b.name
    end)
    result[#result + 1] = { days = days, kinds = bucket }
  end
  table.sort(result, function(a, b)
    return a.days < b.days
  end)
  return result
end

return M