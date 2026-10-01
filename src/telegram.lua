-- Telegram Bot API over curl. curl is used instead of LuaSocket because
-- LuaSocket does not verify TLS by default, which is not acceptable for a
-- client that carries a bot token.
local util = require("util")

local M = {}

local function redact(url)
  return (url:gsub("/bot%d+:", "/bot<token>:"))
end

local function build_command(config, method, fields)
  local url = string.format(
    "%s/bot%s/%s", config.api_base:gsub("/+$", ""), config.token, method
  )
  local parts = {
    "curl", "--silent", "--show-error",
    string.format("--max-time %d", tonumber(config.timeout_seconds) or 20),
    string.format("--retry %d", tonumber(config.retries) or 2),
    "--retry-delay 2",
  }
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

local function request(config, method, fields)
  local command = build_command(config, method, fields)
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
function M.send_message(telegram_config, text, dry_run)
  if dry_run then
    return true
  end
  return request(telegram_config, "sendMessage", {
    chat_id = tostring(telegram_config.chat_id),
    text = text,
    disable_web_page_preview = "true",
  })
end

function M.get_me(telegram_config)
  return request(telegram_config, "getMe", {})
end

return M