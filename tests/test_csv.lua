local h = require("helpers")
local csv = require("csv")

local tests = {}

local function read(text)
  local path = h.tmp_file(text, ".csv")
  local data, err = csv.read(path)
  if not data then
    error(err, 2)
  end
  return data
end

tests[#tests + 1] = { name = "basic rows and header normalisation", run = function()
  local data = read("Name,Emoji ,Week Day\ncarta,x,monday\n")
  h.eq({ "name", "emoji", "week_day" }, data.header)
  h.eq(1, #data.rows)
  h.eq("carta", data.rows[1].name)
  h.eq("monday", data.rows[1].week_day)
end }

tests[#tests + 1] = { name = "comments, blank lines and CRLF", run = function()
  local data = read("# comment\r\n\r\nname,day\r\ncarta,monday\r\n\r\n# trailing comment\r\nvetro,thursday\r\n")
  h.eq(2, #data.rows)
  h.eq("carta", data.rows[1].name)
  h.eq("vetro", data.rows[2].name)
end }

tests[#tests + 1] = { name = "quoted fields, embedded commas and doubled quotes", run = function()
  local data = read('name,notes\n"secco / non riciclabile","a, b ""c"" d"\n')
  h.eq("secco / non riciclabile", data.rows[1].name)
  h.eq('a, b "c" d', data.rows[1].notes)
end }

tests[#tests + 1] = { name = "missing trailing fields become empty strings", run = function()
  local data = read("a,b,c\n1,2\n")
  h.eq("", data.rows[1].c)
  local data2 = read("a,b,c\n1,,3\n")
  h.eq("", data2.rows[1].b)
end }

tests[#tests + 1] = { name = "emoji and utf-8 survive", run = function()
  -- 💩️ is U+1F4A9 followed by the variation selector U+FE0F: four bytes for the
  -- code point plus three more, which the CSV reader must not split or trim.
  local poo = "\240\159\146\169\239\184\143\143"
  local data = read("name,emoji\numido," .. poo .. "\n")
  h.eq(poo, data.rows[1].emoji, "the full emoji sequence comes back byte for byte")
  h.eq(8, #data.rows[1].emoji)
end }

tests[#tests + 1] = { name = "BOM is stripped", run = function()
  local data = read("\239\187\191name,day\ncarta,monday\n")
  h.eq("name", data.header[1])
  h.eq("carta", data.rows[1].name)
end }

tests[#tests + 1] = { name = "empty file is an error", run = function()
  h.errors(function() read("# only comments\n") end, "no header row")
  local missing, err = csv.read("/nonexistent/schedule.csv")
  h.falsy(missing)
  h.matches("cannot open", err)
end }

tests[#tests + 1] = { name = "the shipped calendar parses", run = function()
  local data = read(h.read("schedule.csv"))
  h.eq(5, #data.rows)
end }

return tests