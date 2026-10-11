local h = require("helpers")
local date = require("date")
local schedule = require("schedule")
local plan = require("plan")

local tests = {}

local HEADER = "name,emoji,weekday,every_n_weeks,anchor_date,notes\n"

local function load_csv(text)
  local path = h.tmp_file(HEADER .. text, ".csv")
  local rows, err = schedule.load(path)
  if not rows then
    error(err, 2)
  end
  return rows
end

local function days_of(pickups)
  local out = {}
  for _, pickup in ipairs(pickups) do
    out[#out + 1] = date.format_days(pickup.days)
  end
  return out
end

tests[#tests + 1] = { name = "month includes the 1st and the last day only", run = function()
  -- Anchored just before november, so both rows are active all month:
  -- 2026-11-01 is a sunday, 2026-11-30 a monday.
  local rows = load_csv("sunday,,sunday,1,2026-10-25,\nmonday,,monday,1,2026-10-26,\n")
  local pickups = plan.month(rows, 2026, 11)
  h.eq(10, #pickups)
  h.eq("2026-11-01", date.format_days(pickups[1].days), "the 1st is included")
  h.eq("2026-11-30", date.format_days(pickups[#pickups].days), "the last day is included")
  h.eq({
    "2026-11-01", "2026-11-02", "2026-11-08", "2026-11-09", "2026-11-15",
    "2026-11-16", "2026-11-22", "2026-11-23", "2026-11-29", "2026-11-30",
  }, days_of(pickups))
  -- October holds only the two anchored days: nothing of november leaks in.
  h.eq({ "2026-10-25", "2026-10-26" }, days_of(plan.month(rows, 2026, 10)))
  -- December starts after november: the 30th stays behind.
  h.eq({
    "2026-12-06", "2026-12-07", "2026-12-13", "2026-12-14", "2026-12-20",
    "2026-12-21", "2026-12-27", "2026-12-28",
  }, days_of(plan.month(rows, 2026, 12)))
end }

tests[#tests + 1] = { name = "same-day pickups group into one entry", run = function()
  local rows = load_csv("carta,📄,monday,1,2026-01-05,\numido,💩️,monday,1,2026-01-05,\n")
  local pickups = plan.month(rows, 2026, 10)
  h.eq(4, #pickups)
  h.eq("2026-10-05", date.format_days(pickups[1].days))
  h.eq(2, #pickups[1].kinds)
  h.eq("carta", pickups[1].kinds[1].name)
  h.eq("umido", pickups[1].kinds[2].name)
end }

tests[#tests + 1] = { name = "fortnightly kinds appear only on their phase days", run = function()
  local rows = load_csv("vetro,🍾,thursday,2,2026-01-15,\n")
  local pickups = plan.month(rows, 2026, 1)
  h.eq({ "2026-01-15", "2026-01-29" }, days_of(pickups),
    "the off-phase thursdays (8 and 22) are excluded")
  h.eq(1, #pickups[1].kinds)
  h.eq("vetro", pickups[1].kinds[1].name)
end }

tests[#tests + 1] = { name = "render produces the italian plan text", run = function()
  local rows = load_csv("carta,📄,monday,1,2026-01-05,\numido,💩️,monday,1,2026-01-05,\n")
  local text = plan.render(rows, 2026, 10)
  h.matches("📅 Raccolte di Ottobre 2026", text)
  h.matches("lun 5 ott: 📄 carta, 💩️ umido", text)
  h.matches("lun 26 ott: 📄 carta, 💩️ umido", text)
  h.falsy(text:find("novembre"), "no other month leaks in")
end }

tests[#tests + 1] = { name = "render of an empty month says so", run = function()
  -- The first pickup is years away, so nothing falls in 2026-10.
  local rows = load_csv("futuro,,monday,1,2030-01-07,\n")
  local text = plan.render(rows, 2026, 10)
  h.eq("📅 Raccolte di Ottobre 2026\nNessuna raccolta programmata questo mese.", text)
  h.eq(0, #plan.month(rows, 2026, 10))
end }

tests[#tests + 1] = { name = "leap february keeps its 29th", run = function()
  -- Anchored on the 1st, which is a tuesday in february 2028.
  local rows = load_csv("tuesday,,tuesday,1,2028-02-01,\n")
  h.eq(5, #plan.month(rows, 2028, 2))
  h.matches("mar 29 feb", plan.render(rows, 2028, 2))
  -- A february without a 29th stops at the 28th.
  local flat = load_csv("tuesday,,tuesday,1,2026-02-03,\n")
  h.eq(4, #plan.month(flat, 2026, 2))
  h.falsy(plan.render(flat, 2026, 2):find("29"))
end }

tests[#tests + 1] = { name = "split chunks at the limit on line boundaries", run = function()
  local lines = {}
  for i = 1, 200 do
    lines[#lines + 1] = "lun " .. i .. " ott: 📄 carta, 💩️ umido"
  end
  local text = table.concat(lines, "\n")
  local chunks = plan.split(text, 100)
  h.truthy(#chunks > 1)
  for _, chunk in ipairs(chunks) do
    h.truthy(#chunk <= 100, "chunk of " .. #chunk .. " chars")
    h.truthy(chunk:find("\n") or chunk == chunks[#chunks], "chunk holds whole lines")
  end
  h.eq(text, table.concat(chunks, "\n"))
end }

tests[#tests + 1] = { name = "split defaults to the 4096 telegram limit", run = function()
  local lines = {}
  for i = 1, 250 do
    lines[#lines + 1] = "lun " .. i .. " ott: 📄 carta, 💩️ umido"
  end
  local text = table.concat(lines, "\n")
  h.truthy(#text > 4096)
  local chunks = plan.split(text)
  h.truthy(#chunks >= 2)
  for _, chunk in ipairs(chunks) do
    h.truthy(#chunk <= 4096, "chunk of " .. #chunk .. " chars")
  end
  h.eq(text, table.concat(chunks, "\n"))
  h.eq({ "short" }, plan.split("short"))
end }

tests[#tests + 1] = { name = "split keeps an over-long line whole", run = function()
  local chunks = plan.split(string.rep("x", 5000))
  h.eq(1, #chunks)
  h.eq(5000, #chunks[1])
end }

tests[#tests + 1] = { name = "split joins lines that exactly fill the limit", run = function()
  -- "aaaa\nbbbb" is 9 bytes: the boundary is inclusive, so it stays one chunk.
  local chunks = plan.split("aaaa\nbbbb", 9)
  h.eq(1, #chunks)
  h.eq(9, #chunks[1])
  h.eq("aaaa\nbbbb", chunks[1])
end }

tests[#tests + 1] = { name = "split of empty text yields one empty chunk", run = function()
  h.eq({ "" }, plan.split(""))
end }

return tests
