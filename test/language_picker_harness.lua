-- Does the multi-select picker stay usable once the language list is ~190 long?
--
-- Two problems come with the long list, and this covers both:
--
--  1. Your current choices scatter across a dozen pages. The picker hoists already-selected
--     entries to the top, so a handful of choices are not lost among the rest. The order is set
--     when the list is (re)built -- on open and on a filter change, never on a toggle -- so an
--     entry never jumps out from under the finger that just tapped it.
--
--  2. Finding a language means paging or knowing KOReader's half-hidden type-jump, which only
--     matches a prefix of the *shown* text and stops at the first hit ("ish" lands on Cornish,
--     never Irish; "japanese" never finds 日本語). The picker adds a visible title-bar search that
--     filters by substring against the display name AND the API value -- so "ish" finds Irish and
--     "japanese" finds 日本語. Short lists (formats, order) do not get the search.
--
-- Drives the real _showMultiSelectionDialog with a captured Menu and InputDialog, so the item
-- order, the search affordance and the filtering asserted are what the widget actually does.

local PLUGIN = assert(arg[1], "usage: luajit language_picker_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local function make()
    local rig = { saved = {}, typed = "" }
    local env = {
        pairs = pairs, ipairs = ipairs, table = table, string = string,
        type = type, tostring = tostring,
        T = function(s) return s end,
        util = { trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end },
        logger = { err = function() end },
        UIManager = { show = function() end, close = function() end },
        _showAndTrackDialog = function(m) rig.shown = m end,
        _closeAndUntrackDialog = function() end,
    }
    env.Config = {
        getSetting = function(_, default) return rig.saved or default end,
        saveSetting = function() end,
        deleteSetting = function() end,
    }
    env.Ui = { showInfoMessage = function() end }
    env.InputDialog = {
        new = function(_, spec)
            rig.input_dialog = spec
            return { getInputText = function() return rig.typed end, onShowKeyboard = function() end }
        end,
    }
    env.Menu = {
        new = function(_, spec)
            spec.updateItems = function() end
            spec.switchItemTable = function(self, new_title, items)
                self.title = new_title
                self.item_table = items
            end
            rig.spec = spec
            return spec
        end,
    }

    local pick = support.extract_function(PLUGIN .. "/zlibrary/ui.lua", "_showMultiSelectionDialog", env)
    rig.open = function(options, saved, is_single)
        rig.saved = saved or {}
        rig.spec = nil
        pick({}, "Pick", "some_key", options, nil, is_single)
        return rig.spec
    end
    -- Tap the title-bar search, type a query, press one of its buttons.
    local function press(label)
        for _, btn in ipairs(rig.input_dialog.buttons[1]) do
            if btn.text == label then btn.callback(); return end
        end
        error("no button labelled " .. label)
    end
    rig.filter = function(text)
        rig.typed = text
        rig.spec.onLeftButtonTap()
        press("Filter")
        return rig.spec.item_table
    end
    rig.showAll = function()
        rig.spec.onLeftButtonTap()
        press("Show all")
        return rig.spec.item_table
    end
    return rig
end

local function names(items)
    local t = {}
    for _, it in ipairs(items) do t[#t + 1] = it.text end
    return t
end
local function order(items) return table.concat(names(items), ",") end
local function has(items, name)
    for _, it in ipairs(items) do if it.text == name then return it end end
    return nil
end

local rig = make()
local SMALL = (function()
    local t = {}
    for _, v in ipairs({ "a", "b", "c", "d", "e" }) do t[#t + 1] = { name = v, value = v } end
    return t
end)()

-- A list long enough to earn the search, with the two cases the built-in type-jump fails on: a
-- substring that is not a prefix (Irish/Cornish share "ish"), and a native name reachable only by
-- its English value (日本語 / japanese).
local BIG = (function()
    local t = {}
    for i = 1, 40 do t[#t + 1] = { name = "Filler" .. i, value = "filler" .. i } end
    t[#t + 1] = { name = "Irish", value = "irish" }
    t[#t + 1] = { name = "Cornish", value = "cornish" }
    t[#t + 1] = { name = "日本語", value = "japanese" }
    -- Name and value diverge: "portug" is only in the name, "brazil" only in the value. Between
    -- them these pin that BOTH are matched, and as a substring rather than a prefix.
    t[#t + 1] = { name = "Brazilian Portuguese", value = "brazilian" }
    return t
end)()

-- ---------------------------------------------------------------- hoist, on a short list
do
    local m = rig.open(SMALL, {})
    r.check("nothing selected keeps the given order", order(m.item_table) == "a,b,c,d,e",
            "got " .. order(m.item_table))
    r.check("a short list gets no search icon", m.title_bar_left_icon == nil,
            "got " .. tostring(m.title_bar_left_icon))
end
do
    local m = rig.open(SMALL, { "c", "a" })
    r.check("selected entries hoist to the top, in list order", order(m.item_table) == "a,c,b,d,e",
            "got " .. order(m.item_table))
    r.check("hoisted entries read as selected",
            m.item_table[1].mandatory_func() == "[X]" and m.item_table[2].mandatory_func() == "[X]",
            "a=" .. m.item_table[1].mandatory_func() .. " c=" .. m.item_table[2].mandatory_func())
    r.check("and the rest read as unselected", m.item_table[3].mandatory_func() == "[ ]",
            "b=" .. m.item_table[3].mandatory_func())
end
do
    local m = rig.open(SMALL, { "c" }, true)
    r.check("a single-select (radio) list is not reordered", order(m.item_table) == "a,b,c,d,e",
            "got " .. order(m.item_table))
    r.check("and gets no search icon", m.title_bar_left_icon == nil,
            "got " .. tostring(m.title_bar_left_icon))
end

-- ---------------------------------------------------------------- the search, on a long list
do
    local m = rig.open(BIG, {})
    r.check("a long list gets a title-bar search icon", m.title_bar_left_icon == "appbar.search",
            "got " .. tostring(m.title_bar_left_icon))
    r.check("and shows everything until filtered", #m.item_table == #BIG,
            #m.item_table .. " of " .. #BIG .. " shown")
end

do
    rig.open(BIG, {})
    local items = rig.filter("ish")
    -- The exact case KOReader's prefix type-jump misses.
    r.check("a substring filter finds Irish by 'ish'", has(items, "Irish") ~= nil,
            "Irish not in the filtered list")
    r.check("and also the other 'ish' match, Cornish", has(items, "Cornish") ~= nil,
            "Cornish not in the filtered list")
    r.check("and drops the non-matching rows", has(items, "Filler1") == nil,
            "a non-matching row survived the filter")
    r.check("the filtered list is just the matches", #items == 2, #items .. " rows, expected 2")
end

do
    rig.open(BIG, {})
    -- Native name, English value: only the value match can find it.
    local items = rig.filter("japanese")
    r.check("a native-script name is found by its English value", has(items, "日本語") ~= nil,
            "日本語 not found by typing 'japanese'")
    r.check("and nothing else matches that query", #items == 1, #items .. " rows, expected 1")
end

do
    rig.open(BIG, {})
    -- A word in the middle of the display name, absent from the value: only a name substring
    -- match reaches it. This is the everyday case a prefix-only match would miss.
    local items = rig.filter("portug")
    r.check("a mid-name substring is matched", has(items, "Brazilian Portuguese") ~= nil,
            "'portug' did not find Brazilian Portuguese")
    r.check("only via the name here, so exactly one row", #items == 1, #items .. " rows, expected 1")
end

do
    rig.open(BIG, {})
    -- Typing in any case finds the same rows: query and targets are both lowercased.
    r.check("the filter is case-insensitive (UPPER)", has(rig.filter("IRISH"), "Irish") ~= nil,
            "'IRISH' did not find Irish")
    rig.open(BIG, {})
    r.check("the filter is case-insensitive (Mixed)", has(rig.filter("IrIsH"), "Irish") ~= nil,
            "'IrIsH' did not find Irish")
end

do
    rig.open(BIG, {})
    rig.filter("ish")
    local items = rig.showAll()
    r.check("Show all restores the full list", #items == #BIG, #items .. " of " .. #BIG)
    r.check("and clears the filter title back to the plain one", rig.spec.title == "Pick",
            "title left as " .. tostring(rig.spec.title))
end

do
    rig.open(BIG, {})
    local items = rig.filter("zzzznotalanguage")
    r.check("a query that matches nothing yields an empty list, not a crash", #items == 0,
            #items .. " rows for a no-match query")
end

-- ---------------------------------------------------------------- filter meets selection
do
    -- Irish selected. Filter to the "ish" matches: the selected one still hoists above the rest,
    -- and it still reads as selected -- the selection lives in state, not in the visible rows.
    rig.open(BIG, { "irish" })
    local items = rig.filter("ish")
    r.check("within a filter, a selected match still hoists first", order(items) == "Irish,Cornish",
            "got " .. order(items))
    r.check("and the selection survives the rebuild", has(items, "Irish").mandatory_func() == "[X]",
            "the selected row lost its tick after filtering")
end

-- ---------------------------------------------------------------- the real language table
-- Nearly 200 hand-generatable rows: a duplicate value would send a language twice and show it
-- twice; an empty field would render a blank, unselectable row. Cheap to assert, easy to break.
do
    local src = (function()
        local fh = assert(io.open(PLUGIN .. "/zlibrary/config.lua"))
        local s = fh:read("*a"); fh:close(); return s
    end)()
    local block = src:match("SUPPORTED_LANGUAGES = (%b{})")
    r.check("SUPPORTED_LANGUAGES can be located and parsed", block ~= nil)

    local langs = assert(loadstring("return " .. block))()
    r.check("the list covers the endpoint, not just the old subset", #langs >= 180,
            "only " .. #langs .. " languages -- generation truncated?")

    local seen_value, seen_name, dup_value, dup_name, empty, padded = {}, {}, 0, 0, 0, 0
    for _, e in ipairs(langs) do
        if type(e.name) ~= "string" or e.name == "" or type(e.value) ~= "string" or e.value == "" then
            empty = empty + 1
        end
        if e.value and e.value ~= (e.value:gsub("^%s+", ""):gsub("%s+$", "")) then padded = padded + 1 end
        if seen_value[e.value] then dup_value = dup_value + 1 end
        if seen_name[e.name] then dup_name = dup_name + 1 end
        seen_value[e.value], seen_name[e.name] = true, true
    end
    r.check("no entry has an empty name or value", empty == 0, empty .. " blank entr(ies)")
    r.check("no value carries stray whitespace", padded == 0,
            padded .. " value(s) with leading/trailing space -- the API matches these verbatim")
    r.check("every value is unique", dup_value == 0,
            dup_value .. " duplicate value(s) -- a language would be sent and shown twice")
    r.check("every display name is unique", dup_name == 0, dup_name .. " duplicate name(s)")

    local kept = { english = false, arabic = false, ["traditional chinese"] = false,
                   japanese = false, telugu = false }
    for _, e in ipairs(langs) do
        if kept[e.value] ~= nil then kept[e.value] = true end
    end
    local missing = {}
    for v, present in pairs(kept) do
        if not present then missing[#missing + 1] = v end
    end
    r.check("the previously-supported languages are all still there", #missing == 0,
            "dropped: " .. table.concat(missing, ", "))
end

r.finish()
