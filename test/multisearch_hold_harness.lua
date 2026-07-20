-- What does holding a row in the browse list offer?
--
-- The multi-search screen -- Most popular, Recommended, My Books -- has always shown a menu on
-- hold, with entries for searching the title or the author. Downloading was not among them, so
-- getting a book took a tap into the detail view even though the list already knows enough to
-- start one. The search results list gained hold-to-download first; this is the same thing on
-- the other screen.
--
-- Every entry is conditional, on the book having the right fields and the caller having supplied
-- the matching callback, which is where a menu like this goes wrong: an entry that silently
-- stops appearing looks exactly like a feature that was never there.

local PLUGIN = assert(arg[1], "usage: luajit multisearch_hold_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local block = support.extract_block(PLUGIN .. "/zlibrary/multisearch_dialog.lua",
    "(\nfunction SearchDialog:onMenuHold%(.-\nend\n)")

-- Rebuild the method against a captured ButtonDialog so the entries are observable.
local built
local function hold(book, callbacks, active_item)
    built = nil
    local env = {
        SearchDialog = {},
        string = string, table = table, type = type, tostring = tostring, ipairs = ipairs,
        T = function(s) return s end,
        ButtonDialog = { new = function(_, spec) built = spec; return spec end },
        UIManager = { show = function() end, close = function() end },
    }
    local chunk = assert(loadstring(block, "=onMenuHold"))
    setfenv(chunk, env)
    chunk()

    local self = {
        books = { book },
        getActiveItem = function() return active_item end,
    }
    for k, v in pairs(callbacks or {}) do self[k] = v end
    env.SearchDialog.onMenuHold(self, { book_index = 1 })
    return built
end

local function labels(spec)
    local out = {}
    for _, row in ipairs((spec or {}).buttons or {}) do
        for _, b in ipairs(row) do out[#out + 1] = b.text end
    end
    return out
end

local function has(spec, text)
    for _, l in ipairs(labels(spec)) do
        if l:find(text, 1, true) then return true end
    end
    return false
end

local BOOK = { id = "1", hash = "h", title = "Dune", author = "Frank Herbert" }
local noop = function() end

-- ---------------------------------------------------------------- the download entry
local downloaded = nil
local spec = hold(BOOK, {
    on_search_callback = noop,
    on_similar_books_callback = noop,
    on_download_book_callback = function(b) downloaded = b end,
})
r.check("holding offers a download", has(spec, "Download book"),
        "entries: " .. table.concat(labels(spec), " | "))

-- Find and fire it.
local fired = false
for _, row in ipairs(spec.buttons) do
    for _, b in ipairs(row) do
        if b.text:find("Download book", 1, true) then b.callback(); fired = true end
    end
end
r.check("choosing it hands the book over", fired and downloaded == BOOK,
        "fired=" .. tostring(fired) .. " book=" .. tostring(downloaded))

-- ---------------------------------------------------------------- it stays conditional
-- No callback: the entry must not appear rather than appear and do nothing.
spec = hold(BOOK, { on_search_callback = noop })
r.check("no callback means no download entry", not has(spec, "Download book"),
        "entries: " .. table.concat(labels(spec), " | "))

-- downloadBook resolves the link from these two, so without them the entry is a dead end.
spec = hold({ title = "Dune", author = "Frank Herbert" }, {
    on_search_callback = noop, on_download_book_callback = noop })
r.check("a book with no id or hash offers no download", not has(spec, "Download book"),
        "entries: " .. table.concat(labels(spec), " | "))

spec = hold({ id = "1", title = "Dune" }, {
    on_search_callback = noop, on_download_book_callback = noop })
r.check("a book with an id but no hash offers no download", not has(spec, "Download book"),
        "entries: " .. table.concat(labels(spec), " | "))

-- ---------------------------------------------------------------- the entries it had before
-- Adding one must not have displaced the others.
spec = hold(BOOK, {
    on_search_callback = noop,
    on_similar_books_callback = noop,
    on_download_book_callback = noop,
})
r.check("searching by title is still offered", has(spec, "Dune"),
        "entries: " .. table.concat(labels(spec), " | "))
r.check("searching by author is still offered", has(spec, "Frank Herbert"),
        "entries: " .. table.concat(labels(spec), " | "))
r.check("similar books is still offered", has(spec, "More Similar Books"),
        "entries: " .. table.concat(labels(spec), " | "))

-- A tab may contribute its own action, e.g. removing from the downloaded list.
spec = hold(BOOK, { on_search_callback = noop, on_download_book_callback = noop },
    { book_action = { text = "Remove", callback = noop } })
r.check("a tab's own action is still offered", has(spec, "Remove"),
        "entries: " .. table.concat(labels(spec), " | "))

-- ---------------------------------------------------------------- both screens are wired
local main_src = (function()
    local fh = assert(io.open(PLUGIN .. "/main.lua"))
    local s = fh:read("*a"); fh:close(); return s
end)()
local n = 0
for _ in main_src:gmatch("on_download_book_callback") do n = n + 1 end
r.check("both browse dialogs offer it", n == 2,
        n .. " call sites -- the search and My Books dialogs should each pass one")

-- Nothing here may confirm: downloadBook does that, and asking twice was a bug once already.
--
-- Count the ones that hand straight over and require ALL of them to. An earlier version asked
-- only whether such a call site existed, which stayed true after one of the two was changed --
-- the same "a thing is present" check that let the double dialog through in the first place.
local direct = 0
for _ in main_src:gmatch("on_download_book_callback = function%(book%)%s*self:downloadBook%(book%)%s*end") do
    direct = direct + 1
end
r.check("every callback hands straight to downloadBook", direct == n,
        direct .. " of " .. n .. " hand over directly -- the rest do something else, and "
        .. "downloadBook already confirms")

r.finish()
