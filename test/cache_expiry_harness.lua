-- When a cached entry expires, on a clock this harness controls.
--
-- Every cache in cache.lua stamps entries with the time and later compares that stamp against a
-- TTL: the kv caches (search results, domains), the book info files, the covers (by file mtime),
-- and the once-a-day GC sweep. They all read time through cache.lua's local now(), which this
-- harness supplies, so each boundary can be checked to the second without forging timestamps:
-- an entry exactly TTL seconds old is still a hit and one second more is a miss (and is removed
-- unless skip_rm), a clock that went backwards is a miss, a TTL of 0 never expires, and the
-- sweep runs only when more than a day has passed.
--
-- The methods are extracted from cache.lua with LuaSettings, lfs and util stubbed in memory, so
-- what is under test is the expiry arithmetic and what each miss deletes, not file I/O.

local PLUGIN = assert(arg[1], "usage: luajit cache_expiry_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local CACHE = PLUGIN .. "/zlibrary/cache.lua"
local DEF_TTL = tonumber(support.extract_block(CACHE, "\nlocal DEF_TTL_CACHE_EXPIRY = (%d+)"))

-- ---------------------------------------------------------------- the clock and the stubs
local T = 1700000000
local function at(t) T = t end

-- One in-memory LuaSettings per path; purge drops the file, as the real one deletes it.
local files = {}
local function settings(path, data)
    local s = { data = data or {}, flushes = 0 }
    function s:saveSetting(k, v) self.data[k] = v end
    function s:readSetting(k) return self.data[k] end
    function s:delSetting(k) self.data[k] = nil end
    function s:flush() self.flushes = self.flushes + 1; files[path] = self end
    function s:purge() self.purged = true; files[path] = nil end
    return s
end

local mtimes = {}
local KVCache, BookInfoCache, CoverCache, M = {}, {}, {}, {}
local env = {
    type = type, tonumber = tonumber, next = next, setmetatable = setmetatable,
    now = function() return T end,
    DEF_TTL_CACHE_EXPIRY = DEF_TTL,
    KVCache = KVCache, BookInfoCache = BookInfoCache, CoverCache = CoverCache, M = M,
    _isValidBookHash = function(h) return type(h) == "string" and h:match("^[%w_-]+$") ~= nil end,
    LuaSettings = { open = function(_, path) return files[path] or settings(path) end },
    util = { fileExists = function(path) return files[path] ~= nil or mtimes[path] ~= nil end },
    lfs = { attributes = function(path) return mtimes[path] and { modification = mtimes[path] } end },
    logger = { dbg = function() end, info = function() end, warn = function() end },
}

for _, pattern in ipairs({
    "(\nfunction KVCache:insert%(.-\nend\n)",
    "(\nfunction KVCache:get%(.-\nend\n)",
    "(\nfunction KVCache:remove%(.-\nend\n)",
    "(\nfunction KVCache:clear%(.-\nend\n)",
    "(\nfunction BookInfoCache:insert%(.-\nend\n)",
    "(\nfunction BookInfoCache:get%(.-\nend\n)",
    "(\nfunction CoverCache:get%(.-\nend\n)",
    "(\nfunction M%.autoCacheCleanup%(.-\nend\n)",
}) do
    local chunk = assert(loadstring(support.extract_block(CACHE, pattern), "=cache.lua"))
    setfenv(chunk, env)
    chunk()
end

local function new_kv()
    local kv = setmetatable({ path = "/kv.lua" }, { __index = KVCache })
    kv._cache = settings(kv.path)
    return kv
end

-- ---------------------------------------------------------------- KVCache
local START = 1700000000
local TTL = 3600

local kv = new_kv()
at(START)
kv:insert("k", { "v" })
r.check("kv: insert stamps the entry with the clock", kv._cache.data.k._at == START,
        tostring(kv._cache.data.k._at))

at(START + TTL)
r.check("kv: an entry exactly TTL seconds old is still a hit", kv:get("k", TTL) ~= nil)

at(START + TTL + 1)
r.check("kv: one second past the TTL, skip_rm reports a miss", kv:get("k", TTL, true) == nil)
r.check("kv: and leaves the entry in place", kv._cache.data.k ~= nil, "skip_rm removed it anyway")
kv._cache.data.other = { data = 1, _at = START + TTL + 1 }
r.check("kv: without skip_rm it is a miss too", kv:get("k", TTL) == nil)
r.check("kv: and the expired entry is removed", kv._cache.data.k == nil, "still stored")

kv = new_kv()
at(START); kv:insert("k", 1)
at(START - 1)
r.check("kv: an entry stamped in the future (clock went back) is a miss", kv:get("k", TTL, true) == nil,
        "a stamp ahead of the clock would otherwise stay fresh until the clock caught up")

at(START + 10 * 365 * 86400)
r.check("kv: a TTL of 0 never expires", kv:get("k", 0, true) == 1)

at(START + DEF_TTL)
r.check("kv: with no TTL given, the default applies (still fresh at " .. DEF_TTL .. " s)",
        kv:get("k", nil, true) == 1)
at(START + DEF_TTL + 1)
r.check("kv: and expires one second after it", kv:get("k", nil, true) == nil)
r.check("kv: a non-numeric TTL also falls back to the default", kv:get("k", "soon", true) == nil)

kv._cache.data.bad = { data = 1, _at = "yesterday" }
r.check("kv: a non-numeric stamp (hand-edited file) is a miss, not an error",
        kv:get("bad", TTL) == nil and kv._cache.data.bad == nil)

-- ---------------------------------------------------------------- BookInfoCache
local info = setmetatable({ getPath = function(_, h) return "/bookinfos/" .. h .. "_info.lua" end },
                          { __index = BookInfoCache })
info._ensurePath = function() end
local INFO_PATH = "/bookinfos/abc_info.lua"

at(START)
info:insert("abc", { title = "T" })
r.check("bookinfo: insert stamps the file with the clock", files[INFO_PATH].data._at == START,
        tostring(files[INFO_PATH] and files[INFO_PATH].data._at))

at(START + TTL)
r.check("bookinfo: exactly TTL seconds old is still a hit", info:get("abc", TTL) ~= nil)
at(START + TTL + 1)
r.check("bookinfo: one second past, skip_rm reports a miss", info:get("abc", TTL, true) == nil)
r.check("bookinfo: and keeps the file", files[INFO_PATH] ~= nil)
r.check("bookinfo: with no TTL given there is no expiry check at all",
        info:get("abc", nil) ~= nil, "bookinfo has no default TTL; a nil one must not expire it")
r.check("bookinfo: without skip_rm the expired file is purged",
        info:get("abc", TTL) == nil and files[INFO_PATH] == nil)

at(START); info:insert("abc", { title = "T" })
at(START - 1)
r.check("bookinfo: a stamp in the future is a miss", info:get("abc", TTL, true) == nil)

-- ---------------------------------------------------------------- CoverCache (file mtime)
local removed = {}
local cover = setmetatable({
    getPath = function(_, h) return "/covers/" .. h .. ".jpg" end,
    remove = function(_, h) removed[#removed + 1] = h; mtimes["/covers/" .. h .. ".jpg"] = nil end,
}, { __index = CoverCache })
mtimes["/covers/abc.jpg"] = START

at(START + TTL)
r.check("cover: exactly TTL seconds after the mtime is still a hit", cover:get("abc", TTL) == "/covers/abc.jpg")
at(START - 1)
r.check("cover: an mtime in the future is a miss", cover:get("abc", TTL) == nil)
r.check("cover: and the file is removed", removed[1] == "abc", tostring(removed[1]))

mtimes["/covers/abc.jpg"] = START
at(START + TTL + 1)
r.check("cover: with no TTL given it never expires", cover:get("abc") == "/covers/abc.jpg")
r.check("cover: one second past the TTL is a miss", cover:get("abc", TTL) == nil and #removed == 2)

-- ---------------------------------------------------------------- the daily sweep
local DAY = 86400
local sweeps = 0
function M:new() return { gc_clean = function() sweeps = sweeps + 1 end } end
local stamp = {}
local store = {
    get = function(_, k) return stamp[k] end,
    insert = function(_, k, v) stamp[k] = v end,
}

at(START)
M.autoCacheCleanup(store)
r.check("sweep: runs on first use and cleans both caches", sweeps == 2, sweeps .. " gc_clean calls")
r.check("sweep: records the time it ran", stamp.last_cleaned_at == START, tostring(stamp.last_cleaned_at))

at(START + DAY)
M.autoCacheCleanup(store)
r.check("sweep: not again exactly a day later", sweeps == 2, sweeps .. " gc_clean calls")

at(START + DAY + 1)
M.autoCacheCleanup(store)
r.check("sweep: runs once more than a day has passed", sweeps == 4, sweeps .. " gc_clean calls")
r.check("sweep: and moves the stamp to now", stamp.last_cleaned_at == START + DAY + 1)

r.finish()
