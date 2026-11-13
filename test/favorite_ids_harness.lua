-- Does the favourite button know about every favourite, and stop asking when there are none?
--
-- The ids behind the book details' favourite button came from page 1 of the saved list, which
-- the endpoint caps at 30. Once that cache exists it is taken as the whole truth, so the 31st
-- favourite and every older one showed "Add To Favorites". Api.getFavoriteBookIds now reads
-- every page (up to a bound), and fails rather than return a partial list.
--
-- Separately, Preloader.getFavoriteBookIds refetched on every call for a reader with no
-- favourites at all: the empty id table failed its next() test and never counted as cached.
--
-- Drives the real Api.getFavoriteBookIds with a scripted transport, and the real preloader
-- function compiled out of zlibrary/preloader.lua.

local PLUGIN = assert(arg[1], "usage: luajit favorite_ids_harness.lua <plugin-root> <luasocket-src>")
local LUASOCKET = assert(arg[2], "usage: luajit favorite_ids_harness.lua <plugin-root> <luasocket-src>")

package.path = PLUGIN .. "/?.lua;" .. package.path
local support = dofile(PLUGIN .. "/test/support.lua")
support.preload_socket(LUASOCKET)
support.preload_koreader_stubs()
local r = support.reporter()

local LIMIT = 30
local function page_body(first_id, count, current, total_pages)
    local books = {}
    for i = 0, count - 1 do books[#books + 1] = { id = first_id + i, title = "T", author = "A" } end
    return { success = 1, books = books,
             pagination = total_pages and { current = current, total_pages = total_pages } or nil }
end

-- Bodies are looked up by name rather than parsed, as in api_wrappers_harness.
local BODIES = {}
package.preload["json"] = function()
    return { decode = setmetatable({ simple = {} }, { __call = function(_, s)
        local v = BODIES[s]
        if not v then error("parse error: " .. tostring(s)) end
        return v
    end }) }
end

local real_config_urls = PLUGIN .. "/zlibrary/config_urls.lua"
local Config = {
    getUserAgent = function() return "UA" end,
    getPopularTimeout = function() return { 15, 30 } end,
    getBaseUrl = function() return "https://z.example" end,
    SEARCH_RESULTS_LIMIT = LIMIT,
}
-- The real URL builder, so the page number it puts on the wire is the one checked.
do
    local block = support.extract_block(real_config_urls,
        "(\nfunction Config%.getFavoriteBookIdsUrl%(.-\nend\n)")
    local chunk = assert(loadstring(block, "=getFavoriteBookIdsUrl"))
    setfenv(chunk, { Config = Config, string = string, tonumber = tonumber })
    chunk()
end
package.preload["zlibrary.config"] = function() return Config end
package.preload["socket.http"] = function()
    return { request = function() error("the transport is stubbed in this harness") end }
end

local Api = require("zlibrary.api")
local requests
local script -- page number -> response
Api.makeHttpRequest = function(options)
    table.insert(requests, options.url)
    local page = tonumber(options.url:match("[?&]page=(%d+)"))
    return script[page] or { error = "no page " .. tostring(page) }
end

local function run(pages)
    requests, script = {}, pages
    return Api.getFavoriteBookIds("42", "key")
end

local function ids_of(res)
    local seen = {}
    for _, b in ipairs(res.books or {}) do seen[b.id] = true end
    return seen
end

-- ---------------------------------------------------------------- the URL
r.check("the ids URL names the page it asks for",
        Config.getFavoriteBookIdsUrl(3) == "https://z.example/eapi/user/book/saved?order=saved_date&page=3&limit=30",
        Config.getFavoriteBookIdsUrl(3))
r.check("and defaults to page 1",
        Config.getFavoriteBookIdsUrl():find("page=1&", 1, true) ~= nil, Config.getFavoriteBookIdsUrl())

-- ---------------------------------------------------------------- one page
BODIES.single = page_body(1, 5, 1, 1)
local res = run({ { body = "single" } })
r.check("a single page is read once", #requests == 1, #requests .. " requests")
r.check("and every id on it is returned", #(res.books or {}) == 5 and res.error == nil, tostring(res.error))

-- ---------------------------------------------------------------- several pages
BODIES.p1 = page_body(1, LIMIT, 1, 3)
BODIES.p2 = page_body(31, LIMIT, 2, 3)
BODIES.p3 = page_body(61, 7, 3, 3)
res = run({ { body = "p1" }, { body = "p2" }, { body = "p3" } })
local seen = ids_of(res)
r.check("every page is read", #requests == 3, #requests .. " requests")
r.check("the 31st favourite is known", seen[31] == true)
r.check("so is the last one", seen[67] == true and #res.books == 67, #(res.books or {}) .. " ids")
r.check("only ids cross the pipe", res.books[1].title == nil)

-- No pagination block: a full page means another may follow, a short one ends it.
BODIES.u1 = page_body(1, LIMIT)
BODIES.u2 = page_body(31, 4)
res = run({ { body = "u1" }, { body = "u2" } })
r.check("without pagination, a full page leads to the next", #requests == 2 and #res.books == 34,
        #requests .. " requests, " .. #(res.books or {}) .. " ids")

-- ---------------------------------------------------------------- a later page failing
res = run({ { body = "p1" }, { error = "Request timed out" } })
r.check("a failure on a later page is an error, not a partial list",
        res.error == "Request timed out" and res.books == nil, tostring(res.error))

-- ---------------------------------------------------------------- the bound
BODIES.endless = page_body(1, LIMIT, 1, 999)
local endless = setmetatable({}, { __index = function() return { body = "endless" } end })
res = run(endless)
r.check("reading stops at a bound however many pages the server claims",
        #requests == 20 and res.error == nil, #requests .. " requests")

-- ---------------------------------------------------------------- no favourites
BODIES.none = { success = 1, books = {}, pagination = { current = 1, total_pages = 0 } }
res = run({ { body = "none" } })
r.check("no favourites is an empty list, not an error",
        res.error == nil and type(res.books) == "table" and #res.books == 0, tostring(res.error))

-- ---------------------------------------------------------------- the preloader's cache test
do
    local block = support.extract_block(PLUGIN .. "/zlibrary/preloader.lua",
        "(\nfunction%s+Preloader%.getFavoriteBookIds%(.-\nend\n)")
    local cached, pushed = nil, 0
    local env = {
        type = type, next = next, ipairs = ipairs, tostring = tostring,
        Preloader = {},
        getSafeCallback = function(cb) return cb or function() end end,
        Config = {
            getConfigRuntimeCache = function()
                return { get = function() return cached end, insert = function() end }
            end,
            hasCredentials = function() return true end,
        },
        NetworkMgr = { isConnected = function() return true end },
        ApiHelper = { fetchWithAuth = function() end },
        Api = {},
        _pushTask = function() pushed = pushed + 1 end,
    }
    local chunk = assert(loadstring(block, "=Preloader.getFavoriteBookIds"))
    setfenv(chunk, env)
    chunk()

    local answered
    cached = {}
    env.Preloader.getFavoriteBookIds(function(ok) answered = ok end)
    r.check("an empty cached id list counts as cached", answered == true and pushed == 0,
            "pushed " .. pushed .. " fetches")
    cached = nil
    env.Preloader.getFavoriteBookIds(function(ok) answered = ok end)
    r.check("no cache at all still fetches", pushed == 1, "pushed " .. pushed .. " fetches")
end

r.finish()
