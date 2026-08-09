-- Download categories: do the storage helpers keep the list consistent?
--
-- Categories are names that become folders under the download dir, so the rules that matter are the
-- ones that keep the list clean and unambiguous:
--
--   * a missing or corrupt setting reads back as an empty list, never a crash
--   * a name is sanitised to a safe folder segment before it is stored, and a name that sanitises
--     away to nothing is refused -- otherwise it would map to the download folder itself
--   * names are unique within their scope (top level, or within one parent), because the name is
--     the picker's identity and the folder's name
--   * removing a category takes its sub-categories with it; renaming is guarded against colliding
--     with an existing name
--
-- Drives the real Config helpers extracted from config.lua; the getSetting/saveSetting they build on
-- (covered by base_url_harness) are stubbed over a plain table, and util.trim is the real rule.

local PLUGIN = assert(arg[1], "usage: luajit categories_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local CONFIG = PLUGIN .. "/zlibrary/config.lua"

-- All the category helpers plus the module-local findCategoryIndex they share, compiled into one
-- chunk so the locals resolve. Each extracted block stops short of its closing 'end', so each gets
-- its own appended back.
local function compile(Config)
    local function blk(pattern) return support.extract_block(CONFIG, pattern) .. "end\n" end
    local body =
        blk("(\nfunction Config%.sanitizeCategoryName%(.-\n)end\n") ..
        blk("(\nlocal function findCategoryIndex%(.-\n)end\n") ..
        blk("(\nfunction Config%.setCategories%(.-\n)end\n") ..
        blk("(\nfunction Config%.getCategories%(.-\n)end\n") ..
        blk("(\nfunction Config%.addCategory%(.-\n)end\n") ..
        blk("(\nfunction Config%.addSubcategory%(.-\n)end\n") ..
        blk("(\nfunction Config%.renameCategory%(.-\n)end\n") ..
        blk("(\nfunction Config%.renameSubcategory%(.-\n)end\n") ..
        blk("(\nfunction Config%.removeCategory%(.-\n)end\n") ..
        blk("(\nfunction Config%.removeSubcategory%(.-\n)end\n")
    local chunk = assert(loadstring("local Config = ...\n" .. body .. "return Config", "=categories"))
    setfenv(chunk, {
        type = type,
        ipairs = ipairs,
        table = table,
        -- The real trim (config.lua uses util.trim); the strip of illegal chars is in the source.
        util = { trim = function(s) return s:match("^%s*(.-)%s*$") end },
    })
    return chunk(Config)
end

local function newRig(initial)
    local rig = { store = { zlibrary_categories = initial } }
    local Config = {
        SETTINGS_CATEGORIES_KEY = "zlibrary_categories",
        getSetting = function(key)
            return rig.store[key]
        end,
        saveSetting = function(key, value) rig.store[key] = value end,
    }
    rig.Config = compile(Config)
    return rig
end

-- ---------------------------------------------------------------- reads default to an empty list
do
    local empty = newRig(nil).Config.getCategories()
    r.check("no setting reads back as an empty list",
            type(empty) == "table" and #empty == 0, "got " .. tostring(empty))

    local corrupt = newRig("not a table").Config.getCategories()
    r.check("a corrupt (non-table) setting reads back as an empty list",
            type(corrupt) == "table" and #corrupt == 0, "got " .. tostring(corrupt))
end

-- ---------------------------------------------------------------- setCategories: non-table -> {}
do
    local rig = newRig(nil)
    rig.Config.setCategories("nonsense")
    r.check("setCategories stores a non-table as an empty table, not the value",
            type(rig.store.zlibrary_categories) == "table" and #rig.store.zlibrary_categories == 0,
            "stored " .. tostring(rig.store.zlibrary_categories))
end

-- ---------------------------------------------------------------- addCategory
do
    local rig = newRig(nil)
    local ok = rig.Config.addCategory("Fiction")
    local list = rig.Config.getCategories()
    r.check("addCategory accepts a fresh name", ok == true, "returned " .. tostring(ok))
    r.check("the category is stored with an empty children list",
            #list == 1 and list[1].name == "Fiction" and type(list[1].children) == "table"
                and #list[1].children == 0,
            "list = " .. tostring(list[1] and list[1].name))

    local ok2, reason2 = rig.Config.addCategory("Fiction")
    r.check("a duplicate top-level name is refused",
            ok2 == false and reason2 == "exists", "returned " .. tostring(ok2) .. "," .. tostring(reason2))
    r.check("and the list is left at one entry",
            #rig.Config.getCategories() == 1, "list grew to " .. #rig.Config.getCategories())

    local ok3, reason3 = rig.Config.addCategory("   ")
    r.check("a whitespace-only name (sanitises to empty) is refused",
            ok3 == false and reason3 == "empty", "returned " .. tostring(ok3) .. "," .. tostring(reason3))
end

-- Names are sanitised into safe folder segments before storage.
do
    local rig = newRig(nil)
    rig.Config.addCategory("  Sci/Fi:2000  ")
    local list = rig.Config.getCategories()
    r.check("the stored name is trimmed and stripped of path-unsafe characters",
            #list == 1 and list[1].name == "Sci_Fi_2000",
            "stored name = " .. tostring(list[1] and list[1].name))
end

-- ---------------------------------------------------------------- addSubcategory
do
    local rig = newRig(nil)
    rig.Config.addCategory("Fiction")

    local ok = rig.Config.addSubcategory("Fiction", "Romance")
    r.check("addSubcategory accepts a fresh name under a real parent", ok == true,
            "returned " .. tostring(ok))
    r.check("the sub-category is stored under its parent",
            #rig.Config.getCategories()[1].children == 1
                and rig.Config.getCategories()[1].children[1] == "Romance",
            "children = " .. tostring(rig.Config.getCategories()[1].children[1]))

    local ok2, reason2 = rig.Config.addSubcategory("Fiction", "Romance")
    r.check("a duplicate sub-category name is refused",
            ok2 == false and reason2 == "exists",
            "returned " .. tostring(ok2) .. "," .. tostring(reason2))

    local ok3, reason3 = rig.Config.addSubcategory("Nonexistent", "X")
    r.check("adding under an unknown parent is refused",
            ok3 == false and reason3 == "no_parent",
            "returned " .. tostring(ok3) .. "," .. tostring(reason3))

    local ok4, reason4 = rig.Config.addSubcategory("Fiction", "  ")
    r.check("a sub-category that sanitises to empty is refused",
            ok4 == false and reason4 == "empty",
            "returned " .. tostring(ok4) .. "," .. tostring(reason4))
end

-- ---------------------------------------------------------------- renameCategory
do
    local rig = newRig(nil)
    rig.Config.addCategory("Fiction")
    rig.Config.addCategory("Comics")

    local ok = rig.Config.renameCategory("Fiction", "Novels")
    r.check("renameCategory renames in place", ok == true and rig.Config.getCategories()[1].name == "Novels",
            "name = " .. tostring(rig.Config.getCategories()[1].name))

    local ok2, reason2 = rig.Config.renameCategory("Novels", "Comics")
    r.check("renaming onto an existing name is refused",
            ok2 == false and reason2 == "exists",
            "returned " .. tostring(ok2) .. "," .. tostring(reason2))

    local ok3 = rig.Config.renameCategory("Novels", "Novels")
    r.check("renaming to the same name is allowed (a no-op, not a self-collision)", ok3 == true,
            "returned " .. tostring(ok3))

    local ok4, reason4 = rig.Config.renameCategory("Missing", "Whatever")
    r.check("renaming an unknown category is refused",
            ok4 == false and reason4 == "not_found",
            "returned " .. tostring(ok4) .. "," .. tostring(reason4))
end

-- ---------------------------------------------------------------- renameSubcategory
do
    local rig = newRig(nil)
    rig.Config.addCategory("Fiction")
    rig.Config.addSubcategory("Fiction", "Romance")
    rig.Config.addSubcategory("Fiction", "Sci-Fi")

    local ok = rig.Config.renameSubcategory("Fiction", "Romance", "Love")
    r.check("renameSubcategory renames in place",
            ok == true and rig.Config.getCategories()[1].children[1] == "Love",
            "children[1] = " .. tostring(rig.Config.getCategories()[1].children[1]))

    local ok2, reason2 = rig.Config.renameSubcategory("Fiction", "Love", "Sci-Fi")
    r.check("renaming a sub-category onto a sibling name is refused",
            ok2 == false and reason2 == "exists",
            "returned " .. tostring(ok2) .. "," .. tostring(reason2))

    local ok3, reason3 = rig.Config.renameSubcategory("Fiction", "Nope", "X")
    r.check("renaming an unknown sub-category is refused",
            ok3 == false and reason3 == "not_found",
            "returned " .. tostring(ok3) .. "," .. tostring(reason3))
end

-- ---------------------------------------------------------------- removeCategory / removeSubcategory
do
    local rig = newRig(nil)
    rig.Config.addCategory("Fiction")
    rig.Config.addSubcategory("Fiction", "Romance")
    rig.Config.addCategory("Comics")

    local ok = rig.Config.removeCategory("Fiction")
    local list = rig.Config.getCategories()
    r.check("removeCategory drops the category and its sub-categories",
            ok == true and #list == 1 and list[1].name == "Comics",
            "remaining = " .. tostring(list[1] and list[1].name) .. " (count " .. #list .. ")")

    local ok2, reason2 = rig.Config.removeCategory("Fiction")
    r.check("removing an already-gone category is refused",
            ok2 == false and reason2 == "not_found",
            "returned " .. tostring(ok2) .. "," .. tostring(reason2))
end

do
    local rig = newRig(nil)
    rig.Config.addCategory("Fiction")
    rig.Config.addSubcategory("Fiction", "Romance")
    rig.Config.addSubcategory("Fiction", "Sci-Fi")

    local ok = rig.Config.removeSubcategory("Fiction", "Romance")
    r.check("removeSubcategory removes exactly that child",
            ok == true and #rig.Config.getCategories()[1].children == 1
                and rig.Config.getCategories()[1].children[1] == "Sci-Fi",
            "children = " .. tostring(rig.Config.getCategories()[1].children[1]))

    local ok2, reason2 = rig.Config.removeSubcategory("Fiction", "Romance")
    r.check("removing an already-gone sub-category is refused",
            ok2 == false and reason2 == "not_found",
            "returned " .. tostring(ok2) .. "," .. tostring(reason2))

    local ok3, reason3 = rig.Config.removeSubcategory("Missing", "X")
    r.check("removing a sub-category under an unknown parent is refused",
            ok3 == false and reason3 == "no_parent",
            "returned " .. tostring(ok3) .. "," .. tostring(reason3))
end

-- ---------------------------------------------------------------- round-trip through the store
do
    local rig = newRig(nil)
    rig.Config.addCategory("Fiction")
    rig.Config.addSubcategory("Fiction", "Romance")
    -- What ends up in the settings store is exactly what a later getCategories reads back.
    r.check("the stored value is the category list, under the categories key",
            rig.store.zlibrary_categories == rig.Config.getCategories(),
            "store and getCategories disagree")
    r.check("the round-tripped shape is intact",
            rig.store.zlibrary_categories[1].name == "Fiction"
                and rig.store.zlibrary_categories[1].children[1] == "Romance",
            "shape lost in storage")
end

-- ---------------------------------------------------------------- wiring across the files
-- The helpers above are useless if nothing calls them. These pin the seams that connect storage to
-- the management menu and to the post-download move.
local function slurp(path)
    local fh = assert(io.open(path)); local s = fh:read("*a"); fh:close(); return s
end
local main_src = slurp(PLUGIN .. "/main.lua")
local ui_src = slurp(PLUGIN .. "/zlibrary/ui.lua")
local download_src = slurp(PLUGIN .. "/zlibrary/download.lua")

r.check("the Settings menu reaches the category management builder",
        main_src:find("Ui.buildCategoriesMenuItems", 1, true) ~= nil,
        "the Download categories menu entry is not wired to the builder")

r.check("confirmOpenBook grows the post-download chooser",
        ui_src:find("function Ui.confirmOpenBook", 1, true) ~= nil
            and ui_src:find("_showCategoryChooser", 1, true) ~= nil,
        "the Move to chooser is not wired into confirmOpenBook")

r.check("the Move to chooser is a menu-derived view, not a button stack",
        ui_src:find("function Ui._showCategoryChooser", 1, true) ~= nil
            and ui_src:find("Menu:new", 1, true) ~= nil,
        "the chooser is not built from the Menu widget")

r.check("the chooser can create a category in the flow",
        ui_src:find("_createCategoryTarget", 1, true) ~= nil
            and ui_src:find("_showCreateCategoryDialog", 1, true) ~= nil,
        "in-flow category creation is not wired up")

r.check("download.lua passes the categories into the dialog",
        download_src:find("Config.getCategories()", 1, true) ~= nil
            and download_src:find("confirmOpenBook", 1, true) ~= nil,
        "download.lua does not hand the categories to confirmOpenBook")

r.check("download.lua files the book on the dialog's choice",
        download_src:find("fileInto(chosen_target)", 1, true) ~= nil,
        "the chosen category is not acted on after download")

r.finish()
