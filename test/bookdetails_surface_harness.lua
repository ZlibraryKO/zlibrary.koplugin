-- Does the book details dialog still have every method it had before bookdetails_dialog.lua was split?
--
-- bookdetails_dialog.lua was one 1,084-line file holding one widget class. The class is now created
-- in bookdetails_core.lua, and the parts -- book, content, cover, buttons, comments -- add their
-- methods to it. bookdetails_dialog.lua stays the entry point that ui_books requires: it loads the
-- core and every part, and returns showBookDetails and the class as before. The methods call each
-- other through self, so one that no part defines is a nil call when the dialog opens, and one
-- defined twice silently replaces the other.
--
-- Read from the sources rather than by loading the class, which needs KOReader's widget stack. The
-- list was recorded from the unsplit bookdetails_dialog.lua on 2026-11-13 (20 methods). Added since:
-- _buildTextColumn, _buildTitle, _buildAuthorLine, _buildHeader, _withCloseButton and
-- _buildTextSection (2026-11-13, out of _buildContent).

local PLUGIN = assert(arg[1], "usage: luajit bookdetails_surface_harness.lua <plugin-root> <luasocket-src>")
local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local EXPECTED = {
    "init",
    "_buildInnerDialog",
    "_contentBudget",
    "_calculateDimensions",
    "_buildContent",
    "_buildTextColumn",
    "_buildTitle",
    "_buildAuthorLine",
    "_buildHeader",
    "_withCloseButton",
    "_buildTextSection",
    "_buildHtmlSection",
    "_buildIsbnLine",
    "_generateMetaLines",
    "_buildCoverComponent",
    "_applyCoverPaintShadow",
    "onDownloadClick",
    "_buildButtons",
    "switchState",
    "_addKeyFocusRows",
    "_generateFavoriteButtonDef",
    "refreshCoverImage",
    "getRefreshRegion",
    "_renderComments",
    "_sanitizeBookData",
    "onCloseWidget",
}

local function read(path)
    local fh = assert(io.open(path), "cannot open " .. path)
    local s = fh:read("*a")
    fh:close()
    return s
end

-- The entry point and every part, found by listing the folder so a new part is included.
local ENTRY = PLUGIN .. "/zlibrary/bookdetails_dialog.lua"
local files = { ENTRY }
local parts = {}
local ls = assert(io.popen('ls "' .. PLUGIN .. '/zlibrary"'))
for name in ls:lines() do
    local part = name:match("^(bookdetails_[%w_]+)%.lua$")
    if part and part ~= "bookdetails_dialog" then
        table.insert(files, PLUGIN .. "/zlibrary/" .. name)
        table.insert(parts, part)
    end
end
ls:close()
table.sort(parts)

local defined = {}
for _, path in ipairs(files) do
    local src = "\n" .. read(path)
    local file = path:match("[^/]+$")
    for name in src:gmatch("\nfunction BookDetailsDialog[:%.]([%w_]+)%(") do
        defined[name] = defined[name] or {}
        table.insert(defined[name], file)
    end
end

local missing, twice, extra, expected = {}, {}, {}, {}
for _, name in ipairs(EXPECTED) do
    expected[name] = true
    local where = defined[name]
    if not where then
        table.insert(missing, name)
    elseif #where > 1 then
        table.insert(twice, name .. " (" .. table.concat(where, ", ") .. ")")
    end
end
for name in pairs(defined) do
    if not expected[name] then table.insert(extra, name) end
end
table.sort(extra)

r.check("every method is still defined", #missing == 0, table.concat(missing, ", "))
r.check("no method is defined twice", #twice == 0, table.concat(twice, "; "))
r.check("no method was added", #extra == 0, table.concat(extra, ", "))

-- The entry point has to load every part, or that part's methods never reach the class.
local entry = read(ENTRY)
local not_required = {}
for _, part in ipairs(parts) do
    if not entry:find('require("zlibrary.' .. part .. '")', 1, true) then
        table.insert(not_required, part)
    end
end
r.check("the entry point requires every part", #not_required == 0, table.concat(not_required, ", "))

-- What ui_books relies on: the returned table still carries both names.
local returned = entry:match("\nreturn%s*(%b{})%s*$")
r.check("the entry point returns showBookDetails and BookDetailsDialog",
        returned ~= nil
        and returned:find("showBookDetails%s*=%s*showBookDetails") ~= nil
        and returned:find("BookDetailsDialog%s*=%s*BookDetailsDialog") ~= nil,
        returned)

r.finish()
