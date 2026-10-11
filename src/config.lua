local toml = require("toml")
local dotenv = require("dotenv")
local util = require("util")
local date = require("date")

local M = {}

M.DEFAULT_CONFIG_PATH = "config.toml"
M.EXAMPLE_CONFIG_PATH = "config.example.toml"
M.EXAMPLE_ENV_PATH = ".env.example"

M.defaults = {
  telegram = {
    token = "",
    chat_id = "",
    api_base = "https://api.telegram.org",
  },
  reminders = {
    days_before = 1,
    times = { "11:30", "16:00", "20:30" },
    grace_minutes = 120,
  },
  calendar = {
    csv = "schedule.csv",
  },
  runtime = {
    state_file = "var/state.tsv",
    offset_file = "var/updates.offset",
  },
  cron = {
    schedule = "*/30 * * * *",
  },
  commands = {
    poll_schedule = "* * * * *",
    poll_timeout_seconds = 0,
    allowed_chat_ids = {},
  },
}

local function copy(value)
  if type(value) == "table" then
    local out = {}
    for key, item in pairs(value) do
      out[key] = copy(item)
    end
    return out
  end
  return value
end

-- An empty table is deliberately not an array: it is a table with no keys, and
-- treating it as a list would let `times = []` or a `[telegram]` section holding
-- only comments wipe the defaults instead of leaving them in place.
local function is_array(value)
  if type(value) ~= "table" then
    return false
  end
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" then
      return false
    end
    count = count + 1
  end
  return count > 0 and count == #value
end

-- Only named sub-tables are merged key by key. A list in the user config always
-- replaces the default list wholesale, otherwise `times = ["08:00"]` would be
-- appended to the default three times instead of replacing them.
local function merge(base, override)
  for key, value in pairs(override) do
    if type(value) == "table" and type(base[key]) == "table" and not is_array(value)
      and not is_array(base[key]) then
      base[key] = merge(base[key], value)
    else
      base[key] = copy(value)
    end
  end
  return base
end

M.is_array = is_array

local function validate(config, require_credentials)
  local telegram = config.telegram
  if not require_credentials then
    return true
  end
  -- Credential errors name the variable the user actually sets, never the toml key,
  -- because the value does not live in config.toml any more.
  if type(telegram.token) ~= "string" or telegram.token == "" then
    return nil, "no bot token: set TELEGRAM_TOKEN in " .. config.env_path
  end
  if not telegram.token:match("^%d+:") then
    return nil, "TELEGRAM_TOKEN does not look like a bot token (expected digits then ':')"
  end
  if tostring(telegram.chat_id) == "" then
    return nil, "no chat id: set TELEGRAM_CHAT_ID in " .. config.env_path
  end
  -- Catches an unedited .env.example, which would otherwise post to a
  -- non-existent chat and fail with a confusing API error instead.
  if telegram.token:upper():find("REPLACE") or tostring(telegram.chat_id):upper():find("REPLACE") then
    return nil, "telegram credentials still contain the REPLACE_WITH... placeholder "
      .. "from .env.example (edit " .. config.env_path .. ")"
  end
  -- Negative ids are groups and channels; anything non-numeric is a typo.
  if not tostring(telegram.chat_id):match("^%-?%d+$") then
    return nil, "TELEGRAM_CHAT_ID must be a number"
  end
  if not tostring(telegram.api_base):match("^https?://") then
    return nil, "telegram.api_base must start with http:// or https://"
  end

  local reminders = config.reminders
  local function valid_day_count(value)
    return type(value) == "number" and value >= 0 and value % 1 == 0
  end
  if is_array(reminders.days_before) then
    if #reminders.days_before == 0 then
      return nil, "reminders.days_before is an empty list"
    end
    for _, value in ipairs(reminders.days_before) do
      if not valid_day_count(value) then
        return nil, "reminders.days_before must hold non-negative whole numbers"
      end
    end
  elseif not valid_day_count(reminders.days_before) then
    return nil, "reminders.days_before must be a non-negative whole number or a list of them"
  end
  if type(reminders.times) ~= "table" or not is_array(reminders.times) or #reminders.times == 0 then
    return nil, "reminders.times must be a non-empty list of HH:MM strings"
  end
  for _, value in ipairs(reminders.times) do
    if type(value) ~= "string" then
      return nil, "reminders.times must hold HH:MM strings"
    end
    local hour, time_error = date.parse_time(value)
    if not hour then
      return nil, "reminders.times: " .. time_error
    end
  end
  if type(reminders.grace_minutes) ~= "number" or reminders.grace_minutes < 0 then
    return nil, "reminders.grace_minutes must be a non-negative number"
  end

  if type(config.calendar.csv) ~= "string" or config.calendar.csv == "" then
    return nil, "calendar.csv must be a path"
  end
  if type(config.runtime.state_file) ~= "string" or config.runtime.state_file == "" then
    return nil, "runtime.state_file must be a path"
  end
  local function valid_cron(value)
    return type(value) == "string"
      and value:match("^%S+%s+%S+%s+%S+%s+%S+%s+%S+$") ~= nil
  end
  if not valid_cron(config.cron.schedule) then
    return nil, "cron.schedule must be exactly 5 whitespace-separated cron fields"
  end

  local commands = config.commands
  if type(commands) ~= "table" then
    return nil, "commands must be a table"
  end
  if not valid_cron(commands.poll_schedule) then
    return nil, "commands.poll_schedule must be exactly 5 whitespace-separated cron fields"
  end
  if type(commands.poll_timeout_seconds) ~= "number"
    or commands.poll_timeout_seconds < 0
    or commands.poll_timeout_seconds % 1 ~= 0 then
    return nil, "commands.poll_timeout_seconds must be a non-negative whole number"
  end
  -- A long poll must stay well inside the cron tick that spawned it.
  if commands.poll_timeout_seconds > 300 then
    return nil, "commands.poll_timeout_seconds must be no larger than 300"
  end
  if type(commands.allowed_chat_ids) ~= "table" then
    return nil, "commands.allowed_chat_ids must be a list of chat ids"
  end
  if is_array(commands.allowed_chat_ids) then
    for _, id in ipairs(commands.allowed_chat_ids) do
      if type(id) ~= "number" then
        return nil, "commands.allowed_chat_ids must hold chat ids (numbers)"
      end
    end
  elseif next(commands.allowed_chat_ids) ~= nil then
    -- An empty table means "only the configured chat id"; a non-empty
    -- non-list is a mistake worth reporting.
    return nil, "commands.allowed_chat_ids must be a list of chat ids"
  end
  if type(config.runtime.offset_file) ~= "string" or config.runtime.offset_file == "" then
    return nil, "runtime.offset_file must be a path"
  end
  return true
end

function M.load(path, root, options)
  options = options or {}
  local config = copy(M.defaults)
  local used = path or os.getenv("DIFFERENZIATA_CONFIG")
  if not used or used == "" then
    used = M.DEFAULT_CONFIG_PATH
    -- Falling back to the example lets a fresh clone run --dry-run and --list
    -- before anyone has filled in a token.
    if not util.file_exists(used) then
      used = M.EXAMPLE_CONFIG_PATH
    end
  end
  local user, err = toml.load(used)
  if not user then
    return nil, err
  end
  merge(config, user)

  -- Relative paths resolve against the directory holding the config file, not
  -- the current working directory, so the bot behaves the same under cron as it
  -- does in a shell. An absolute path is left untouched.
  local base = used:match("^(.*)/[^/]*$")
  if not base or base == "" then
    base = "."
  end

  local function resolve(path)
    if path:sub(1, 1) == "/" then
      return path
    end
    return base .. "/" .. path
  end

  -- Credentials come from three layers, lowest priority first: config.toml, then
  -- .env, then a real exported variable. The last one wins so `TELEGRAM_TOKEN=x
  -- bin/differenziata-bot` overrides the file for a single run.
  local env_path = os.getenv(dotenv.ENV_PATH_VARIABLE)
  if not env_path or env_path == "" then
    env_path = resolve(dotenv.DEFAULT_ENV_PATH)
  end
  local secrets, env_error = dotenv.load(env_path)
  if not secrets then
    return nil, env_error
  end

  local function resolve_secret(name, current)
    local from_file = secrets[name]
    if from_file and from_file ~= "" then
      current = from_file
    end
    local from_env = os.getenv(name)
    if from_env and from_env ~= "" then
      current = from_env
    end
    return current
  end

  config.telegram.token = resolve_secret("TELEGRAM_TOKEN", config.telegram.token)
  config.telegram.chat_id = resolve_secret("TELEGRAM_CHAT_ID", config.telegram.chat_id)
  config.env_path = env_path

  config.calendar.csv = resolve(config.calendar.csv)
  config.runtime.state_file = resolve(config.runtime.state_file)
  config.runtime.offset_file = resolve(config.runtime.offset_file)
  config.config_path = used
  config.root = root or base

  local ok, validation_error = validate(config, options.require_credentials ~= false)
  if not ok then
    -- A credentials failure names .env itself in its message, so prefixing the
    -- config path again would read as "config.toml: ... edit ./.env".
    if validation_error:find("TELEGRAM") or validation_error:find("placeholder") then
      return nil, validation_error
    end
    return nil, string.format("%s: %s", used, validation_error)
  end
  return config
end

return M