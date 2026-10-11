-- Telegram Bot API over curl. curl is used instead of LuaSocket because
-- LuaSocket does not verify TLS by default, which is not acceptable for a
-- client that carries a bot token.
local util = require("util")
local json = require("json")

local M = {}

-- Masks the whole credential, not just its numeric prefix: the secret half must
-- never reach a log, on sendMessage or getUpdates.
local function redact(url)
  return (url:gsub("/bot[^/'%s]*", "/bot<token>"))
end

local function build_command(config, method, fields, max_time, get)
  local url = string.format(
    "%s/bot%s/%s", config.api_base:gsub("/+$", ""), config.token, method
  )
  local parts = {
    "curl", "--silent", "--show-error",
  }
  -- Without --get, --data-urlencode makes curl POST. getUpdates is a read, so
  -- the same encoded fields are sent as a query string instead.
  if get then
    parts[#parts + 1] = "--get"
  end
  parts[#parts + 1] = string.format("--max-time %d", max_time or (tonumber(config.timeout_seconds) or 20))
  parts[#parts + 1] = string.format("--retry %d", tonumber(config.retries) or 2)
  parts[#parts + 1] = "--retry-delay 2"
  -- Every argument is quoted, including the name=value payload: message text
  -- routinely contains spaces, parentheses and emoji that a shell would
  -- otherwise mangle or try to interpret.
  for name, value in pairs(fields) do
    parts[#parts + 1] = util.shell_quote("--data-urlencode")
    parts[#parts + 1] = util.shell_quote(string.format("%s=%s", name, tostring(value)))
  end
  parts[#parts + 1] = util.shell_quote(url)
  return table.concat(parts, " ")
end

-- The raw response body, without judging it: a caller that needs the payload
-- (getUpdates) must inspect it itself.
local function request_raw(config, method, fields, max_time, get)
  local command = build_command(config, method, fields, max_time, get)
  util.debug("telegram: %s", redact(command))
  local pipe = io.popen(command, "r")
  if not pipe then
    return nil, "cannot spawn curl"
  end
  local body = pipe:read("a") or ""
  local ok, _, code = pipe:close()
  if not ok then
    return nil, string.format("curl exited with status %s", tostring(code))
  end
  return body
end

local function request(config, method, fields)
  local body, err = request_raw(config, method, fields)
  if not body then
    return nil, err
  end
  if not body:find('"ok"%s*:%s*true') then
    local description = body:match('"description"%s*:%s*"(.-)"')
    return nil, string.format(
      "telegram API refused the request%s", description and (": " .. description) or ""
    )
  end
  return true
end

-- Takes the [telegram] table rather than the whole config, so a caller cannot
-- accidentally pass the wrong shape and get a nil field inside curl's argv.
-- chat_id, when given, replies to that chat instead of the configured one, so a
-- command is answered where it was asked.
function M.send_message(telegram_config, text, dry_run, chat_id)
  if dry_run then
    return true
  end
  chat_id = chat_id or tostring(telegram_config.chat_id)
  return request(telegram_config, "sendMessage", {
    chat_id = tostring(chat_id),
    text = text,
    disable_web_page_preview = "true",
  })
end

function M.get_me(telegram_config)
  return request(telegram_config, "getMe", {})
end

local function is_list(value)
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
  return count == #value
end

-- One-shot getUpdates for the poller. timeout 0 returns at once; a long poll
-- must outlive curl's own timeout or the tick is wasted, so the HTTP timeout
-- is raised above the poll timeout (and still bounded, so a hung socket can
-- never wedge the cron tick forever).
function M.get_updates(config, offset, timeout, limit)
  local max_time = math.max(
    tonumber(config.timeout_seconds) or 20,
    (tonumber(timeout) or 0) + 10
  )
  local body, err = request_raw(config, "getUpdates", {
    offset = tostring(offset),
    timeout = tostring(timeout),
    limit = tostring(limit),
    allowed_updates = '["message"]',
  }, max_time, true)
  if not body then
    return nil, err
  end
  local value, decode_error = json.decode(body)
  if decode_error then
    return nil, decode_error
  end
  if type(value) ~= "table" or value.ok ~= true then
    local description
    if type(value) == "table" and type(value.description) == "string" then
      description = value.description
    end
    return nil, string.format(
      "telegram API refused the request%s", description and (": " .. description) or ""
    )
  end
  if not is_list(value.result) then
    return nil, "getUpdates: result is not a list of updates"
  end
  return value.result
end

return M