local h = require("helpers")
local state = require("state")

local tests = {}

local NOW = 1767225600 -- 2026-01-01T00:00:00Z

tests[#tests + 1] = { name = "a fresh state is empty and survives a missing file", run = function()
  local loaded = state.load("/nonexistent/var/state.tsv")
  h.eq(0, h.count(loaded.entries))
  h.eq(0, #loaded.order)
  h.falsy(state.was_sent(loaded, "anything"))
  h.eq("", state.serialize(loaded, NOW))
end }

tests[#tests + 1] = { name = "mark and reload round trip", run = function()
  local path = h.tmp_file("", ".tsv")
  local first = state.load(path)
  state.mark_sent(first, "2026-10-05|d1|11:30", NOW)
  state.mark_sent(first, "2026-10-05|d1|16:00", NOW + 60)
  h.truthy(state.save(path, first, NOW))
  local second = state.load(path)
  h.truthy(state.was_sent(second, "2026-10-05|d1|11:30"))
  h.truthy(state.was_sent(second, "2026-10-05|d1|16:00"))
  h.eq(NOW, second.entries["2026-10-05|d1|11:30"])
  h.falsy(state.was_sent(second, "2026-10-05|d1|20:30"))
end }

tests[#tests + 1] = { name = "marking twice does not duplicate a key", run = function()
  local ledger = state.new()
  state.mark_sent(ledger, "k", NOW)
  state.mark_sent(ledger, "k", NOW + 10)
  h.eq(1, #ledger.order)
  h.eq(NOW + 10, ledger.entries["k"])
  local lines = 0
  for _ in state.serialize(ledger, NOW):gmatch("[^\n]+") do
    lines = lines + 1
  end
  h.eq(1, lines)
end }

tests[#tests + 1] = { name = "a missed reminder is settled but not sent", run = function()
  local ledger = state.new()
  state.mark_missed(ledger, "2026-10-02|d1|11:30", NOW)
  h.truthy(state.was_missed(ledger, "2026-10-02|d1|11:30"))
  h.falsy(state.was_sent(ledger, "2026-10-02|d1|11:30"),
    "a miss must not count as a delivery, or it would hide the fact nothing was sent")
  h.truthy(state.is_settled(ledger, "2026-10-02|d1|11:30"),
    "but it must count as dealt with, so cron does not re-report it every 30 minutes")
  h.eq("missed|2026-10-02|d1|11:30", ledger.order[1])
end }

tests[#tests + 1] = { name = "a sent reminder is settled", run = function()
  local ledger = state.new()
  state.mark_sent(ledger, "k", NOW)
  h.truthy(state.is_settled(ledger, "k"))
  h.falsy(state.was_missed(ledger, "k"))
end }

tests[#tests + 1] = { name = "sent and missed for the same key coexist", run = function()
  -- A slot marked missed can still be delivered later if the pickup day is
  -- rescheduled, so the two records must not overwrite each other.
  local ledger = state.new()
  state.mark_missed(ledger, "k", NOW)
  state.mark_sent(ledger, "k", NOW + 60)
  h.truthy(state.was_sent(ledger, "k"))
  h.truthy(state.was_missed(ledger, "k"))
  h.eq(2, #ledger.order)
end }

tests[#tests + 1] = { name = "missed records are pruned like any other", run = function()
  local ledger = state.new()
  state.mark_missed(ledger, "old", NOW - 200 * 86400)
  state.mark_missed(ledger, "new", NOW)
  h.matches("new", state.serialize(ledger, NOW))
  h.falsy(state.serialize(ledger, NOW):find("old", 1, true))
end }

tests[#tests + 1] = { name = "a missed record survives a save and load", run = function()
  local path = h.tmp_file("", ".tsv")
  local first = state.new()
  state.mark_missed(first, "2026-10-02|d1|11:30", NOW)
  h.truthy(state.save(path, first, NOW))
  h.truthy(state.was_missed(state.load(path), "2026-10-02|d1|11:30"))
end }

tests[#tests + 1] = { name = "serialised output is sorted and stable", run = function()
  local ledger = state.new()
  state.mark_sent(ledger, "b", NOW)
  state.mark_sent(ledger, "a", NOW)
  state.mark_sent(ledger, "c", NOW)
  h.eq("a\t" .. NOW .. "\nb\t" .. NOW .. "\nc\t" .. NOW .. "\n", state.serialize(ledger, NOW))
end }

tests[#tests + 1] = { name = "old entries are pruned on save", run = function()
  local path = h.tmp_file("", ".tsv")
  local ledger = state.new()
  state.mark_sent(ledger, "ancient", NOW - 200 * 86400)
  state.mark_sent(ledger, "recent", NOW)
  state.save(path, ledger, NOW)
  h.matches("recent", h.read(path))
  h.falsy(h.read(path):find("ancient"))
  local reloaded = state.load(path)
  h.falsy(state.was_sent(reloaded, "ancient"))
end }

tests[#tests + 1] = { name = "corrupt lines are ignored instead of fatal", run = function()
  local path = h.tmp_file("garbage\nkey-without-tab\n\n2026-10-05|d1|11:30\t" .. NOW .. "\n")
  local loaded = state.load(path)
  h.eq(1, h.count(loaded.entries))
  h.truthy(state.was_sent(loaded, "2026-10-05|d1|11:30"))
  h.falsy(state.was_sent(loaded, "garbage"))
end }

return tests