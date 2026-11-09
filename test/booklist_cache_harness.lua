-- Signing out forgets every cached booklist_<id>, including lists deleted on the website since,
-- which no longer appear under "booklists". Real clearPersonalCaches and KVCache, fake settings file.

local PLUGIN = assert(arg[1], "usage: luajit booklist_cache_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local function fake_settings(data)
    return {
        data = data,
        flushes = 0,
        delSetting = function(self, key) self.data[key] = nil end,
        flush = function(self) self.flushes = self.flushes + 1 end,
        purge = function(self) self.purged = true end,
    }
end

local KVCache = {}
local env = {
    KVCache = KVCache, pairs = pairs, next = next, type = type,
    LuaSettings = { open = function() return fake_settings({}) end },
}
for _, pattern in ipairs({
    "(\nfunction KVCache:remove%(.-\nend\n)",
    "(\nfunction KVCache:removePrefix%(.-\nend\n)",
    "(\nfunction KVCache:clear%(.-\nend\n)",
}) do
    local chunk = assert(loadstring(support.extract_block(PLUGIN .. "/zlibrary/cache.lua", pattern), "=KVCache"))
    setfenv(chunk, env)
    chunk()
end

local function new_kv(data)
    return setmetatable({ _cache = fake_settings(data) }, { __index = KVCache })
end

-- ---------------------------------------------------------------- removePrefix on its own
local kv = new_kv({ booklist_1 = {}, booklist_2 = {}, booklists = {}, favorites = {}, popular = {} })
kv:removePrefix("booklist_")
local data = kv._cache.data
r.check("removePrefix: drops every key with the prefix", data.booklist_1 == nil and data.booklist_2 == nil)
r.check("removePrefix: leaves other keys alone",
        data.booklists ~= nil and data.favorites ~= nil and data.popular ~= nil)
r.check("removePrefix: writes the file once", kv._cache.flushes == 1, kv._cache.flushes .. " flushes")

kv = new_kv({ booklist_1 = {} })
local only = kv._cache
kv:removePrefix("booklist_")
r.check("removePrefix: purges the file when nothing is left, as remove does", only.purged == true)

kv = new_kv({ booklists = {}, favorites = {} })
r.check("removePrefix: with nothing to remove still succeeds", kv:removePrefix("booklist_") == true)
r.check("removePrefix: and leaves the file alone",
        kv._cache.flushes == 0 and not kv._cache.purged and kv._cache.data.booklists ~= nil,
        kv._cache.flushes .. " flushes, purged=" .. tostring(kv._cache.purged))

-- ---------------------------------------------------------------- clearPersonalCaches end to end
local multi_search = new_kv({
    booklists = { { id = 1, name = "Still here" } },
    booklist_1 = { { id = 10 } },
    -- Deleted on the website after it was cached: no longer listed under "booklists".
    booklist_999 = { { id = 11 } },
    favorites = {}, popular = {},
})
local search_history_cleared = false
local config_env = { ipairs = ipairs, Config = {
    getConfigRuntimeCache = function() return { remove = function() end } end,
    getMultiSearchCache = function() return multi_search end,
    clearSearchHistory = function() search_history_cleared = true end,
} }
local body = support.extract_block(PLUGIN .. "/zlibrary/config.lua",
                                   "(\nfunction Config%.clearPersonalCaches%(%).-\n)end\n")
local chunk = assert(loadstring("local Config = ...\n" .. body .. "end\nreturn Config", "=clearPersonalCaches"))
setfenv(chunk, config_env)
chunk(config_env.Config).clearPersonalCaches()

data = multi_search._cache.data
r.check("signing out drops the booklists entry", data.booklists == nil)
r.check("signing out drops a listed booklist's books", data.booklist_1 == nil)
r.check("signing out drops a booklist no longer listed", data.booklist_999 == nil)
r.check("signing out keeps popular", data.popular ~= nil)
r.check("signing out clears the search history", search_history_cleared)

r.finish()
