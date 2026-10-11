-- Renders one calendar month of pickups as Italian plain text for Telegram.
-- Pure: no clock, no IO, no calendar maths beyond what date.lua and
-- schedule.lua already provide; util supplies only the Italian month name.
local date = require("date")
local schedule = require("schedule")
local util = require("util")

local M = {}

-- Telegram rejects messages longer than this, so renderings are chunked on
-- line boundaries before being sent.
M.TELEGRAM_LIMIT = 4096

-- Per-day pickup buckets for one calendar month: the 1st through the last
-- day, adjacent months excluded.
function M.month(rows, year, month)
  return schedule.upcoming(rows, date.to_days(year, month, 1), date.days_in_month(year, month) - 1)
end

local function capitalize(text)
  return text:sub(1, 1):upper() .. text:sub(2)
end

-- Mirrors describe_kinds in init.lua: "emoji name" or the bare name, comma
-- joined. Kept identical on purpose so the plan and the reminder line read
-- alike; init.lua cannot be required from here.
local function describe_kinds(kinds)
  local names = {}
  for _, kind in ipairs(kinds) do
    if kind.emoji ~= "" then
      names[#names + 1] = kind.emoji .. " " .. kind.name
    else
      names[#names + 1] = kind.name
    end
  end
  return table.concat(names, ", ")
end

function M.render(rows, year, month)
  local lines = {
    string.format("📅 Raccolte di %s %d", capitalize(util.month_name(month)), year),
  }
  local pickups = M.month(rows, year, month)
  if #pickups == 0 then
    lines[#lines + 1] = "Nessuna raccolta programmata questo mese."
    return table.concat(lines, "\n")
  end
  for _, pickup in ipairs(pickups) do
    local y, m, d = date.from_days(pickup.days)
    lines[#lines + 1] = string.format(
      "%s: %s", date.short_date(y, m, d), describe_kinds(pickup.kinds)
    )
  end
  return table.concat(lines, "\n")
end

-- Chunks text on line boundaries so no chunk exceeds limit. A single line
-- longer than the limit is emitted alone rather than truncated: silently
-- dropping text could lose a pickup.
function M.split(text, limit)
  limit = limit or M.TELEGRAM_LIMIT
  local chunks = {}
  local current = nil
  for line in (tostring(text) .. "\n"):gmatch("([^\n]*)\n") do
    if current == nil then
      current = line
    elseif #current + 1 + #line <= limit then
      current = current .. "\n" .. line
    else
      chunks[#chunks + 1] = current
      current = line
    end
  end
  if current ~= nil then
    chunks[#chunks + 1] = current
  end
  return chunks
end

return M
