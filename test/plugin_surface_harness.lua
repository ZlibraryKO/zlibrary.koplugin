-- Does the plugin class still have every method it had before main.lua was split?
--
-- main.lua was one 1,579-line file. Its methods now live in main.lua and six parts --
-- plugin_menu, plugin_requests, plugin_browse, plugin_books, plugin_signin, plugin_search -- which
-- main.lua copies onto the class at load. Other modules call these methods on the plugin instance
-- (ui.lua, bookdetails_dialog.lua, download.lua, discovery.lua), so a method left behind is a nil
-- call on a device, and one defined twice is a silent overwrite.
--
-- Read from the sources rather than by loading the class, which needs KOReader's widget stack. The
-- list was recorded from the unsplit main.lua on 2026-11-10 (32 methods).

local PLUGIN = assert(arg[1], "usage: luajit plugin_surface_harness.lua <plugin-root> <luasocket-src>")
local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local function read(path)
    local fh = assert(io.open(path), "cannot open " .. path)
    local s = fh:read("*a")
    fh:close()
    return s
end

local EXPECTED = {
    "addToMainMenu",
    "autoDiscoverAndSetBaseUrl",
    "deleteDownloadedBook",
    "displaySearchResults",
    "downloadAndShowCover",
    "downloadBook",
    "favoriteBook",
    "fetchAndDisplayComments",
    "_fetchBookList",
    "_fetchDetailsThenDownload",
    "getDownloadQuotaCache",
    "init",
    "isBookInFavorites",
    "login",
    "onCloseWidget",
    "onDispatcherRegisterActions",
    "onExit",
    "onSelectRecommendedBook",
    "onSelectSearchBook",
    "onZlibrarySearch",
    "performSearch",
    "_promptForCredentials",
    "_requestDispatcher",
    "resetDownloadQuotaCache",
    "resetFavoritesCache",
    "searchSimilarBooks",
    "showBooklistDialog",
    "showMultiSearchDialog",
    "showMyBooksDialog",
    "_teardown",
    "unfavoriteBook",
    "_verifyCredentials",
}

-- main.lua, plus every part it mixes in. The parts are found by listing the folder, so a new
-- plugin_*.lua that main.lua forgets to mix in is caught below rather than silently ignored.
local main_src = read(PLUGIN .. "/main.lua")
local sources = { ["main.lua"] = main_src }
local parts = {}
do
    local ls = assert(io.popen('ls "' .. PLUGIN .. '/zlibrary"'))
    for file in ls:lines() do
        local name = file:match("^(plugin_[%w_]+)%.lua$")
        if name then
            parts[#parts + 1] = name
            sources["zlibrary/" .. file] = read(PLUGIN .. "/zlibrary/" .. file)
        end
    end
    ls:close()
end

local defined = {}
for file, src in pairs(sources) do
    for name in ("\n" .. src):gmatch("\nfunction Zlibrary:([%w_]+)%(") do
        defined[name] = defined[name] or {}
        table.insert(defined[name], file)
    end
end

local missing, twice, extra = {}, {}, {}
local expected = {}
for _, name in ipairs(EXPECTED) do
    expected[name] = true
    if not defined[name] then missing[#missing + 1] = name end
end
for name, files in pairs(defined) do
    if not expected[name] then extra[#extra + 1] = name end
    if #files > 1 then twice[#twice + 1] = name .. " (" .. table.concat(files, ", ") .. ")" end
end
table.sort(missing); table.sort(twice); table.sort(extra)

r.check(string.format("all %d recorded methods are still defined", #EXPECTED),
        #missing == 0, "missing: " .. table.concat(missing, ", "))
r.check("each exactly once", #twice == 0, "defined twice: " .. table.concat(twice, "; "))
r.check("and no new ones", #extra == 0, "not recorded: " .. table.concat(extra, ", "))

local not_mixed = {}
for _, part in ipairs(parts) do
    if not main_src:find('"' .. part .. '"', 1, true) then not_mixed[#not_mixed + 1] = part end
end
r.check("main.lua mixes in every plugin_* part", #not_mixed == 0,
        "never copied onto the class: " .. table.concat(not_mixed, ", "))

r.finish()
