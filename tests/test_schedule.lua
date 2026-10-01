local h = require("helpers")
local date = require("date")
local schedule = require("schedule")

local tests = {}

local HEADER = "name,emoji,weekday,every_n_weeks,anchor_date,notes\n"

-- HEADER ends in a newline, so appending a comment-only line adds row 1
-- (data rows are counted from the first line after the header).
local function load_csv(text)
  local path = h.tmp_file(HEADER .. text, ".csv")
  local rows, err = schedule.load(path)
  if not rows then
    error(err, 2)
  end
  return rows
end

local function load_error(text)
  local path = h.tmp_file(HEADER .. "# a comment line is skipped\n" .. text, ".csv")
  local rows, err = schedule.load(path)
  if rows then
    error("expected a load failure", 2)
  end
  return err
end

local PAPER = { name = "carta", emoji = "📄", weekday = 1, every_n_weeks = 1, anchor_days = date.to_days(2026, 1, 5) }
local GLASS = { name = "vetro", emoji = "🍾", weekday = 4, every_n_weeks = 2, anchor_days = date.to_days(2026, 1, 15) }

tests[#tests + 1] = { name = "matches honours weekday and cycle phase", run = function()
  h.truthy(schedule.matches(PAPER, date.to_days(2026, 10, 5)))
  h.falsy(schedule.matches(PAPER, date.to_days(2026, 10, 6)))
  h.truthy(schedule.matches(GLASS, date.to_days(2026, 1, 15)))
  h.falsy(schedule.matches(GLASS, date.to_days(2026, 1, 22)), "two weeks after the anchor")
  h.truthy(schedule.matches(GLASS, date.to_days(2026, 1, 29)))
  h.falsy(schedule.matches(GLASS, date.to_days(2026, 1, 8)), "one week before the anchor")
end }

tests[#tests + 1] = { name = "next_on_or_after weekly", run = function()
  local monday = date.to_days(2026, 10, 5)
  h.eq("2026-10-05", date.format_days(schedule.next_on_or_after(PAPER, monday)))
  h.eq("2026-10-05", date.format_days(schedule.next_on_or_after(PAPER, date.to_days(2026, 10, 2))),
    "friday looks forward to monday")
  h.eq("2026-10-12", date.format_days(schedule.next_on_or_after(PAPER, monday + 1)),
    "from tuesday the next pickup is the following monday")
  h.eq("2026-10-12", date.format_days(schedule.next_on_or_after(PAPER, monday + 7)))
  h.eq("2026-10-12", date.format_days(schedule.next_on_or_after(PAPER, monday + 3)),
    "from thursday the next pickup is the following monday")
end }

tests[#tests + 1] = { name = "next_on_or_after fortnightly keeps the phase across months", run = function()
  local expected = { "2026-01-15", "2026-01-29", "2026-02-12", "2026-02-26", "2026-03-12" }
  local cursor = date.to_days(2025, 12, 20)
  for _, text in ipairs(expected) do
    local days = schedule.next_on_or_after(GLASS, cursor)
    h.eq(text, date.format_days(days))
    cursor = days + 1
  end
  h.eq("2026-01-15", date.format_days(schedule.next_on_or_after(GLASS, date.to_days(2025, 1, 1))))
  h.eq("2026-01-15", date.format_days(schedule.next_on_or_after(GLASS, date.to_days(2026, 1, 15))),
    "the anchor day itself is a pickup")
end }

tests[#tests + 1] = { name = "upcoming groups the same day together", run = function()
  local rows = load_csv("carta,📄,monday,1,2026-01-05,\nplastica e lattine,🧴,monday,1,2026-01-05,\n")
  local pickups = schedule.upcoming(rows, date.to_days(2026, 10, 1), 10)
  h.eq(1, #pickups)
  h.eq("2026-10-05", date.format_days(pickups[1].days))
  h.eq(2, #pickups[1].kinds)
  h.eq("carta", pickups[1].kinds[1].name)
  h.eq("plastica e lattine", pickups[1].kinds[2].name)
end }

tests[#tests + 1] = { name = "upcoming respects the horizon and sorts by day", run = function()
  local rows = load_csv("carta,📄,monday,1,2026-01-05,\nvetro,🍾,thursday,2,2026-01-15,\n")
  -- 13 days from 2026-10-01 reaches 2026-10-14, so carta (10-05, 10-12) and
  -- vetro (10-08) all fall inside; the next vetro (10-22) does not.
  local pickups = schedule.upcoming(rows, date.to_days(2026, 10, 1), 13)
  local days = {}
  for _, pickup in ipairs(pickups) do
    days[#days + 1] = date.format_days(pickup.days)
  end
  h.eq({ "2026-10-05", "2026-10-08", "2026-10-12" }, days)
end }

tests[#tests + 1] = { name = "upcoming never returns a day before the start", run = function()
  local rows = load_csv("carta,📄,monday,1,2026-01-05,\n")
  local pickups = schedule.upcoming(rows, date.to_days(2026, 10, 5), 0)
  h.eq(1, #pickups)
  h.eq("2026-10-05", date.format_days(pickups[1].days))
end }

tests[#tests + 1] = { name = "weekday accepts names and numbers", run = function()
  local rows = load_csv("a,,3,1,2026-01-07,\nb,,7,1,2026-01-11,\n")
  h.eq(3, rows[1].weekday)
  h.eq(7, rows[2].weekday)
end }

tests[#tests + 1] = { name = "load rejects bad data with a useful message", run = function()
  h.matches("unknown weekday", load_error("x,,funday,1,2026-01-05,\n"))
  h.matches(
    "anchor_date 2026-01-07 is a wednesday but weekday is monday",
    load_error("x,,monday,1,2026-01-07,\n")
  )
  h.matches("every_n_weeks must be", load_error("x,,monday,0,2026-01-05,\n"))
  h.matches("every_n_weeks must be", load_error("x,,monday,two,2026-01-05,\n"))
  h.matches("expected YYYY-MM-DD", load_error("x,,monday,1,05-01-2026,\n"))
  h.matches("no usable rows", load_error("# nothing\n"))
end }

tests[#tests + 1] = { name = "load requires the mandatory columns", run = function()
  local path = h.tmp_file("name,weekday\ncarta,monday\n", ".csv")
  local rows, err = schedule.load(path)
  h.falsy(rows)
  h.matches("missing required column", err)
end }

tests[#tests + 1] = { name = "the shipped calendar loads and validates", run = function()
  local rows = schedule.load("schedule.csv")
  h.eq(5, #rows)
  local names = {}
  for _, row in ipairs(rows) do
    names[row.name] = row
  end
  h.truthy(names["carta"])
  h.truthy(names["plastica e lattine"])
  h.truthy(names["umido"])
  h.truthy(names["vetro"])
  h.truthy(names["secco / non riciclabile"])
  h.eq(2, names["vetro"].every_n_weeks, "vetro is the fortnightly one")
end }

return tests