-- The list of recent searches: newest first, no repeats, and never longer than ten.

local PLUGIN = assert(arg[1], "usage: luajit search_history_harness.lua <plugin-root>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()
local SearchHistory = dofile(PLUGIN .. "/zlibrary/search_history.lua")

local function joined(list) return table.concat(list, ",") end

local history = SearchHistory.add({}, "dune")
history = SearchHistory.add(history, "emma")
r.check("the newest search comes first", joined(history) == "emma,dune", joined(history))

history = SearchHistory.add(history, "Dune")
r.check("a repeat moves to the top, as typed this time", joined(history) == "Dune,emma", joined(history))

local full = {}
for i = 1, 15 do full = SearchHistory.add(full, "q" .. i) end
r.check("only the last ten are kept", #full == 10 and full[1] == "q15" and full[10] == "q6", joined(full))

r.check("removing ignores case", joined(SearchHistory.remove({ "Dune", "emma" }, "dune")) == "emma",
    joined(SearchHistory.remove({ "Dune", "emma" }, "dune")))
r.check("removing something absent changes nothing", joined(SearchHistory.remove({ "emma" }, "dune")) == "emma",
    joined(SearchHistory.remove({ "emma" }, "dune")))

r.finish()
