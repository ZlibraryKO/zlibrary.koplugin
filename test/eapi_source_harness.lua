-- The `source` header every /eapi request now carries, and nothing else does.
--
-- Since 2026-11-23 /eapi/book/search answers 400 {"error":"Access denied"} to a request without a
-- non-empty `source` header. Any value is accepted, so the plugin sends its own name rather than
-- posing as one of Z-library's apps. Drives the real Api.makeHttpRequest through a scripted server
-- and checks what each request actually went out with: the plugin's name on /eapi paths (search,
-- login, downloads list), across a redirect hop, never on the website or a cover, never replacing
-- a value the caller set, and never mutating the caller's headers table.

local PLUGIN = assert(arg[1], "usage: luajit eapi_source_harness.lua <plugin-root> <luasocket-src>")
local LUASOCKET = assert(arg[2], "usage: luajit eapi_source_harness.lua <plugin-root> <luasocket-src>")

package.path = PLUGIN .. "/?.lua;" .. package.path
local support = dofile(PLUGIN .. "/test/support.lua")
support.preload_socket(LUASOCKET)
support.preload_koreader_stubs()
local r = support.reporter()

local pinned = nil
package.preload["zlibrary.config"] = function()
    return {
        setCacheRealUrl = function(_, real) pinned = real end,
        getCacheRealUrl = function() return pinned end,
        clearCacheRealUrlIfPinned = function() return false end,
    }
end

local server = { routes = {}, seen = {} }
local http_stub = { request = function(params)
    local source_header = nil
    for k, v in pairs(params.headers or {}) do
        if string.lower(k) == "source" then source_header = v end
    end
    table.insert(server.seen, { url = params.url, source = source_header, headers = params.headers })
    local route = server.routes[params.url] or { status = 200, body = "{}" }
    if route.body and params.sink then params.sink(route.body) end
    return 1, route.status, route.headers or {}, "HTTP/1.1 " .. tostring(route.status)
end }
package.preload["socket.http"] = function() return http_stub end

local Api = require("zlibrary.api")
local SOURCE = "zlibrary.koplugin"   -- the plugin names itself, like its User-Agent

local function send(url, headers, routes)
    server.routes, server.seen, pinned = routes or {}, {}, nil
    return Api.makeHttpRequest{ url = url, method = "POST", body = "message=dune", headers = headers }
end

-- ---------------------------------------------------------------- /eapi gets it
send("https://z.example/eapi/book/search", { ["User-Agent"] = "ua" })
r.check("search carries source", server.seen[1] and server.seen[1].source == SOURCE,
        tostring(server.seen[1] and server.seen[1].source))
r.check("and keeps the caller's other headers",
        server.seen[1] and server.seen[1].headers["User-Agent"] == "ua")
r.check("and the value is not left on the Api table", Api.EAPI_SOURCE == nil)

send("https://z.example/eapi/user/login", nil)
r.check("a request with no headers table gets one with source",
        server.seen[1] and server.seen[1].source == SOURCE)

send("https://z.example/eapi/user/book/downloaded?page=1&limit=20", {})
r.check("a query string does not hide the /eapi path",
        server.seen[1] and server.seen[1].source == SOURCE)

-- ---------------------------------------------------------------- caller's table untouched
local mine = { ["User-Agent"] = "ua" }
send("https://z.example/eapi/book/search", mine)
r.check("the caller's headers table is not mutated", mine.source == nil)

-- ---------------------------------------------------------------- a caller's value wins
send("https://z.example/eapi/book/search", { Source = "caller-value" })
r.check("a caller-set source (any case) is kept",
        server.seen[1] and server.seen[1].source == "caller-value", tostring(server.seen[1] and server.seen[1].source))
local count = 0
for k in pairs(server.seen[1] and server.seen[1].headers or {}) do
    if string.lower(k) == "source" then count = count + 1 end
end
r.check("and not sent twice", count == 1, "sent " .. count)

-- ---------------------------------------------------------------- nothing else gets it
send("https://z.example/s/dune", {})
r.check("the website search does not", server.seen[1] and server.seen[1].source == nil)
send("https://covers.example/eapi-like/cover.jpg", {})
r.check("a path that only starts like eapi does not", server.seen[1] and server.seen[1].source == nil)
send("https://z.example/dl/123/abc", {})
r.check("a file download does not", server.seen[1] and server.seen[1].source == nil)

-- ---------------------------------------------------------------- across a redirect hop
send("https://a.example/eapi/book/search", {}, {
    ["https://a.example/eapi/book/search"] = { status = 307, headers = { location = "https://b.example/eapi/book/search" } },
    ["https://b.example/eapi/book/search"] = { status = 200, body = "{}" },
})
r.check("both hops of a mirror move carry source", #server.seen == 2
        and server.seen[1].source == SOURCE and server.seen[2].source == SOURCE,
        "made " .. #server.seen)

r.finish()
