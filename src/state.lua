-- Append-only ledger: one "key<TAB>epoch" line per dealt-with reminder, whether
-- it was delivered or deliberately dropped. Plain TSV keeps it greppable and
-- means no JSON parser is needed.
--
-- Missed reminders are recorded under a prefixed key, because cron runs every
-- 30 minutes: without a record, a reminder whose grace window has passed would
-- be re-reported as missed on every tick for as long as its pickup stayed in the
-- horizon, drowning the log in identical lines.
local util = require("util")

local M = {}

M.PRUNE_AFTER_DAYS = 90
M.MISSED_PREFIX = "missed|"

function M.new()
  return { entries = {}, order = {} }
end

function M.load(path)
  local state = M.new()
  local text = util.read_file(path)
  if not text then
    return state
  end
  for line in text:gmatch("[^\n]+") do
    local key, stamp = line:match("^(.-)\t(%d+)$")
    if key then
      if state.entries[key] == nil then
        state.order[#state.order + 1] = key
      end
      state.entries[key] = tonumber(stamp)
    end
  end
  return state
end

function M.was_sent(state, key)
  return state.entries[key] ~= nil
end

-- True when this reminder has already been delivered or already reported as
-- missed, so neither branch should run again.
function M.is_settled(state, key)
  return state.entries[key] ~= nil or state.entries[M.MISSED_PREFIX .. key] ~= nil
end

function M.was_missed(state, key)
  return state.entries[M.MISSED_PREFIX .. key] ~= nil
end

function M.mark_missed(state, key, at)
  M.mark_sent(state, M.MISSED_PREFIX .. key, at)
end

function M.mark_sent(state, key, at)
  if state.entries[key] == nil then
    state.order[#state.order + 1] = key
  end
  state.entries[key] = at
end

function M.serialize(state, now, prune_after_days)
  local cutoff = now - (prune_after_days or M.PRUNE_AFTER_DAYS) * 86400
  local keys = {}
  for _, key in ipairs(state.order) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  local lines = {}
  for _, key in ipairs(keys) do
    local stamp = state.entries[key]
    if stamp and stamp >= cutoff then
      lines[#lines + 1] = string.format("%s\t%d", key, stamp)
    end
  end
  if #lines == 0 then
    return ""
  end
  return table.concat(lines, "\n") .. "\n"
end

function M.save(path, state, now)
  return util.write_file(path, M.serialize(state, now))
end

return M