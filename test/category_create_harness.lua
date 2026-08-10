-- The post-download "New category…" path and the alphabetical sort.
--
-- Two behaviours that are easy to get subtly wrong:
--
--   * _createCategoryTarget turns two typed names into a move target, creating the category/
--     sub-category as needed. The rule that matters: a name that ALREADY EXISTS is reused, not an
--     error -- typing "Fiction" when Fiction exists should just file into it. But a genuine failure
--     (any reason other than "exists") must abort, so the book is not filed somewhere unintended.
--   * _sortedCategories / _sortedNames sort case-insensitively and must not reorder the caller's
--     list (the stored order is what the mutation helpers rewrite; only the display is sorted).
--
-- Drives the real functions extracted from ui.lua.

local PLUGIN = assert(arg[1], "usage: luajit category_create_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local UI = PLUGIN .. "/zlibrary/ui.lua"

-- ---------------------------------------------------------------- sorting
do
    local env = { table = table, ipairs = ipairs }
    local sortedCategories = support.extract_function(UI, "_sortedCategories", env)
    local sortedNames = support.extract_function(UI, "_sortedNames", env)

    local cats = { { name = "banana" }, { name = "Apple" }, { name = "cherry" } }
    local out = sortedCategories(cats)
    r.check("categories sort case-insensitively by name",
            out[1].name == "Apple" and out[2].name == "banana" and out[3].name == "cherry",
            "order: " .. table.concat({ out[1].name, out[2].name, out[3].name }, ","))
    r.check("sorting leaves the caller's list untouched",
            cats[1].name == "banana" and cats[2].name == "Apple",
            "the input list was reordered in place")

    local names = { "Zed", "alpha", "Beta" }
    local nout = sortedNames(names)
    r.check("child names sort case-insensitively",
            nout[1] == "alpha" and nout[2] == "Beta" and nout[3] == "Zed",
            "order: " .. table.concat(nout, ","))
    r.check("sorting names leaves the caller's list untouched",
            names[1] == "Zed", "the input list was reordered in place")
end

-- ---------------------------------------------------------------- _createCategoryTarget
-- A Config double whose add* return values are scripted per case, plus a sanitiser matching the real
-- rule (trim + strip path-unsafe chars) so an empty/whitespace name behaves as it will in the app.
local function newRig(opts)
    opts = opts or {}
    local rec = { added = {}, added_sub = {} }
    local Config = {
        sanitizeCategoryName = function(s)
            if type(s) ~= "string" then return "" end
            return (s:gsub("^%s*(.-)%s*$", "%1"):gsub("[/\\?%*:|\"<>%c]", "_"))
        end,
        addCategory = function(name)
            table.insert(rec.added, name)
            if opts.addCategory_result ~= nil then
                return opts.addCategory_result, opts.addCategory_reason
            end
            return true
        end,
        addSubcategory = function(parent, name)
            table.insert(rec.added_sub, { parent = parent, name = name })
            if opts.addSub_result ~= nil then
                return opts.addSub_result, opts.addSub_reason
            end
            return true
        end,
    }
    rec.fn = support.extract_function(UI, "_createCategoryTarget", {
        Config = Config,
        T = function(s) return s end,
        _categoryError = function(reason) return "err:" .. tostring(reason) end,
    })
    return rec
end

-- Empty / whitespace parent: refused before anything is created.
do
    local rec = newRig()
    local target, err = rec.fn("   ", "")
    r.check("an empty parent is refused with a message",
            target == nil and type(err) == "string", "target = " .. tostring(target))
    r.check("nothing is created for an empty parent", #rec.added == 0,
            "addCategory ran " .. #rec.added .. " times")
end

-- A fresh top-level name.
do
    local rec = newRig()
    local target = rec.fn("Fiction", "")
    r.check("a new parent yields a top-level target",
            target ~= nil and target.name == "Fiction" and target.sub == nil,
            "target = " .. tostring(target and target.name))
end

-- Existing parent: reused, not an error. This is the whole point of the create flow accepting a
-- name that already exists.
do
    local rec = newRig({ addCategory_result = false, addCategory_reason = "exists" })
    local target = rec.fn("Fiction", "")
    r.check("an existing parent is reused rather than erroring",
            target ~= nil and target.name == "Fiction",
            "target = " .. tostring(target))
end

-- A genuine addCategory failure (any other reason) must abort.
do
    local rec = newRig({ addCategory_result = false, addCategory_reason = "weird" })
    local target, err = rec.fn("Fiction", "")
    r.check("a non-exists addCategory failure aborts",
            target == nil and err == "err:weird",
            "target = " .. tostring(target) .. ", err = " .. tostring(err))
end

-- Parent + sub creates the sub and returns a nested target.
do
    local rec = newRig()
    local target = rec.fn("Fiction", "Romance")
    r.check("parent + sub yields a nested target",
            target ~= nil and target.name == "Fiction" and target.sub == "Romance",
            "target = " .. tostring(target and (target.name .. "/" .. tostring(target.sub))))
    r.check("the sub-category is created under the parent",
            #rec.added_sub == 1 and rec.added_sub[1].parent == "Fiction"
                and rec.added_sub[1].name == "Romance",
            "added_sub = " .. #rec.added_sub)
end

-- Existing sub: reused.
do
    local rec = newRig({ addSub_result = false, addSub_reason = "exists" })
    local target = rec.fn("Fiction", "Romance")
    r.check("an existing sub-category is reused rather than erroring",
            target ~= nil and target.sub == "Romance", "target = " .. tostring(target))
end

-- A genuine addSubcategory failure aborts, and the book is not filed.
do
    local rec = newRig({ addSub_result = false, addSub_reason = "weird" })
    local target, err = rec.fn("Fiction", "Romance")
    r.check("a non-exists addSubcategory failure aborts",
            target == nil and err == "err:weird",
            "target = " .. tostring(target) .. ", err = " .. tostring(err))
end

r.finish()
