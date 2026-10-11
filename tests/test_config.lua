local h = require("helpers")
local config = require("config")
local util = require("util")

local tests = {}

local VALID = [[
[telegram]
token = "123456:abcdef"
chat_id = "42"

[reminders]
days_before = 1
times = ["11:30", "16:00", "20:30"]
grace_minutes = 120

[cron]
schedule = "*/30 * * * *"
]]

local function load(text, options)
  local path = text and h.tmp_file(text, ".toml") or "/nonexistent/config.toml"
  return config.load(path, "/project", options or { require_credentials = false })
end

tests[#tests + 1] = { name = "a minimal config keeps the defaults", run = function()
  local loaded, err = load(VALID)
  h.truthy(loaded, err)
  h.eq("123456:abcdef", loaded.telegram.token)
  h.eq("42", loaded.telegram.chat_id)
  h.eq("https://api.telegram.org", loaded.telegram.api_base)
  h.eq("*/30 * * * *", loaded.cron.schedule)
  h.eq({ "11:30", "16:00", "20:30" }, loaded.reminders.times)
end }

tests[#tests + 1] = { name = "relative paths resolve next to the config file", run = function()
  local path = h.tmp_file(VALID, ".toml")
  local loaded = config.load(path, "/ignored/root", { require_credentials = true })
  h.truthy(loaded)
  local dir = path:match("^(.*)/[^/]*$")
  h.eq(dir .. "/schedule.csv", loaded.calendar.csv)
  h.eq(dir .. "/var/state.tsv", loaded.runtime.state_file)
end }

tests[#tests + 1] = { name = "absolute paths in the config are left alone", run = function()
  local loaded = config.load(h.tmp_file(VALID .. '\n[calendar]\ncsv = "/srv/data/calendar.csv"\n', ".toml"),
    "/ignored/root", { require_credentials = true })
  h.truthy(loaded)
  h.eq("/srv/data/calendar.csv", loaded.calendar.csv)
end }

tests[#tests + 1] = { name = "an empty file yields the shipped defaults", run = function()
  local loaded, err = load("")
  h.truthy(loaded, err)
  h.eq({ "11:30", "16:00", "20:30" }, loaded.reminders.times)
  h.eq(1, loaded.reminders.days_before)
  h.eq(120, loaded.reminders.grace_minutes)
  h.eq("*/30 * * * *", loaded.cron.schedule)
end }

tests[#tests + 1] = { name = "days_before may be a list", run = function()
  local multi = load([[
[telegram]
token = "1:a"
chat_id = "2"
[reminders]
days_before = [2, 1, 0]
times = ["08:00"]
]])
  h.truthy(multi)
  h.eq({ 2, 1, 0 }, multi.reminders.days_before)
  h.eq({ "08:00" }, multi.reminders.times)
end }

tests[#tests + 1] = { name = "a missing config file is a clear error", run = function()
  local loaded, err = load(nil)
  h.falsy(loaded)
  h.matches("/nonexistent/config.toml", err)
end }

tests[#tests + 1] = { name = "a syntax error keeps the file and line", run = function()
  local loaded, err = load("[telegram]\ntoken =\n")
  h.falsy(loaded)
  h.matches("toml: line 2", err)
  h.matches("unexpected value", err)
end }

tests[#tests + 1] = { name = "credentials are only required when messages are sent", run = function()
  local ok_without, err_without = load("")
  h.truthy(ok_without, err_without)
  local strict, err = load("", { require_credentials = true })
  h.falsy(strict)
  h.matches("no bot token", err)
  h.matches("TELEGRAM_TOKEN", err, "the error names the variable, not the toml key")
  local bad_token, bad_token_error = load([[
[telegram]
token = "not-a-token"
chat_id = "1"
]], { require_credentials = true })
  h.falsy(bad_token)
  h.matches("does not look like a bot token", bad_token_error)
end }

tests[#tests + 1] = { name = "validation rejects unusable values", run = function()
  local cases = {
    {
      [[
[telegram]
token = "1:a"
chat_id = ""
]], "no chat id",
    },
    {
      [[
[telegram]
token = "1:a"
chat_id = "1"
[reminders]
times = ["25:00"]
]], "time out of range",
    },
    {
      [[
[telegram]
token = "1:a"
chat_id = "1"
[reminders]
times = []
]], "times must be a non-empty list",
    },
    {
      [[
[telegram]
token = "1:a"
chat_id = "1"
[reminders]
days_before = -1
]], "days_before must be",
    },
    {
      [[
[telegram]
token = "1:a"
chat_id = "1"
[reminders]
days_before = "tomorrow"
]], "days_before must be",
    },
    {
      [[
[telegram]
token = "1:a"
chat_id = "1"
[cron]
schedule = "*/30 * * *"
]], "5 whitespace-separated",
    },
    {
      [[
[telegram]
token = "1:a"
chat_id = "abc"
]], "TELEGRAM_CHAT_ID must be a number",
    },
    {
      [[
[telegram]
token = "1:a"
chat_id = "1"
[commands]
poll_timeout_seconds = 301
]], "no larger than 300",
    },
    {
      [[
[telegram]
token = "1:a"
chat_id = "1"
[telegram]
token = "2:b"
]], "duplicate table",
    },
  }
  for index, case in ipairs(cases) do
    local loaded, err = load(case[1], { require_credentials = true })
    h.falsy(loaded, "case " .. index .. " should have failed")
    h.matches(case[2], err, "case " .. index)
  end
end }

-- Copies the shipped example into a scratch dir so the assertions cannot be
-- influenced by a developer's own .env sitting next to it.
local function load_example_in_scratch()
  local dir = h.tmp_dir()
  h.write(dir .. "/config.toml", h.read("config.example.toml"))
  return dir .. "/config.toml"
end

tests[#tests + 1] = { name = "the shipped example config is settings-only", run = function()
  local path = load_example_in_scratch()
  local loaded, err = config.load(path, "/ignored", { require_credentials = false })
  h.truthy(loaded, err)
  -- The token lives in .env now, so the example toml must not carry credentials.
  h.eq("", loaded.telegram.token)
  h.eq("", loaded.telegram.chat_id)
  h.eq("*/30 * * * *", loaded.cron.schedule)

  local strict, strict_error = config.load(path, "/ignored", { require_credentials = true })
  h.falsy(strict, "with no .env beside it, an unedited example must not be usable")
  h.matches("no bot token", strict_error)
end }

tests[#tests + 1] = { name = "an unedited .env is rejected as a placeholder", run = function()
  -- What a fresh clone looks like after `cp .env.example .env` without editing.
  local dir = h.tmp_dir()
  h.write(dir .. "/config.toml", h.read("config.example.toml"))
  h.write(dir .. "/.env", h.read(".env.example"))
  local loaded, err = config.load(dir .. "/config.toml", "/ignored", { require_credentials = true })
  h.falsy(loaded)
  h.matches("REPLACE_WITH", err)
  h.matches("placeholder", err)
end }

tests[#tests + 1] = { name = "shell_quote survives hostile input", run = function()
  h.eq("'plain'", util.shell_quote("plain"))
  h.eq("'it'\\''s'", util.shell_quote("it's"))
  h.eq("'$(rm -rf /)'", util.shell_quote("$(rm -rf /)"))
  h.eq("'a\nb'", util.shell_quote("a\nb"))
  h.eq("'🍾'", util.shell_quote("🍾"))
end }

tests[#tests + 1] = { name = "small string helpers", run = function()
  h.eq("abc", util.trim("  abc  "))
  h.eq({ "a", "b", "c" }, util.split("a:b:c", ":"))
  h.eq({ "2026-10-05" }, util.split("2026-10-05", " "))
end }

return tests