local h = require("helpers")
local date = require("date")
local schedule = require("schedule")
local commands = require("commands")

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

local ROWS = load_csv("carta,📄,monday,1,2026-01-05,\numido,💩️,monday,1,2026-01-05,\n")

local function dispatch(text, chat_id, today_days, rows, allowed_chat_ids)
  return commands.dispatch({
    update_id = 101,
    message = { chat = { id = chat_id }, text = text },
  }, {
    rows = rows or ROWS,
    today_days = today_days or date.to_days(2026, 10, 10),
    allowed_chat_ids = allowed_chat_ids or { 42 },
  })
end

tests[#tests + 1] = { name = "bare /planning shows the current month", run = function()
  local reply = dispatch("/planning", 42, date.to_days(2026, 10, 10))
  h.truthy(type(reply) == "string")
  h.matches("📅 Raccolte di Ottobre 2026", reply)
  h.matches("lun 5 ott", reply)
end }

tests[#tests + 1] = { name = "/planning takes a YYYY-MM argument", run = function()
  h.matches("📅 Raccolte di Novembre 2026", dispatch("/planning 2026-11", 42, date.to_days(2026, 10, 10)))
  h.matches("📅 Raccolte di Gennaio 2027", dispatch("/planning 2027-01", 42, date.to_days(2026, 12, 15)))
end }

tests[#tests + 1] = { name = "/planning prossimo shows the next month", run = function()
  h.matches("📅 Raccolte di Novembre 2026", dispatch("/planning prossimo", 42, date.to_days(2026, 10, 10)))
  h.matches("📅 Raccolte di Gennaio 2027", dispatch("/planning prossimo", 42, date.to_days(2026, 12, 15)))
end }

tests[#tests + 1] = { name = "an unknown month argument gets the usage back", run = function()
  for _, text in ipairs({ "/planning 2026-13", "/planning ieri", "/planning 11" }) do
    local reply = dispatch(text, 42, date.to_days(2026, 10, 10))
    h.truthy(type(reply) == "string", text)
    h.matches("Uso:", reply, text)
    h.matches("prossimo", reply, text)
  end
end }

tests[#tests + 1] = { name = "/help lists the commands", run = function()
  local reply = dispatch("/help", 42, date.to_days(2026, 10, 10))
  h.truthy(type(reply) == "string")
  h.matches("/planning", reply)
  h.matches("prossimo", reply)
  h.matches("/help", reply)
end }

tests[#tests + 1] = { name = "unknown commands are consumed silently", run = function()
  h.falsy(dispatch("/frobnicate", 42, date.to_days(2026, 10, 10)))
  h.falsy(dispatch("planning", 42, date.to_days(2026, 10, 10)), "no leading slash")
  h.falsy(dispatch("/plann", 42, date.to_days(2026, 10, 10)), "prefix is not enough")
  h.falsy(dispatch("/PLANNING", 42, date.to_days(2026, 10, 10)), "commands are lowercase")
end }

tests[#tests + 1] = { name = "updates that are not text messages are ignored", run = function()
  local ctx = { rows = ROWS, today_days = date.to_days(2026, 10, 10), allowed_chat_ids = { 42 } }
  h.falsy(commands.dispatch({ update_id = 1 }, ctx), "no message at all")
  h.falsy(commands.dispatch({ update_id = 1, message = { chat = { id = 42 } } }, ctx), "no text")
  h.falsy(commands.dispatch(nil, ctx))
  h.falsy(commands.dispatch({
    update_id = 1,
    message = { chat = { id = 42 }, text = "just chatting" },
  }, ctx), "text without a command")
end }

tests[#tests + 1] = { name = "unauthorized chats are consumed silently", run = function()
  h.falsy(dispatch("/planning", 999, date.to_days(2026, 10, 10)))
  h.falsy(dispatch("/help", 999, date.to_days(2026, 10, 10)))
  h.falsy(dispatch("/planning", 42, date.to_days(2026, 10, 10), ROWS, {}),
    "an empty allow-list denies everyone")
  h.falsy(dispatch("/planning", 42, date.to_days(2026, 10, 10), ROWS, { 1, 7 }),
    "a chat outside the list")
  -- Several ids may be allowed at once.
  h.truthy(dispatch("/planning", 7, date.to_days(2026, 10, 10), ROWS, { 1, 7 }))
end }

tests[#tests + 1] = { name = "the @bot suffix does not hide the command", run = function()
  h.matches("Ottobre 2026", dispatch("/planning@MioBot", 42, date.to_days(2026, 10, 10)))
  h.matches("Novembre 2026", dispatch("/planning@MioBot 2026-11", 42, date.to_days(2026, 10, 10)))
  h.falsy(dispatch("/frobnicate@MioBot", 42, date.to_days(2026, 10, 10)))
end }

tests[#tests + 1] = { name = "the reply depends only on the injected context", run = function()
  local october = dispatch("/planning", 42, date.to_days(2026, 10, 10))
  local november = dispatch("/planning", 42, date.to_days(2026, 11, 3))
  h.falsy(october == november, "a different today_days gives a different month")
  h.matches("Ottobre 2026", october)
  h.matches("Novembre 2026", november)
  -- Without the rows the dispatch declines rather than guessing.
  h.falsy(commands.dispatch({
    update_id = 101,
    message = { chat = { id = 42 }, text = "/planning" },
  }, { rows = nil, today_days = date.to_days(2026, 10, 10), allowed_chat_ids = { 42 } }))
end }

tests[#tests + 1] = { name = "a missing context is consumed silently", run = function()
  h.falsy(commands.dispatch({
    update_id = 101,
    message = { chat = { id = 42 }, text = "/planning" },
  }, nil))
end }

tests[#tests + 1] = { name = "extra arguments after a month are rejected", run = function()
  local reply = dispatch("/planning 2026-11 extra", 42, date.to_days(2026, 10, 10))
  h.truthy(type(reply) == "string")
  h.matches("Uso:", reply)
end }

return tests
