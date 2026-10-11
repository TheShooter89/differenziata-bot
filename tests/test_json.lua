local h = require("helpers")
local json = require("json")

local tests = {}

tests[#tests + 1] = { name = "decodes objects, arrays and literals", run = function()
  local value = json.decode('{"a": 1, "b": [true, false], "c": {}}')
  h.eq(1, value.a)
  h.eq(2, #value.b)
  h.truthy(value.b[1])
  h.falsy(value.b[2])
  h.eq({}, value.c)
  local literal = json.decode("[null]")
  h.falsy(literal[1])
end }

tests[#tests + 1] = { name = "decodes strings with escapes", run = function()
  local value = json.decode('["a\\tb", "quo\\"te", "back\\\\slash", "sl/ash"]')
  h.eq("a\tb", value[1])
  h.eq('quo"te', value[2])
  h.eq("back\\slash", value[3])
  h.eq("sl/ash", value[4])
end }

tests[#tests + 1] = { name = "decodes unicode escapes and surrogate pairs", run = function()
  h.eq(utf8.char(0xE9), json.decode('"\\u00e9"'))
  h.eq(utf8.char(0x1F600), json.decode('"\\ud83d\\ude00"'))
  h.eq(utf8.char(0x2603), json.decode('"\\u2603"'))
end }

tests[#tests + 1] = { name = "rejects lone surrogates", run = function()
  local high, high_err = json.decode('"\\ud83d"')
  h.falsy(high)
  h.matches("surrogate", high_err)
  local low, low_err = json.decode('"\\ude00"')
  h.falsy(low)
  h.matches("surrogate", low_err)
  local mismatch, mismatch_err = json.decode('"\\ud83d\\u0041"')
  h.falsy(mismatch)
  h.matches("low surrogate", mismatch_err)
end }

tests[#tests + 1] = { name = "decodes numbers", run = function()
  local value = json.decode("[0, -17, 3.5, 1e3, -2.5E-2]")
  h.eq({ 0, -17, 3.5, 1000, -0.025 }, value)
  h.eq(42, json.decode("42"))
  h.eq(-0.5, json.decode("-0.5"))
end }

tests[#tests + 1] = { name = "rejects malformed numbers", run = function()
  for _, text in ipairs({ "[01]", "[1.]", "[1e]", "[+1]", "[.5]" }) do
    local value, err = json.decode(text)
    h.falsy(value, text)
    h.matches("number", err, text)
  end
end }

tests[#tests + 1] = { name = "decodes a 30-digit integer without truncating it", run = function()
  -- A decoder that slices a fixed number of characters would cut this short and
  -- leave the rest as trailing garbage, or silently decode the wrong value.
  local value, err = json.decode("123456789012345678901234567890")
  h.falsy(err, err)
  h.eq("number", type(value))
  h.truthy(value > 1e29, "the whole 30-digit number is decoded")
end }

tests[#tests + 1] = { name = "tolerates whitespace between tokens", run = function()
  local value = json.decode('{\n\t"a"  :  [ 1 , 2 ]\r\n}')
  h.eq({ 1, 2 }, value.a)
end }

tests[#tests + 1] = { name = "rejects trailing garbage", run = function()
  local value, err = json.decode('{"a":1} {"b":2}')
  h.falsy(value)
  h.matches("trailing garbage", err)
  h.falsy(json.decode("{},"))
  h.matches("trailing garbage", select(2, json.decode("[1] ]")))
end }

tests[#tests + 1] = { name = "rejects malformed input with a message", run = function()
  for _, text in ipairs({ "{", "[1,", '{"a"}', '{"a":1,}', "nul", "[,]", "" }) do
    local value, err = json.decode(text)
    h.falsy(value, text)
    h.truthy(err and #err > 0, text)
  end
  local no_string, no_string_err = json.decode(nil)
  h.falsy(no_string)
  h.truthy(no_string_err)
end }

tests[#tests + 1] = { name = "decodes a getUpdates payload", run = function()
  local text = '{"ok":true,"result":[{"update_id":101,"message":{"chat":{"id":999},"text":"/planning"}}]}'
  local value = json.decode(text)
  h.truthy(value.ok)
  h.eq(1, #value.result)
  h.eq(101, value.result[1].update_id)
  h.eq(999, value.result[1].message.chat.id)
  h.eq("/planning", value.result[1].message.text)
end }

tests[#tests + 1] = { name = "rejects unreasonably deep nesting", run = function()
  local text = string.rep("[", 200) .. string.rep("]", 200)
  local value, err = json.decode(text)
  h.falsy(value)
  h.matches("too deep", err)
end }

return tests
