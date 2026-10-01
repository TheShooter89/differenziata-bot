local h = require("helpers")
local date = require("date")
local reminders = require("reminders")

local tests = {}

local DEFAULTS = { days_before = 1, times = { "11:30", "16:00", "20:30" }, grace_minutes = 120 }

local PICKUP = date.to_days(2026, 10, 5) -- monday
local KINDS = {
  { name = "carta", emoji = "📄" },
  { name = "plastica e lattine", emoji = "🧴" },
}

local function stamp(year, month, day, hour, minute)
  return os.time({ year = year, month = month, day = day, hour = hour, min = minute, sec = 0 })
end

tests[#tests + 1] = { name = "days_before normalises to a descending unique list", run = function()
  h.eq({ 1 }, reminders.days_before({ days_before = 1 }))
  h.eq({ 0 }, reminders.days_before({ days_before = 0 }))
  h.eq({ 2, 1, 0 }, reminders.days_before({ days_before = { 0, 2, 1 } }))
  h.eq({ 3, 1 }, reminders.days_before({ days_before = { 1, 3, 1 } }))
end }

tests[#tests + 1] = { name = "default reminders are three times the day before", run = function()
  local slots = reminders.slots(DEFAULTS, PICKUP)
  h.eq(3, #slots)
  h.eq({ "2026-10-04", "2026-10-04", "2026-10-04" }, {
    os.date("%Y-%m-%d", slots[1].due_at),
    os.date("%Y-%m-%d", slots[2].due_at),
    os.date("%Y-%m-%d", slots[3].due_at),
  })
  h.eq({ "11:30", "16:00", "20:30" }, {
    os.date("%H:%M", slots[1].due_at),
    os.date("%H:%M", slots[2].due_at),
    os.date("%H:%M", slots[3].due_at),
  })
  h.eq("2026-10-05|d1|11:30", slots[1].key)
  h.eq("2026-10-05|d1|20:30", slots[3].key)
end }

tests[#tests + 1] = { name = "slots across month boundaries land on the right day", run = function()
  local slots = reminders.slots(DEFAULTS, date.to_days(2026, 11, 1)) -- sunday
  h.eq("2026-10-31", os.date("%Y-%m-%d", slots[1].due_at))
  local leap = reminders.slots(DEFAULTS, date.to_days(2028, 3, 1))
  h.eq("2028-02-29", os.date("%Y-%m-%d", leap[1].due_at))
end }

tests[#tests + 1] = { name = "several days_before values multiply the slots", run = function()
  local slots = reminders.slots({ days_before = { 2, 1 }, times = { "09:00", "21:00" } }, PICKUP)
  h.eq(4, #slots)
  h.eq(stamp(2026, 10, 3, 9, 0), slots[1].due_at)
  h.eq(stamp(2026, 10, 3, 21, 0), slots[2].due_at)
  h.eq(stamp(2026, 10, 4, 9, 0), slots[3].due_at)
  h.eq(stamp(2026, 10, 4, 21, 0), slots[4].due_at)
  local keys = {}
  for _, slot in ipairs(slots) do
    h.falsy(keys[slot.key], "duplicate key " .. slot.key)
    keys[slot.key] = true
  end
end }

tests[#tests + 1] = { name = "days_before = 0 reminds on the pickup day", run = function()
  local slots = reminders.slots({ days_before = 0, times = { "07:00" } }, PICKUP)
  h.eq(stamp(2026, 10, 5, 7, 0), slots[1].due_at)
  h.eq("2026-10-05|d0|07:00", slots[1].key)
end }

tests[#tests + 1] = { name = "keys differ per pickup day so nothing collides", run = function()
  local first = reminders.slots(DEFAULTS, PICKUP)[1].key
  local second = reminders.slots(DEFAULTS, PICKUP + 7)[1].key
  h.falsy(first == second)
end }

tests[#tests + 1] = { name = "message says the day, the kinds and how to leave them out", run = function()
  local slots = reminders.slots(DEFAULTS, PICKUP)
  local text = reminders.message(slots[1], KINDS)
  h.matches("ritirano domani", text)
  h.matches("lun 5 ott", text)
  h.matches("Lascia fuori", text)
  h.matches("📄 carta", text)
  h.matches("🧴 plastica e lattine", text)
  h.falsy(text:find("non riciclabile"), "only the kinds of that day")
end }

tests[#tests + 1] = { name = "message wording follows days_before", run = function()
  h.eq("oggi", reminders.lead_phrase(0))
  h.eq("domani", reminders.lead_phrase(1))
  h.eq("tra 3 giorni", reminders.lead_phrase(3))
  local same_day = reminders.slots({ days_before = 0, times = { "07:00" } }, PICKUP)
  local text = reminders.message(same_day[1], KINDS)
  h.matches("ritirano oggi", text)
  h.matches("Lascia fuori adesso", text)
end }

tests[#tests + 1] = { name = "message copes with a kind without an emoji", run = function()
  local slots = reminders.slots(DEFAULTS, PICKUP)
  local text = reminders.message(slots[1], { { name = "secco / non riciclabile", emoji = "" } })
  h.matches("\n- secco / non riciclabile", text)
end }

return tests