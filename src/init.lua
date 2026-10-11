local util = require("util")
local date = require("date")
local config_module = require("config")
local schedule = require("schedule")
local reminders = require("reminders")
local state_module = require("state")
local telegram = require("telegram")
local plan = require("plan")
local commands = require("commands")

local USAGE = [[
differenziata-bot - reminds you which trash to leave out

Usage: bin/differenziata-bot [options]

Options:
  -n, --dry-run          report what would be sent, send nothing
      --at TIME          pretend the current time is TIME (YYYY-MM-DDTHH:MM)
  -l, --list             print the upcoming calendar and exit
  -d, --days N           how many days to look ahead (default 14)
      --poll             answer Telegram commands (/planning, /help) once and exit
      --poll-timeout N   seconds a --poll may wait for updates (default 0: return at once)
      --test-send        send one test message and exit
      --config PATH      config file (default config.toml, then config.example.toml)
  -v, --verbose          log every step
  -h, --help             this text
]]

local function fail(message)
  io.stderr:write(message .. "\n")
  os.exit(1)
end

local function project_root()
  local from_env = os.getenv("DIFFERENZIATA_ROOT")
  if from_env and from_env ~= "" then
    return from_env
  end
  local dir = (arg[0] or ""):match("^(.*)/[^/]*$") or "."
  if dir == "src" then
    return "."
  end
  return dir:match("^(.*)/src$") or dir
end

local function parse_at(text)
  local date_part, time_part = text:match("^(%d%d%d%d%-%d%d%-%d%d)[T ](%d%d:%d%d)$")
  if not date_part then
    date_part = text:match("^(%d%d%d%d%-%d%d%-%d%d)$")
    time_part = "00:00"
  end
  if not date_part then
    return nil, string.format("--at: expected YYYY-MM-DDTHH:MM, got %q", text)
  end
  local year, month, day, err = date.parse(date_part)
  if not year then
    return nil, "--at: " .. err
  end
  local hour, minute, time_error = date.parse_time(time_part)
  if not hour then
    return nil, "--at: " .. time_error
  end
  local at = os.time({
    year = year, month = month, day = day, hour = hour, min = minute, sec = 0,
  })
  if not at then
    return nil, "--at: cannot resolve that local time"
  end
  return at
end

local function parse_options(argv)
  local options = {
    dry_run = false,
    list = false,
    poll = false,
    poll_timeout = nil,
    test_send = false,
    verbose = false,
    days = 14,
    config = nil,
    at = nil,
  }
  local index = 1
  while index <= #argv do
    local item = argv[index]
    if item == "-n" or item == "--dry-run" then
      options.dry_run = true
    elseif item == "-l" or item == "--list" then
      options.list = true
    elseif item == "--test-send" then
      options.test_send = true
    elseif item == "--poll" then
      options.poll = true
    elseif item == "--poll-timeout" then
      index = index + 1
      options.poll_timeout = tonumber(argv[index])
    elseif item:match("^%-%-poll-timeout=") then
      options.poll_timeout = tonumber(item:match("^%-%-poll-timeout=(.+)$"))
    elseif item == "-v" or item == "--verbose" then
      options.verbose = true
    elseif item == "-h" or item == "--help" then
      io.write(USAGE)
      os.exit(0)
    elseif item == "-d" or item == "--days" then
      index = index + 1
      options.days = tonumber(argv[index])
    elseif item:match("^%-%-days=") then
      options.days = tonumber(item:match("^%-%-days=(.+)$"))
    elseif item == "--config" then
      index = index + 1
      options.config = argv[index]
    elseif item:match("^%-%-config=") then
      options.config = item:match("^%-%-config=(.+)$")
    elseif item == "--at" then
      index = index + 1
      options.at = argv[index]
    elseif item:match("^%-%-at=") then
      options.at = item:match("^%-%-at=(.+)$")
    else
      io.stderr:write(string.format("unknown option %q\n\n", item))
      io.stderr:write(USAGE)
      os.exit(2)
    end
    index = index + 1
  end
  if not options.days or options.days < 1 then
    fail("--days must be a positive number")
  end
  if options.poll_timeout and (options.poll_timeout < 0 or options.poll_timeout % 1 ~= 0) then
    fail("--poll-timeout must be a non-negative whole number")
  end
  return options
end

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

local function print_calendar(pickups, today_days, reminders_config)
  local days_before = reminders.days_before(reminders_config)
  local times = table.concat(reminders_config.times, "/")
  local labels = {}
  for _, value in ipairs(days_before) do
    labels[#labels + 1] = string.format("%s %s", reminders.lead_phrase(value), times)
  end
  local reminder_summary = table.concat(labels, " | ")
  for _, pickup in ipairs(pickups) do
    local delta = pickup.days - today_days
    local relative = delta == 0 and "today" or string.format("+%dd", delta)
    io.write(string.format(
      "%s  %-6s  %s\n", date.format_days(pickup.days), relative, describe_kinds(pickup.kinds)
    ))
    io.write(string.format("           reminders: %s\n", reminder_summary))
  end
end

-- One-shot command poll: fetch new updates, answer the allowed ones, then
-- exit. This path never touches var/state.tsv, which belongs to the reminder
-- line alone.
local function run_poll(config, rows, options, now)
  local offset = 0
  local offset_text = util.read_file(config.runtime.offset_file)
  if offset_text then
    local trimmed = util.trim(offset_text)
    if trimmed:match("^%d+$") then
      offset = tonumber(trimmed) or 0
      -- A corrupt or absurd offset would silently skip updates; refuse it.
      if offset > 2 ^ 53 or offset ~= math.floor(offset) then
        fail("var/updates.offset: expected a whole number of at most 53 digits")
      end
    end
  end

  -- An empty allowed_chat_ids means "only the configured chat id".
  local allowed_chat_ids = {}
  if config_module.is_array(config.commands.allowed_chat_ids) then
    for _, id in ipairs(config.commands.allowed_chat_ids) do
      allowed_chat_ids[#allowed_chat_ids + 1] = id
    end
  end
  if #allowed_chat_ids == 0 then
    allowed_chat_ids = { tonumber(config.telegram.chat_id) }
  end

  local today = os.date("*t", now)
  local ctx = {
    rows = rows,
    today_days = date.to_days(today.year, today.month, today.day),
    allowed_chat_ids = allowed_chat_ids,
  }

  local timeout = options.poll_timeout or config.commands.poll_timeout_seconds
  util.log("polling for updates (offset %d, timeout %d)", offset, timeout)
  local updates, updates_error = telegram.get_updates(config.telegram, offset, timeout, 100)
  if not updates then
    fail(updates_error)
  end
  util.debug("got %d update(s)", #updates)

  local last_update_id = nil
  for _, update in ipairs(updates) do
    local reply = commands.dispatch(update, ctx)
    if reply then
      -- Reply to the chat that asked, not the configured one: a group command
      -- must be answered in the group.
      local message = update.message
      local reply_chat_id = message and message.chat and message.chat.id or nil
      for _, chunk in ipairs(plan.split(reply)) do
        local sent, send_error = telegram.send_message(config.telegram, chunk, options.dry_run, reply_chat_id)
        if not sent then
          -- Deliberately before advancing the offset: a failed send must be
          -- retried on the next tick, never dropped.
          fail(send_error)
        end
      end
    end
    if type(update.update_id) == "number" then
      last_update_id = update.update_id
    end
  end

  if last_update_id ~= nil then
    local new_offset = last_update_id + 1
    -- A dry run reads the stream but must not consume it: the next real tick
    -- has to see the same updates.
    if options.dry_run then
      util.log("offset %d -> %d would be written", offset, new_offset)
    else
      local dir = config.runtime.offset_file:match("^(.*)/[^/]*$")
      if dir and dir ~= "" then
        util.ensure_dir(dir)
      end
      local ok, write_error = util.write_file(config.runtime.offset_file, tostring(new_offset))
      if not ok then
        fail(write_error)
      end
      util.log("offset %d -> %d (%d update(s) processed)", offset, new_offset, #updates)
    end
  end
  return 0
end

local function main(argv)
  local options = parse_options(argv)
  util.VERBOSE = options.verbose

  local root = project_root()
  -- Credentials are only demanded when this run could actually post something,
-- so --list and --dry-run work on a fresh clone with no token configured.
  local sends_messages = not (options.dry_run or options.list)
  local config, config_error = config_module.load(options.config, root, {
    require_credentials = sends_messages,
  })
  if not config then
    fail(config_error)
  end
  util.debug("root: %s", root)
  util.debug("config: %s", config.config_path)
  util.debug("calendar: %s", config.calendar.csv)

  local rows, rows_error = schedule.load(config.calendar.csv)
  if not rows then
    fail(rows_error)
  end
  util.debug("loaded %d trash kinds", #rows)

  local now = os.time()
  if options.at then
    local parsed, err = parse_at(options.at)
    if not parsed then
      fail(err)
    end
    now = parsed
  end
  local today = os.date("*t", now)
  local today_days = date.to_days(today.year, today.month, today.day)
  local horizon = options.days + reminders.days_before(config.reminders)[1]

  local pickups = schedule.upcoming(rows, today_days, horizon)

  if options.list then
    print_calendar(pickups, today_days, config.reminders)
    return 0
  end

  if options.test_send then
    local message = string.format(
      "🗑 Differenziata: test dal bot, configurazione letta correttamente (%d tipi di rifiuto, %d raccolte nei prossimi %d giorni).",
      #rows, #pickups, options.days
    )
    local sent, send_error = telegram.send_message(config.telegram, message, options.dry_run)
    if not sent then
      fail(send_error)
    end
    util.log("test message %s", options.dry_run and "prepared" or "sent")
    if not options.dry_run then
      print(message)
    end
    return 0
  end

  if options.poll then
    return run_poll(config, rows, options, now)
  end

  local state = state_module.load(config.runtime.state_file)
  local grace = config.reminders.grace_minutes * 60
  local sent_count = 0
  local missed_count = 0
  local failed = false

  for _, pickup in ipairs(pickups) do
    local slots, slots_error = reminders.slots(config.reminders, pickup.days)
    if not slots then
      fail(slots_error)
    end
    for _, slot in ipairs(slots) do
      if state_module.is_settled(state, slot.key) then
        util.debug("skip %s (already dealt with)", slot.key)
      elseif now < slot.due_at then
        util.debug("skip %s (due at %s)", slot.key, os.date("%Y-%m-%d %H:%M", slot.due_at))
      elseif now > slot.due_at + grace then
        -- Recorded so the next cron tick does not report the same miss again.
        missed_count = missed_count + 1
        util.log("missed reminder %s (was due %s)", slot.key, os.date("%Y-%m-%d %H:%M", slot.due_at))
        if not options.dry_run then
          state_module.mark_missed(state, slot.key, now)
        end
      else
        local message = reminders.message(slot, pickup.kinds)
        local sent, send_error = telegram.send_message(config.telegram, message, options.dry_run)
        if sent then
          state_module.mark_sent(state, slot.key, now)
          sent_count = sent_count + 1
          util.log("reminder %s %s", slot.key, options.dry_run and "would be sent:" or "sent:")
          io.write(message .. "\n\n")
        else
          failed = true
          util.log("failed %s: %s", slot.key, send_error)
        end
      end
    end
  end

  -- A dry run must never touch the state file, otherwise --dry-run would mark
  -- reminders as dealt with and the real run would skip them.
  if (sent_count > 0 or missed_count > 0) and not options.dry_run then
    local dir = config.runtime.state_file:match("^(.*)/[^/]*$")
    if dir and dir ~= "" then
      util.ensure_dir(dir)
    end
    local ok, save_error = state_module.save(config.runtime.state_file, state, now)
    if not ok then
      fail(save_error)
    end
  end

  util.log(
    "run at %s: %d %s, %d missed, %d pickups in the next %d days",
    os.date("%Y-%m-%d %H:%M", now), sent_count,
    options.dry_run and "would be sent" or "sent",
    missed_count, #pickups, options.days
  )
  if failed then
    return 1
  end
  return 0
end

os.exit(main(arg or {}))