-- Telegram command dispatch: /planning and /help. Pure: the caller supplies
-- everything a dispatch needs (schedule rows, today's day number, the
-- authorized chat ids), so nothing here reads the clock or the config.
local plan = require("plan")
local date = require("date")

local M = {}

-- Replies are plain text, never Markdown/HTML: with no parse mode there is
-- nothing to escape, so a kind called "secco / non riciclabile" cannot be
-- mangled by a parser.
local HELP = [[🗑 Differenziata - comandi:
/planning - raccolte del mese corrente
/planning 2026-11 - raccolte di un mese specifico
/planning prossimo - raccolte del mese prossimo
/help - questo messaggio]]

local USAGE = "Uso: /planning, /planning 2026-11 o /planning prossimo"

local function is_allowed(chat_id, allowed_chat_ids)
  if type(chat_id) ~= "number" or type(allowed_chat_ids) ~= "table" then
    return false
  end
  for _, id in ipairs(allowed_chat_ids) do
    if id == chat_id then
      return true
    end
  end
  return false
end

-- The month after the one containing today_days.
local function next_month(today_days)
  local year, month = date.from_days(today_days)
  if month == 12 then
    return year + 1, 1
  end
  return year, month + 1
end

local function planning_reply(rows, today_days, argument)
  local year, month = date.from_days(today_days)
  if argument ~= nil and argument ~= "" then
    if argument == "prossimo" then
      year, month = next_month(today_days)
    else
      local parts, err = date.parse_parts(argument .. "-01")
      if not parts then
        return USAGE
      end
      year, month = parts[1], parts[2]
    end
  end
  return plan.render(rows, year, month)
end

-- Returns the reply text, or nil when the update is consumed silently: not a
-- message, an unknown command, or a chat that is not allowed.
function M.dispatch(update, ctx)
  if type(update) ~= "table" then
    return nil
  end
  local message = update.message
  if type(message) ~= "table" then
    return nil
  end
  local text = message.text
  if type(text) ~= "string" or text:sub(1, 1) ~= "/" then
    return nil
  end
  if not is_allowed(message.chat and message.chat.id, ctx and ctx.allowed_chat_ids) then
    -- Consumed silently: replying would confirm the bot's presence to a
    -- stranger, and acking the update keeps it from being reprocessed.
    return nil
  end
  local name = text:match("^/(%S+)")
  if not name then
    return nil
  end
  -- In groups commands arrive as /planning@MioBot; the suffix is not part of
  -- the name.
  local base = name:match("^[^@]+") or name
  local argument = text:match("^/%S+%s*(.*)$") or ""
  argument = argument:gsub("^%s+", ""):gsub("%s+$", "")
  local rows = ctx and ctx.rows
  local today_days = ctx and ctx.today_days
  if base == "planning" then
    if type(rows) ~= "table" or type(today_days) ~= "number" then
      return nil
    end
    return planning_reply(rows, today_days, argument)
  elseif base == "help" then
    return HELP
  end
  return nil
end

return M
