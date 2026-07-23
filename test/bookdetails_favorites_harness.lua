-- After a successful favorite/unfavorite, main.lua clears the shared favorites-id cache
-- (resetFavoritesCache). The book details dialog rebuilds its buttons on every view switch, and
-- a rebuild used to re-query that now-empty cache -- showing "Add To Favorites" for a book the
-- user had just favorited. The dialog now records the toggled state in _favorite_state_override
-- and trusts it only until fresh cache data arrives, at which point the cache is authoritative
-- again (it reflects favorite changes made elsewhere too).
--
-- This harness compiles the real _buildButtons and _generateFavoriteButtonDef out of
-- bookdetails_dialog.lua and drives that cycle: toggle, rebuild with an empty cache, rebuild
-- with a repopulated cache.
--
-- usage: luajit bookdetails_favorites_harness.lua <plugin-root> <luasocket-src>

local PLUGIN = assert(arg[1], "usage: luajit bookdetails_favorites_harness.lua <plugin-root> <luasocket-src>")
package.path = PLUGIN .. "/test/?.lua;" .. package.path
local support = require("support")

-- support.extract_function only handles file-local `local function`s; these are methods on the
-- BookDetailsDialog table. Same deal otherwise: compile the real definition out of the source,
-- and refuse to guess if the name stops being unique.
local function extract_method(path, name)
    local fh = assert(io.open(path), "cannot open " .. path)
    local src = "\n" .. fh:read("*a")
    fh:close()
    local anchor = "\nfunction BookDetailsDialog:" .. name
    local n, pos = 0, 1
    while true do
        local s, e = string.find(src, anchor, pos, true)
        if not s then break end
        n = n + 1
        pos = e + 1
    end
    assert(n == 1, string.format("'%s' appears %d times in %s -- refusing to guess which one is live",
        anchor, n, path))
    -- Every `end` inside these methods is indented; the method's own `end` is the first one at
    -- the start of a line.
    local body = src:match("(" .. anchor:gsub("(%W)", "%%%1") .. ".-\nend\n)")
    assert(body, "could not delimit the end of " .. name)
    return body
end

local BookDetailsDialog = {}
local chunk = assert(loadstring(
    extract_method(PLUGIN .. "/zlibrary/bookdetails_dialog.lua", "_buildButtons")
    .. extract_method(PLUGIN .. "/zlibrary/bookdetails_dialog.lua", "_generateFavoriteButtonDef"),
    "=bookdetails_favorites"))
setfenv(chunk, {
    BookDetailsDialog = BookDetailsDialog,
    table = table, string = string, type = type, ipairs = ipairs, pairs = pairs,
    tostring = tostring, T = function(s) return s end,
    UIManager = { setDirty = function() end, close = function() end },
})
chunk()

-- Mirrors Zlibrary:isBookInFavorites / resetFavoritesCache from main.lua: cache_ids == nil means
-- the shared cache is absent (never fetched, or cleared by a successful toggle).
local function make_plugin(cache_ids)
    return {
        cache_ids = cache_ids,
        isBookInFavorites = function(self, book_stub)
            if not (book_stub and book_stub.id) then return type(self.cache_ids) == "table" end
            return type(self.cache_ids) == "table" and self.cache_ids[tostring(book_stub.id)] == true
        end,
        favoriteBook = function(self, book_stub, on_success)
            self.cache_ids = nil -- resetFavoritesCache(true)
            on_success()
        end,
        unfavoriteBook = function(self, book_stub, on_success)
            self.cache_ids = nil -- resetFavoritesCache(true)
            on_success()
        end,
    }
end

local function make_dialog(plugin, book_id)
    local dlg = setmetatable({
        view_state = "menu",
        book = { id = book_id, title = "Title", hash = "abc", format = "N/A" },
        is_cache = false,
        has_favorite_ids_cache = true,
        parent_zlibrary = plugin,
    }, { __index = BookDetailsDialog })
    dlg._fake_button = { setText = function(self, t) self.text = t end }
    dlg.inner_dialog = {
        getButtonById = function(_, id)
            if id == "favorite_btn" then return dlg._fake_button end
        end,
    }
    return dlg
end

-- What switchState -> _buildInnerDialog -> _buildButtons does on every view switch.
local function rebuilt_favorite_def(dlg)
    for _, row in ipairs(dlg:_buildButtons()) do
        for _, def in ipairs(row) do
            if def.id == "favorite_btn" then return def end
        end
    end
end

local function says(def, label)
    return def and string.find(def.text, label, 1, true) ~= nil
end

local r = support.reporter()

-- 1. The cache says the book is favorited.
local dlg = make_dialog(make_plugin({ ["7"] = true }), 7)
r.check("cached favorite shows Remove From Favorites",
    says(rebuilt_favorite_def(dlg), "Remove From Favorites"),
    tostring(rebuilt_favorite_def(dlg).text))

-- 2. The cache says it is not.
dlg = make_dialog(make_plugin({ ["7"] = true }), 8)
r.check("cached non-favorite shows Add To Favorites",
    says(rebuilt_favorite_def(dlg), "Add To Favorites"),
    tostring(rebuilt_favorite_def(dlg).text))

-- 3. Favorite a book, then rebuild the way a view switch does: the toggle cleared the cache,
--    but the button must not revert.
dlg = make_dialog(make_plugin({}), 7)
local def = rebuilt_favorite_def(dlg)
def.callback() -- the toggle; on_success runs reload_ui
r.check("successful favorite records the override",
    dlg._favorite_state_override == true, tostring(dlg._favorite_state_override))
r.check("reload_ui updated the visible button",
    says(dlg._fake_button, "Remove From Favorites"), tostring(dlg._fake_button.text))
r.check("rebuild after favorite keeps Remove From Favorites",
    says(rebuilt_favorite_def(dlg), "Remove From Favorites"),
    tostring(rebuilt_favorite_def(dlg).text))

-- 4. Once the cache is repopulated it is authoritative again and the override is dropped.
dlg.parent_zlibrary.cache_ids = { ["7"] = true }
r.check("repopulated cache retakes authority",
    says(rebuilt_favorite_def(dlg), "Remove From Favorites"),
    tostring(rebuilt_favorite_def(dlg).text))
r.check("override dropped once the cache is back",
    dlg._favorite_state_override == nil, tostring(dlg._favorite_state_override))

-- 5. An unfavorite made ELSEWHERE must win over the stale override: the repopulated cache no
--    longer holds the book, so the button flips back.
dlg = make_dialog(make_plugin({}), 7)
rebuilt_favorite_def(dlg).callback() -- favorite; override = true, cache cleared
dlg.parent_zlibrary.cache_ids = {}   -- repopulated; the book is not in it
r.check("fresh cache beats a stale override",
    says(rebuilt_favorite_def(dlg), "Add To Favorites"),
    tostring(rebuilt_favorite_def(dlg).text))

-- 6. The mirror image: unfavorite a favorited book, then rebuild with the cache cleared.
dlg = make_dialog(make_plugin({ ["7"] = true }), 7)
rebuilt_favorite_def(dlg).callback()
r.check("rebuild after unfavorite keeps Add To Favorites",
    says(rebuilt_favorite_def(dlg), "Add To Favorites"),
    tostring(rebuilt_favorite_def(dlg).text))

r.finish()
