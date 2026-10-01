local date = require("date")
local config_util = require("config")

local M = {}

function M.days_before(reminders)
  local list = config_util.is_array(reminders.days_before) and reminders.days_before
    or { reminders.days_before }
  local seen = {}
  local unique = {}
  for _, value in ipairs(list) do
    if not seen[value] then
      seen[value] = true
      unique[#unique + 1] = value
    end
  end
  table.sort(unique, function(a, b)
    return a > b
  end)
  return unique
end

-- One slot per (pickup day, days_before, time). All kinds collected on the same
-- day share a single message, so the number of messages per day is bounded by
-- the config rather than by the size of the CSV.
function M.slots(reminders, pickup_days)
  local slots = {}
  for _, days_before in ipairs(M.days_before(reminders)) do
    for _, time in ipairs(reminders.times) do
      local year, month, day = date.from_days(pickup_days - days_before)
      local hour, minute = date.parse_time(time)
      -- isdst is deliberately left unset: os.time then uses the local zone's
      -- DST rules, which is what a human means by "11:30 that morning". Forcing
      -- isdst = false would shift every reminder by an hour for half the year.
      local due_at = os.time({
        year = year,
        month = month,
        day = day,
        hour = hour,
        min = minute,
        sec = 0,
      })
      if not due_at then
        return nil, string.format(
          "cannot resolve local time %04d-%02d-%02d %s", year, month, day, time
        )
      end
      slots[#slots + 1] = {
        key = string.format("%s|d%d|%s", date.format_days(pickup_days), days_before, time),
        pickup_days = pickup_days,
        days_before = days_before,
        time = time,
        due_at = due_at,
      }
    end
  end
  table.sort(slots, function(a, b)
    if a.due_at ~= b.due_at then
      return a.due_at < b.due_at
    end
    return a.key < b.key
  end)
  return slots
end

function M.lead_phrase(days_before)
  if days_before == 0 then
    return "oggi"
  elseif days_before == 1 then
    return "domani"
  end
  return string.format("tra %d giorni", days_before)
end

local function kind_line(kind)
  if kind.emoji ~= "" then
    return string.format("- %s %s", kind.emoji, kind.name)
  end
  return string.format("- %s", kind.name)
end

function M.message(slot, kinds)
  local year, month, day = date.from_days(slot.pickup_days)
  local lines = {
    string.format(
      "🗑 Differenziata: ritirano %s (%s)",
      M.lead_phrase(slot.days_before),
      date.short_date(year, month, day)
    ),
  }
  if slot.days_before == 0 then
    lines[#lines + 1] = "Lascia fuori adesso, prima che passino."
  else
    lines[#lines + 1] = "Lascia fuori entro stasera / domani mattina."
  end
  for _, kind in ipairs(kinds) do
    lines[#lines + 1] = kind_line(kind)
  end
  return table.concat(lines, "\n")
end

return M