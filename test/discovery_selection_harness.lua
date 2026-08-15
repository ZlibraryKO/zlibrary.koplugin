-- Which mirror does discovery settle on? Picking the single fastest every time lands the reader on
-- the same server on every sweep (the subtle half of the tw.101d.by report). _pickFastestRandom
-- spreads the choice over the fastest few instead, so it must:
--   * choose only from the k fastest, never a slow one
--   * still be able to pick any of those k (not collapse back to the single quickest)
--   * treat a mirror that reported no timing as slowest, and never mutate the caller's list
--
-- Drives the real _pickFastestRandom extracted from discovery.lua, with math.random stubbed so the
-- choice is observable.

local PLUGIN = assert(arg[1], "usage: luajit discovery_selection_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

-- math.random is stubbed per case to return a chosen index into the top-k; math.huge is real.
local forced_index = 1
local function build()
    return support.extract_function(PLUGIN .. "/zlibrary/discovery.lua", "_pickFastestRandom", {
        type = type,
        ipairs = ipairs,
        table = table,
        math = { huge = math.huge, min = math.min, random = function(n) return math.min(forced_index, n) end },
    })
end
local pick = build()

local function cands(...)
    local t = {}
    for _, e in ipairs({...}) do t[#t + 1] = { url = e[1], elapsed = e[2] } end
    return t
end

-- ---------------------------------------------------------------- empty / degenerate
r.check("no candidates -> nil", pick({}, 5) == nil, "expected nil")
forced_index = 1
r.check("a single candidate is returned", pick(cands({ "a", 10 }), 5) == "a", "expected a")

-- ---------------------------------------------------------------- picks within the fastest k
-- Unsorted input; the three fastest are b(5), d(8), a(10) in that order; e(20),c(30) must be unreachable.
local list = cands({ "a", 10 }, { "c", 30 }, { "b", 5 }, { "e", 20 }, { "d", 8 })
forced_index = 1
r.check("index 1 -> the fastest", pick(list, 3) == "b", "got " .. tostring(pick(list, 3)))
forced_index = 2
r.check("index 2 -> the second fastest", pick(list, 3) == "d", "got " .. tostring(pick(list, 3)))
forced_index = 3
r.check("index 3 -> the third fastest", pick(list, 3) == "a", "got " .. tostring(pick(list, 3)))

-- The slow ones are never in the running: even asking for index 5, random() is clamped to k=3.
forced_index = 5
r.check("a slower mirror outside the top-k is never chosen",
        pick(list, 3) == "a", "a slow mirror leaked in: " .. tostring(pick(list, 3)))

-- ---------------------------------------------------------------- k larger than the list
forced_index = 4
r.check("k beyond the list size is clamped to the list",
        pick(cands({ "a", 10 }, { "b", 5 }), 5) == "a",
        "expected the slower of the two at index 2 (clamped)")

-- ---------------------------------------------------------------- missing timings sort last
forced_index = 1
local with_nil = cands({ "slow", 100 })
with_nil[#with_nil + 1] = { url = "untimed" } -- no elapsed
with_nil[#with_nil + 1] = { url = "fast", elapsed = 5 }
r.check("a mirror with a real timing beats one with none",
        pick(with_nil, 1) == "fast", "got " .. tostring(pick(with_nil, 1)))
forced_index = 3
r.check("a mirror with no timing sorts last",
        pick(with_nil, 3) == "untimed", "got " .. tostring(pick(with_nil, 3)))

-- ---------------------------------------------------------------- does not mutate the caller's list
forced_index = 1
local original = cands({ "a", 10 }, { "b", 5 })
pick(original, 5)
r.check("the caller's list is left in its original order",
        original[1].url == "a" and original[2].url == "b", "the input list was reordered")

r.finish()
