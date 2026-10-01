local h = require("helpers")
local date = require("date")

local tests = {}

tests[#tests + 1] = { name = "epoch day zero is thursday", run = function()
  h.eq(4, date.weekday(1970, 1, 1))
  h.eq(0, date.to_days(1970, 1, 1))
  h.eq(1, date.weekday(1970, 1, 5))
end }

tests[#tests + 1] = { name = "weekday mapping is 1..7 monday..sunday", run = function()
  local expected = {
    "2026-01-05", "2026-01-06", "2026-01-07", "2026-01-08",
    "2026-01-09", "2026-01-10", "2026-01-11",
  }
  for index, text in ipairs(expected) do
    local year, month, day = date.parse(text)
    h.eq(index, date.weekday(year, month, day), text)
  end
end }

tests[#tests + 1] = { name = "to_days/from_days round trip", run = function()
  for days = -20000, 20000, 37 do
    local year, month, day = date.from_days(days)
    h.eq(days, date.to_days(year, month, day), string.format("round trip at %d", days))
  end
end }

tests[#tests + 1] = { name = "known anchors", run = function()
  h.eq("2000-03-01", date.format_days(date.to_days(2000, 3, 1)))
  h.eq("1970-01-01", date.format_days(0))
  h.eq("2100-01-01", date.format_days(date.to_days(2100, 1, 1)))
  h.eq(28, date.to_days(2000, 2, 29) - date.to_days(2000, 2, 1))
  h.eq(1, date.to_days(2000, 3, 1) - date.to_days(2000, 2, 29))
end }

tests[#tests + 1] = { name = "leap years", run = function()
  h.truthy(date.is_leap_year(2024))
  h.falsy(date.is_leap_year(2100))
  h.truthy(date.is_leap_year(2000))
  h.eq(29, date.days_in_month(2024, 2))
  h.eq(28, date.days_in_month(2100, 2))
  h.eq(31, date.days_in_month(2026, 12))
end }

tests[#tests + 1] = { name = "parse rejects nonsense", run = function()
  local bad1, bad1_error = date.parse("2026-02-30")
  h.falsy(bad1)
  h.matches("not a real calendar date", bad1_error)
  h.falsy(date.parse("2026-13-01"))
  h.falsy(date.parse("26-1-1"))
  h.falsy(date.parse(""))
  local year, month, day = date.parse("2026-01-05")
  h.eq({ 2026, 1, 5 }, { year, month, day })
end }

tests[#tests + 1] = { name = "parse_time", run = function()
  h.eq({ 11, 30 }, { date.parse_time("11:30") })
  h.eq({ 0, 0 }, { date.parse_time("0:00") })
  h.eq({ 23, 59 }, { date.parse_time("23:59") })
  h.falsy(date.parse_time("24:00"))
  h.falsy(date.parse_time("11:60"))
  h.falsy(date.parse_time("1130"))
  h.eq("07:05", date.format_time(7, 5))
end }

tests[#tests + 1] = { name = "parse_parts reports failures without slot confusion", run = function()
  local parts = date.parse_parts("2026-01-05")
  h.eq({ 2026, 1, 5 }, parts)
  local nil_parts, err = date.parse_parts("05/01/2026")
  h.falsy(nil_parts)
  h.matches("expected YYYY-MM-DD", err)
  local year, month, day = date.parse("2026-01-05")
  h.eq({ 2026, 1, 5 }, { year, month, day })
end }

tests[#tests + 1] = { name = "italian short names", run = function()
  h.eq("ven 2 ott", date.short_date(2026, 10, 2), "a friday in october")
  h.eq("ven 1 gen", date.short_date(2027, 1, 1))
  h.eq("ven 31 dic", date.short_date(2027, 12, 31))
  h.eq("dom 1 feb", date.short_date(2026, 2, 1))
end }

return tests