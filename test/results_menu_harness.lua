-- Does the search results page offer a way back to the search box?
--
-- It did not. You could page through results, open a book, or close the screen -- but to change
-- the query you had to close it, find the plugin menu and start over. The multi-search screen
-- has carried a magnifying glass in its title bar all along, so the results page was the odd one
-- out rather than the design.
--
-- Only the icon route exists: KOReader's TitleBar takes callbacks for its left and right icons
-- and none for the title text, so tapping the "Search Results: x" caption cannot be wired up
-- however reasonable it sounds.
--
-- Drives the real Ui.createSearchResultsMenu with a stub Menu, so what is asserted is what the
-- widget would actually be constructed with.

local PLUGIN = assert(arg[1], "usage: luajit results_menu_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local block = support.extract_block(PLUGIN .. "/zlibrary/ui.lua",
    "(\nfunction Ui%.createSearchResultsMenu%(.-\nend\n)")

-- Rebuild the function against a captured Menu, so the constructor arguments are observable.
local built, shown
local function make()
    local Ui = {}
    local env = {
        Ui = Ui,
        string = string,
        Menu = { new = function(_, spec) built = spec; return spec end },
        Config = { getSearchOrderName = function() return "Popular" end },
        T = function(s) return s end,
        _colon_concat = function(a, b) return a .. ": " .. b end,
        _showAndTrackDialog = function(m) shown = m end,
    }
    local chunk = assert(loadstring(block, "=createSearchResultsMenu"))
    setfenv(chunk, env)
    chunk()
    return Ui.createSearchResultsMenu
end

local createSearchResultsMenu = make()
r.check("the function was recovered from ui.lua", type(createSearchResultsMenu) == "function",
        "got " .. type(createSearchResultsMenu))

-- ---------------------------------------------------------------- with a callback
local opened_with = nil
built, shown = nil, nil
local held_book = nil
local menu = createSearchResultsMenu({}, "dune", {}, function() end, {},
    function() opened_with = "called" end,
    function(book) held_book = book end)

r.check("results menu shows a search button",
        built and built.title_bar_left_icon == "appbar.search",
        "title_bar_left_icon = " .. tostring(built and built.title_bar_left_icon))
r.check("the button is wired to something",
        type(menu.onLeftButtonTap) == "function",
        "onLeftButtonTap = " .. type(menu.onLeftButtonTap))

-- Menu invokes this as a method, so the menu arrives as an argument the handler must tolerate.
menu:onLeftButtonTap()
r.check("tapping it reopens the search input", opened_with == "called", "callback never ran")

r.check("the query stays in the title", built and built.title == "Search Results: dune",
        "title = " .. tostring(built and built.title))
r.check("the menu is still shown", shown ~= nil, "_showAndTrackDialog was not called")

-- ---------------------------------------------------------------- holding a row
-- Holding downloads without opening the detail view, so the row has to carry the book and the
-- handler has to reach it. Menu invokes this as a method, so the menu arrives first.
r.check("holding a row is handled", type(menu.onMenuHold) == "function",
        "onMenuHold = " .. type(menu.onMenuHold))
local BOOK = { id = "1", hash = "h", title = "Dune", author = "Herbert", format = "epub", size = "2 MB" }
local handled = menu:onMenuHold({ book_data = BOOK })
r.check("holding passes the book on", held_book == BOOK, "got " .. tostring(held_book))
r.check("holding is marked handled", handled == true,
        "returned " .. tostring(handled) .. " -- the list would act on it as well")

-- A row without book data must not raise; menus carry other kinds of entry.
held_book = nil
local ok = pcall(function() return menu:onMenuHold({}) end)
r.check("holding a row with no book does nothing and does not raise",
        ok and held_book == nil, "raised or fired anyway")
ok = pcall(function() return menu:onMenuHold(nil) end)
r.check("holding nothing does not raise", ok, "raised on a nil item")

-- ---------------------------------------------------------------- without one
-- Every other caller passes nothing, and they must not gain a button that does nothing.
built = nil
local plain = createSearchResultsMenu({}, "dune", {}, function() end, {})
r.check("no callback means no button",
        built and built.title_bar_left_icon == nil,
        "title_bar_left_icon = " .. tostring(built and built.title_bar_left_icon))
r.check("no callback means no handler",
        plain.onLeftButtonTap == nil,
        "onLeftButtonTap = " .. type(plain.onLeftButtonTap))
r.check("no hold callback means no hold handler",
        plain.onMenuHold == nil, "onMenuHold = " .. type(plain.onMenuHold))

-- ---------------------------------------------------------------- the wiring in main.lua
-- The harness cannot run main.lua, but it can check the call site still passes a callback: the
-- feature is two halves and either alone is silent.
local main_src = (function()
    local fh = assert(io.open(PLUGIN .. "/main.lua"))
    local s = fh:read("*a"); fh:close(); return s
end)()
local call = main_src:match("Ui%.createSearchResultsMenu%b()")
    or main_src:match("Ui%.createSearchResultsMenu%(.-\n.-%)")
r.check("main.lua passes a new-search callback",
        call ~= nil and call:find("showSearchDialog", 1, true) ~= nil,
        "call site: " .. tostring(call))
r.check("the search box is seeded with the current query",
        call ~= nil and call:find("query_string", 1, true) ~= nil,
        "call site: " .. tostring(call))

-- Holding must confirm, because it spends quota and cannot be undone -- but it must confirm
-- ONCE. downloadBook already ends with Ui.confirmDownload, so asking again at the call site
-- produced two dialogs back to back: "Download this book?" and then Download "<file>"?. Count
-- the confirmations on the path rather than checking any single one is present, which is what
-- an earlier version of this did and why it passed while the bug was live.
r.check("holding routes into downloadBook",
        call ~= nil and call:find("downloadBook(book)", 1, true) ~= nil,
        "call site: " .. tostring(call))
-- Matches a call, not the word: the call site's own comment mentions confirming, and an
-- earlier version of this check failed on that rather than on anything real.
r.check("the hold call site does not confirm on its own",
        call ~= nil and call:find("Ui.confirmDownload", 1, true) == nil,
        "call site confirms as well as downloadBook: " .. tostring(call))

local confirms = 0
for _ in main_src:gmatch("Ui%.confirmDownload") do confirms = confirms + 1 end
r.check("exactly one confirmation exists in the download path", confirms == 1,
        confirms .. " calls to Ui.confirmDownload -- the user would answer that many dialogs")

-- And the row has to carry the book, or the handler has nothing to act on.
local ui_src = (function()
    local fh = assert(io.open(PLUGIN .. "/zlibrary/ui.lua"))
    local s = fh:read("*a"); fh:close(); return s
end)()
r.check("menu rows carry their book",
        ui_src:find("book_data = book_data", 1, true) ~= nil,
        "createBookMenuItem does not attach the book")

r.finish()
