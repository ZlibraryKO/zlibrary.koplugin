-- Two callers asking for the same cache must get the same cache.
--
-- Cache:new memoised the bookinfo and cover caches but built a fresh KVCache on every call, each
-- opening its own LuaSettings on the same file. So "_domains_cache" -- constructed in
-- Config.getSeedUrls, in discovery, and behind the menu's "clear domains cache" -- existed as
-- several independent in-memory copies of one file: a write through one was invisible to the
-- others, and the later flush wrote its own copy back over theirs. The cheaper half of the cost
-- was re-reading and re-parsing that file on every call, inside a discovery sweep that calls
-- getSeedUrls repeatedly.
--
-- Cache:new is extracted with the three cache classes stubbed, so what is under test is the
-- memoisation decision rather than any file behaviour.

local PLUGIN = assert(arg[1], "usage: luajit cache_instances_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local inits = { kv = 0, bookinfo = 0, cover = 0 }
local function fake_class(kind)
    local class = {}
    class.__index = class
    class.kind = kind
    function class:init() inits[kind] = inits[kind] + 1 end
    return class
end

local env = {
    setmetatable = setmetatable, tostring = tostring, type = type,
    logger = { warn = function() end, info = function() end, dbg = function() end },
    KVCache = fake_class("kv"),
    BookInfoCache = fake_class("bookinfo"),
    CoverCache = fake_class("cover"),
    _instances = {},
}
env.M = {}

local block = support.extract_block(PLUGIN .. "/zlibrary/cache.lua", "(\nfunction M:new%(.-\nend\n)")
local chunk = assert(loadstring(block, "=Cache:new"))
setfenv(chunk, env)
chunk()
local Cache = env.M

-- ---------------------------------------------------------------- the bug
local domains_a = Cache:new{ name = "_domains_cache" }
local domains_b = Cache:new{ name = "_domains_cache" }
r.check("the same named kv cache is handed out twice", domains_a == domains_b,
        "two independent copies of one file, each unaware of the other's writes")
r.check("and it is only opened once", inits.kv == 1, inits.kv .. " opens of the same file")

-- Different names are different files, and must stay separate.
local check_cache = Cache:new{ name = "_domains_check_cache" }
r.check("a different name is a different cache", check_cache ~= domains_a and inits.kv == 2,
        "two names collapsed into one cache")

-- A kv cache with no name at all still resolves to one shared default rather than a new object
-- per call, which is what the unnamed path did before.
local default_a = Cache:new{}
local default_b = Cache:new{}
r.check("the unnamed kv cache is shared too", default_a == default_b and inits.kv == 3,
        "the default kv cache is still rebuilt per call")
r.check("and is not confused with a named one", default_a ~= domains_a,
        "the unnamed cache collided with a named one")

-- ---------------------------------------------------------------- what already worked
local cover_a = Cache:new{ type = "cover" }
local cover_b = Cache:new{ type = "cover" }
local info = Cache:new{ type = "bookinfo" }
r.check("cover and bookinfo caches are still single instances",
        cover_a == cover_b and inits.cover == 1 and inits.bookinfo == 1,
        "cover inits: " .. inits.cover .. ", bookinfo inits: " .. inits.bookinfo)
r.check("and the three kinds do not collide",
        cover_a ~= info and cover_a ~= domains_a, "two kinds returned the same object")

r.check("an unknown kind is refused rather than guessed at",
        Cache:new{ type = "nonsense" } == nil, "an unknown cache type was built anyway")

r.finish()
