-- Civil date arithmetic with no timezone and no os.time involvement, so the
-- calendar logic is pure integer maths and trivially testable.
local M = {}

local MONTH_DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local WEEKDAY_NAMES = {
  "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
}

M.WEEKDAY_NAMES = WEEKDAY_NAMES

M.WEEKDAY_INDEX = {}
for i, name in ipairs(WEEKDAY_NAMES) do
  M.WEEKDAY_INDEX[name] = i
  M.WEEKDAY_INDEX[tostring(i)] = i
end

local SHORT_WEEKDAY_NAMES = {
  "lun", "mar", "mer", "gio", "ven", "sab", "dom",
}

local SHORT_MONTH_NAMES = {
  "gen", "feb", "mar", "apr", "mag", "giu",
  "lug", "ago", "set", "ott", "nov", "dic",
}

function M.is_leap_year(year)
  return (year % 4 == 0 and year % 100 ~= 0) or year % 400 == 0
end

function M.days_in_month(year, month)
  if month == 2 and M.is_leap_year(year) then
    return 29
  end
  return MONTH_DAYS[month]
end

function M.is_valid(year, month, day)
  if type(year) ~= "number" or type(month) ~= "number" or type(day) ~= "number" then
    return false
  end
  if month < 1 or month > 12 then
    return false
  end
  return day >= 1 and day <= M.days_in_month(year, month)
end

-- Howard Hinnant's days_from_civil: days since 1970-01-01.
function M.to_days(year, month, day)
  local y = year
  local m = month
  if m <= 2 then
    y = y - 1
    m = m + 12
  end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * (m - 3) + 2) / 5) + day - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

-- Inverse of to_days (civil_from_days).
function M.from_days(days)
  local z = days + 719468
  local era = math.floor(z / 146097)
  local doe = z - era * 146097
  local yoe = math.floor(
    (doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365
  )
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local day = doy - math.floor((153 * mp + 2) / 5) + 1
  local month = mp + (mp < 10 and 3 or -9)
  if month <= 2 then
    y = y + 1
  end
  return y, month, day
end

-- 1 = monday .. 7 = sunday. 1970-01-01 (day 0) was a thursday, which is 4.
function M.weekday_of_days(days)
  return (days + 3) % 7 + 1
end

function M.weekday(year, month, day)
  return M.weekday_of_days(M.to_days(year, month, day))
end

-- Returns a table so callers never confuse a failed parse with the y/m/d slots.
function M.parse_parts(text)
  local year, month, day = tostring(text):match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
  if not year then
    return nil, string.format("expected YYYY-MM-DD, got %q", tostring(text))
  end
  year, month, day = tonumber(year), tonumber(month), tonumber(day)
  if not M.is_valid(year, month, day) then
    return nil, string.format("not a real calendar date: %q", tostring(text))
  end
  return { year, month, day }
end

function M.parse(text)
  local parts, err = M.parse_parts(text)
  if not parts then
    return nil, err
  end
  return parts[1], parts[2], parts[3]
end

function M.format(year, month, day)
  return string.format("%04d-%02d-%02d", year, month, day)
end

function M.format_days(days)
  return M.format(M.from_days(days))
end

local function two_digits(value)
  return string.format("%02d", value)
end

function M.short_weekday(year, month, day)
  return SHORT_WEEKDAY_NAMES[M.weekday(year, month, day)]
end

function M.short_date(year, month, day)
  return string.format("%s %d %s", M.short_weekday(year, month, day), day, SHORT_MONTH_NAMES[month])
end

function M.parse_time(text)
  local hour, minute = tostring(text):match("^(%d%d?):(%d%d)$")
  if not hour then
    return nil, string.format("expected HH:MM, got %q", tostring(text))
  end
  hour, minute = tonumber(hour), tonumber(minute)
  if hour > 23 or minute > 59 then
    return nil, string.format("time out of range: %q", tostring(text))
  end
  return hour, minute
end

function M.format_time(hour, minute)
  return two_digits(hour) .. ":" .. two_digits(minute)
end

return M