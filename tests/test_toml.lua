local h = require("helpers")
local toml = require("toml")

local tests = {}

local function parse(text)
  return toml.parse(text)
end

tests[#tests + 1] = { name = "scalars", run = function()
  local config = parse([[
str = "hello"
literal = 'raw \n stays'
int = 42
negative = -7
float = 1.5
exp = 2e3
hex = 0xff
yes = true
no = false
]])
  h.eq("hello", config.str)
  h.eq("raw \\n stays", config.literal)
  h.eq(42, config.int)
  h.eq(-7, config.negative)
  h.eq(1.5, config.float)
  h.eq(2000, config.exp)
  h.eq(255, config.hex)
  h.eq(true, config.yes)
  h.eq(false, config.no)
end }

-- [==[ ]==] rather than [[ ]] so the TOML escapes below are not themselves
-- interpreted by the Lua lexer.
tests[#tests + 1] = { name = "escapes and unicode", run = function()
  local config = parse([==[a = "line\nnext\ttab \"quoted\" back\\slash"
b = "è \U0001F5D1"
c = "é"
]==])
  h.eq("line\nnext\ttab \"quoted\" back\\slash", config.a)
  h.eq("\195\168 \240\159\151\145", config.b, "U+1F5D1 encoded as UTF-8")
  h.eq("é", config.c, "\\u00e9 decodes to the same bytes as a literal")
end }

tests[#tests + 1] = { name = "tables and dotted keys", run = function()
  local config = parse([[
[telegram]
token = "abc"
chat_id = "-100"

[reminders.cron]
schedule = "*/30 * * * *"

[runtime]
paths.state = "var/state.tsv"
paths.log = "var/log"
]])
  h.eq("abc", config.telegram.token)
  h.eq("-100", config.telegram.chat_id)
  h.eq("*/30 * * * *", config.reminders.cron.schedule)
  h.eq("var/state.tsv", config.runtime.paths.state)
  h.eq("var/log", config.runtime.paths.log)
end }

-- A nested array is spelled out as a Lua table here so the TOML literal does not
-- contain "]]", which would close the Lua long string holding the fixture.
tests[#tests + 1] = { name = "arrays", run = function()
  local config = parse([[
times = ["11:30", "16:00"]
multi = [
  1,
  2,   # trailing comment inside an array
  3,
]
empty = []
]])
  h.eq({ "11:30", "16:00" }, config.times)
  h.eq({ 1, 2, 3 }, config.multi)
  h.eq({}, config.empty)
  local nested = parse("nested = [ [1, 2], [3] ]")
  h.eq({ { 1, 2 }, { 3 } }, nested.nested)
end }

-- The array-of-tables fixture is concatenated rather than written inline,
-- because "[[servers]]" inside a Lua long string would close it early.
tests[#tests + 1] = { name = "inline tables and table arrays", run = function()
  local config = parse(
    'inline = { a = 1, b = { c = "x" } }\n'
    .. '[[servers]]\nname = "one"\n'
    .. '[[servers]]\nname = "two"\n'
  )
  h.eq(1, config.inline.a)
  h.eq("x", config.inline.b.c)
  h.eq(2, #config.servers)
  h.eq("one", config.servers[1].name)
  h.eq("two", config.servers[2].name)
end }

tests[#tests + 1] = { name = "comments and whitespace", run = function()
  local config = parse([[
# leading comment

key = "v"  # trailing comment
  spaced   =   1

# another
]])
  h.eq("v", config.key)
  h.eq(1, config.spaced)
end }

tests[#tests + 1] = { name = "errors are reported with a line number", run = function()
  h.errors(function() parse("a = 1\na = 2\n") end, "line 2")
  h.errors(function() parse("a = 1\nb\n") end, "line 2")
  h.errors(function() parse("a = \"unterminated\n") end, "line 1")
  h.errors(function() parse("[t]\nx = 1\n[t]\n") end, "duplicate table")
  h.errors(function() parse("= 1\n") end, "invalid key")
  h.errors(function() parse("a = @nope\n") end, "unexpected value")
  h.errors(function() parse("a = [1, 2\n") end, "expected")
  h.errors(function() parse("a = 1\n[a.b]\nc = 2\n") end, "is not a table")
  h.errors(function() parse("[a.b]\nc = 1\n[a]\nd = 2\n") end, "duplicate table")
end }

tests[#tests + 1] = { name = "load reads files and strips the BOM", run = function()
  local path = h.tmp_file("\239\187\191[telegram]\ntoken = \"x\"\n")
  local config, err = toml.load(path)
  h.truthy(config, err)
  h.eq("x", config.telegram.token)
  local missing, missing_error = toml.load("/nonexistent/config.toml")
  h.falsy(missing)
  h.matches("cannot open", missing_error)
end }

tests[#tests + 1] = { name = "the shipped example config parses and validates", run = function()
  local config, err = toml.load("config.example.toml")
  h.truthy(config, err)
  h.eq({ "11:30", "16:00", "20:30" }, config.reminders.times)
  h.eq(1, config.reminders.days_before)
  h.eq("*/30 * * * *", config.cron.schedule)
  h.eq("schedule.csv", config.calendar.csv)
end }

return tests