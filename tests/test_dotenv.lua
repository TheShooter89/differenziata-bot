local h = require("helpers")
local dotenv = require("dotenv")

local tests = {}

tests[#tests + 1] = { name = "bare key=value pairs", run = function()
  local values, err = dotenv.parse("TELEGRAM_TOKEN=123:abc\nTELEGRAM_CHAT_ID=42\n")
  h.truthy(values, err)
  h.eq("123:abc", values.TELEGRAM_TOKEN)
  h.eq("42", values.TELEGRAM_CHAT_ID)
end }

tests[#tests + 1] = { name = "quoted values keep their spaces and hash", run = function()
  local values = dotenv.parse('A="value with spaces"\nB=\'single quoted\'\nC="has # hash"\n')
  h.eq("value with spaces", values.A)
  h.eq("single quoted", values.B)
  h.eq("has # hash", values.C, "a # inside quotes is data, not a comment")
end }

tests[#tests + 1] = { name = "an unquoted value is trimmed and comment-stripped", run = function()
  local values = dotenv.parse("A=  spaced out  # trailing note\nB=bare   # note\n")
  h.eq("spaced out", values.A)
  h.eq("bare", values.B)
end }

tests[#tests + 1] = { name = "export prefix is accepted", run = function()
  local values = dotenv.parse("export TELEGRAM_TOKEN=123:abc\nexport  A=1\n")
  h.eq("123:abc", values.TELEGRAM_TOKEN)
  h.eq("1", values.A)
end }

tests[#tests + 1] = { name = "comments and blank lines are skipped", run = function()
  local values = dotenv.parse("# leading\n\n  # indented comment\nA=1\n\n\nB=2\n")
  h.eq("1", values.A)
  h.eq("2", values.B)
  h.eq(2, h.count(values))
end }

tests[#tests + 1] = { name = "an empty value is allowed", run = function()
  local values = dotenv.parse("A=\nB=   \n")
  h.eq("", values.A)
  h.eq("", values.B)
end }

tests[#tests + 1] = { name = "values may contain equals signs", run = function()
  local values = dotenv.parse("A=x=y=z\n")
  h.eq("x=y=z", values.A)
end }

tests[#tests + 1] = { name = "no trailing newline on the last line", run = function()
  local values = dotenv.parse("A=1\nB=2")
  h.eq("2", values.B)
end }

tests[#tests + 1] = { name = "CRLF and a BOM are handled", run = function()
  local values = dotenv.parse("\239\187\191A=1\r\nB=2\r\n")
  h.eq("1", values.A)
  h.eq("2", values.B)
end }

tests[#tests + 1] = { name = "the last definition of a key wins", run = function()
  local values = dotenv.parse("A=first\nA=second\n")
  h.eq("second", values.A)
end }

tests[#tests + 1] = { name = "a token is not mangled by the parse", run = function()
  local token = "123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw"
  local values = dotenv.parse("TELEGRAM_TOKEN=" .. token .. "\n")
  h.eq(token, values.TELEGRAM_TOKEN)
end }

tests[#tests + 1] = { name = "malformed lines are reported with their line number", run = function()
  local _, err = dotenv.parse("A=1\nthis is not a pair\n")
  h.matches("line 2", err)
  h.matches("expected KEY=value", err)
  local _, unterminated = dotenv.parse('A="never closed\n')
  h.matches("unterminated", unterminated)
end }

tests[#tests + 1] = { name = "keys tolerate dots and dashes", run = function()
  local values = dotenv.parse("my.key=1\nmy-key=2\n_underscore=3\n")
  h.eq("1", values["my.key"])
  h.eq("2", values["my-key"])
  h.eq("3", values._underscore)
end }

tests[#tests + 1] = { name = "load returns empty for a missing file", run = function()
  local values, err = dotenv.load("/nonexistent/.env")
  h.truthy(values, err)
  h.eq(0, h.count(values), "a missing .env is not an error")
end }

tests[#tests + 1] = { name = "load reads a file from disk", run = function()
  local path = h.tmp_file("# comment\nTELEGRAM_TOKEN=1:a\nTELEGRAM_CHAT_ID=2\n", ".env")
  local values, err = dotenv.load(path)
  h.truthy(values, err)
  h.eq("1:a", values.TELEGRAM_TOKEN)
  h.eq("2", values.TELEGRAM_CHAT_ID)
end }

tests[#tests + 1] = { name = "the shipped .env.example parses and is detectable as a placeholder", run = function()
  local values, err = dotenv.load(".env.example")
  h.truthy(values, err)
  h.matches("REPLACE_WITH", values.TELEGRAM_TOKEN)
  h.matches("REPLACE_WITH", values.TELEGRAM_CHAT_ID)
end }

return tests