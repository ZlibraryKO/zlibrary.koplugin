-- Drives the real Api.makeHttpRequest through a scripted server to check the follow loop.
--
-- redirect_resolve_harness proves which Location shapes resolve. This proves what
-- makeHttpRequest then DOES with them: that it follows more than one hop, that a 307 POST
-- re-sends its body instead of an empty one, that a 302 POST degrades to GET per RFC, that a
-- mirror pointing at itself is not chased five times, and that a cookie set by a challenge is
-- returned to the host that set it and to nowhere else.
--
-- The body case is the subtle one. An ltn12 source is a one-shot generator, so a naive re-issue
-- sends nothing while still advertising the original Content-Length: the server would see a
-- blank sign-in and reject it, with no clue in any log as to why.

local PLUGIN = assert(arg[1], "usage: luajit redirect_follow_harness.lua <plugin-root> <luasocket-src>")
local LUASOCKET = assert(arg[2], "usage: luajit redirect_follow_harness.lua <plugin-root> <luasocket-src>")

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

-- Scripted server: routes keyed by URL, plus a log of every request it actually received.
local server = { routes = {}, seen = {} }
local function default_request(params)
    local body = nil
    if params.source then
        local parts = {}
        while true do
            local chunk = params.source()
            if not chunk then break end
            table.insert(parts, chunk)
        end
        body = table.concat(parts)
    end
    table.insert(server.seen, {
        url = params.url, method = params.method, body = body,
        cookie = params.headers and params.headers["Cookie"],
        content_length = params.headers and params.headers["Content-Length"],
        content_type = params.headers and params.headers["Content-Type"],
    })
    local route = server.routes[params.url] or { status = 404 }
    if route.body and params.sink then params.sink(route.body) end
    return 1, route.status, route.headers or {}, "HTTP/1.1 " .. tostring(route.status)
end

local http_stub = { request = function(params) return server.handler(params) end }
package.preload["socket.http"] = function() return http_stub end

local Api = require("zlibrary.api")

local function reset(routes, handler)
    server.routes, server.seen, pinned = routes or {}, {}, nil
    server.handler = handler or default_request
end

local A = "https://a.example/eapi/user/login"

-- ---------------------------------------------------------------- relative 307 keeps the body
reset({
    [A] = { status = 307, headers = { location = "/eapi/v2/login" } },
    ["https://a.example/eapi/v2/login"] = { status = 200, body = "{}" },
})
local res = Api.makeHttpRequest{
    url = A, method = "POST", body = "email=x&password=y",
    headers = { ["Content-Length"] = "18", ["Content-Type"] = "application/x-www-form-urlencoded" },
}
r.check("relative 307: reaches the final URL", res.status_code == 200,
        "status " .. tostring(res.status_code) .. " error=" .. tostring(res.error))
r.check("relative 307: two requests made", #server.seen == 2, "made " .. #server.seen)
r.check("relative 307: method stays POST",
        server.seen[2] and server.seen[2].method == "POST",
        server.seen[2] and server.seen[2].method or "no 2nd request")
r.check("relative 307: body re-sent, not empty",
        server.seen[2] and server.seen[2].body == "email=x&password=y",
        server.seen[2] and string.format("%q", tostring(server.seen[2].body)) or "no 2nd request")

-- ---------------------------------------------------------------- multi-hop across hosts
reset({
    [A] = { status = 307, headers = { location = "https://b.example/eapi/user/login" } },
    ["https://b.example/eapi/user/login"] = { status = 307, headers = { location = "https://c.example/eapi/user/login" } },
    ["https://c.example/eapi/user/login"] = { status = 200, body = "{}" },
})
res = Api.makeHttpRequest{ url = A, method = "POST", body = "x=1", headers = {} }
r.check("two cross-host hops complete", res.status_code == 200,
        "status " .. tostring(res.status_code) .. " error=" .. tostring(res.error))
r.check("two cross-host hops: 3 requests", #server.seen == 3, "made " .. #server.seen)
r.check("two cross-host hops: final base pinned", pinned == "https://c.example", tostring(pinned))

-- ---------------------------------------------------------------- 302 POST degrades to GET
reset({
    [A] = { status = 302, headers = { location = "/after" } },
    ["https://a.example/after"] = { status = 200, body = "{}" },
})
res = Api.makeHttpRequest{
    url = A, method = "POST", body = "email=x",
    headers = { ["Content-Length"] = "7", ["Content-Type"] = "application/x-www-form-urlencoded" },
}
r.check("302 POST becomes GET", server.seen[2] and server.seen[2].method == "GET",
        server.seen[2] and server.seen[2].method or "no 2nd request")
r.check("302 POST drops the body", server.seen[2] and server.seen[2].body == nil,
        server.seen[2] and tostring(server.seen[2].body) or "no 2nd request")
r.check("302 POST drops Content-Length", server.seen[2] and server.seen[2].content_length == nil,
        server.seen[2] and tostring(server.seen[2].content_length) or "no 2nd request")
r.check("302 POST drops Content-Type", server.seen[2] and server.seen[2].content_type == nil,
        server.seen[2] and tostring(server.seen[2].content_type) or "no 2nd request")

-- 301 and 303 take the same route. Only 302 used to be exercised, while the README claimed
-- method conversion "per RFC" for all of them.
for _, status in ipairs({ 301, 303 }) do
    reset({
        [A] = { status = status, headers = { location = "/after" } },
        ["https://a.example/after"] = { status = 200, body = "{}" },
    })
    Api.makeHttpRequest{
        url = A, method = "POST", body = "email=x",
        headers = { ["Content-Length"] = "7", ["Content-Type"] = "application/x-www-form-urlencoded" },
    }
    r.check(status .. " POST becomes GET and drops its body",
            server.seen[2] and server.seen[2].method == "GET"
                and server.seen[2].body == nil
                and server.seen[2].content_length == nil,
            server.seen[2] and (server.seen[2].method .. " body=" .. tostring(server.seen[2].body))
                           or "no 2nd request")
end

-- ---------------------------------------------------------------- loops terminate early
reset({
    [A] = { status = 307, headers = { location = "https://b.example/x" } },
    ["https://b.example/x"] = { status = 307, headers = { location = A } },
})
res = Api.makeHttpRequest{ url = A, method = "GET", headers = {} }
r.check("A<->B loop terminates", res.error ~= nil and res.status_code ~= 200,
        "error=" .. tostring(res.error))
r.check("A<->B loop stops at 2 requests", #server.seen == 2, "made " .. #server.seen)

-- The real 1lib.sk shape: a WAF answering with a Location pointing at the request URL. Hopeless
-- on the first hop, so exactly one request must go out. Chasing it five times only loads a free
-- service to learn what was already known.
reset({ [A] = { status = 307, headers = { location = A } } })
res = Api.makeHttpRequest{ url = A, method = "GET", headers = {} }
r.check("self-redirect: exactly one request", #server.seen == 1, "made " .. #server.seen)
r.check("self-redirect: reports too many redirects",
        res.error and string.find(tostring(res.error), "Too many redirects", 1, true) ~= nil,
        "error=" .. tostring(res.error))

reset({ [A] = { status = 307, headers = { location = "/eapi/user/login" } } })
res = Api.makeHttpRequest{ url = A, method = "GET", headers = {} }
r.check("self-redirect via relative Location: one request", #server.seen == 1, "made " .. #server.seen)

-- A chain of distinct URLs must stop at the hop cap. Without this the bound could be raised to
-- any value with the suite still green, and a long chain would hammer a free service.
local chain = {}
for i = 1, 9 do
    chain["https://a.example/h" .. i] =
        { status = 307, headers = { location = "https://a.example/h" .. (i + 1) } }
end
reset(chain)
res = Api.makeHttpRequest{ url = "https://a.example/h1", method = "GET", headers = {} }
r.check("hop cap reached: chain stops at 6 requests", #server.seen == 6, "made " .. #server.seen)
r.check("hop cap reached: reported as too many redirects",
        res.error and string.find(tostring(res.error), "Too many redirects", 1, true) ~= nil,
        "error=" .. tostring(res.error))

-- A host issuing a fresh cookie every time defeats the loop guard by design, so the hop cap is
-- the only thing left bounding it.
local ck = 0
reset(nil, function(params)
    ck = ck + 1
    table.insert(server.seen, { url = params.url })
    return 1, 307, { location = params.url, ["set-cookie"] = "c=v" .. ck .. "; Path=/" },
           "HTTP/1.1 307"
end)
ck = 0
res = Api.makeHttpRequest{ url = A, method = "GET", headers = {} }
r.check("ever-fresh cookie is still bounded by the hop cap", #server.seen == 6,
        "made " .. #server.seen)

-- ---------------------------------------------------------------- 308 and the no-Location case
reset({
    [A] = { status = 308, headers = { location = "/moved" } },
    ["https://a.example/moved"] = { status = 200, body = "{}" },
})
res = Api.makeHttpRequest{ url = A, method = "POST", body = "x=1", headers = {} }
r.check("308 followed, method preserved",
        res.status_code == 200 and server.seen[2] and server.seen[2].method == "POST",
        "status " .. tostring(res.status_code))

reset({ [A] = { status = 307, headers = {} } })
res = Api.makeHttpRequest{ url = A, method = "GET", headers = {} }
r.check("307 with no Location does not loop",
        #server.seen == 1 and res.status_code == 307,
        "requests=" .. #server.seen .. " status=" .. tostring(res.status_code))

-- ---------------------------------------------------------------- cookie challenge
-- A 307 plus Set-Cookie asks the client to prove it keeps cookies. Without echoing it the retry
-- is byte-identical to the request that was just challenged, so the mirror challenges it again.
local visits = 0
reset(nil, function(params)
    visits = visits + 1
    table.insert(server.seen, { url = params.url,
                                cookie = params.headers and params.headers["Cookie"] })
    if visits == 1 then
        return 1, 307, { location = A, ["set-cookie"] = "DiamWall=tok123; Path=/; HttpOnly" },
               "HTTP/1.1 307"
    end
    if params.sink then params.sink("{}") end
    return 1, 200, {}, "HTTP/1.1 200"
end)
visits = 0
res = Api.makeHttpRequest{ url = A, method = "GET",
                           headers = { ["Cookie"] = "remix_userid=42; remix_userkey=abc" } }
r.check("cookie challenge: retried and succeeded", res.status_code == 200,
        "status " .. tostring(res.status_code) .. " error=" .. tostring(res.error))
r.check("cookie challenge: exactly 2 requests", #server.seen == 2, "made " .. #server.seen)
local sent = server.seen[2] and server.seen[2].cookie or ""
r.check("cookie challenge: WAF cookie echoed",
        string.find(sent, "DiamWall=tok123", 1, true) ~= nil, "Cookie: " .. sent)
r.check("cookie challenge: session cookies preserved",
        string.find(sent, "remix_userid=42", 1, true) ~= nil and
        string.find(sent, "remix_userkey=abc", 1, true) ~= nil, "Cookie: " .. sent)
r.check("cookie challenge: attributes not sent as cookies",
        string.find(sent, "Path=", 1, true) == nil and
        string.find(sent, "HttpOnly", 1, true) == nil, "Cookie: " .. sent)

-- The security property of the whole feature, asserted rather than assumed.
visits = 0
reset(nil, function(params)
    visits = visits + 1
    table.insert(server.seen, { url = params.url,
                                cookie = params.headers and params.headers["Cookie"] })
    if visits == 1 then
        return 1, 307, { location = "https://evil.example/eapi/user/login",
                         ["set-cookie"] = "SECRET=leakme; Path=/" }, "HTTP/1.1 307"
    end
    if params.sink then params.sink("{}") end
    return 1, 200, {}, "HTTP/1.1 200"
end)
visits = 0
res = Api.makeHttpRequest{ url = A, method = "GET", headers = {} }
r.check("cross-host cookie case: the hop actually happened", #server.seen == 2,
        "made " .. #server.seen)
r.check("cross-host cookie case: went to the other host",
        server.seen[2] and server.seen[2].url == "https://evil.example/eapi/user/login",
        server.seen[2] and server.seen[2].url or "no 2nd request")
local cross = server.seen[2] and server.seen[2].cookie or ""
r.check("cookie is NOT replayed to another host",
        string.find(cross, "SECRET", 1, true) == nil,
        "leaked to " .. tostring(server.seen[2] and server.seen[2].url) .. ": " .. cross)

-- ---------------------------------------------------------------- onRedirect still owns moves
-- A cross-host hop must still hand control to the caller's rebuild: only it can reconstruct the
-- API path from config against the new base. Regression guard for the login and search flows.
reset({
    [A] = { status = 307, headers = { location = "https://b.example/" } },
    ["https://b.example/eapi/rebuilt"] = { status = 200, body = "{}" },
})
res = Api.makeHttpRequest{
    url = A, method = "GET", headers = {},
    onRedirect = function() return "https://b.example/eapi/rebuilt" end,
}
r.check("cross-host: onRedirect string is used",
        res.status_code == 200 and server.seen[2] and
        server.seen[2].url == "https://b.example/eapi/rebuilt",
        server.seen[2] and server.seen[2].url or "no 2nd request")
r.check("cross-host: base still pinned for the rebuild",
        pinned == "https://b.example", tostring(pinned))

reset({ [A] = { status = 307, headers = { location = "https://b.example/" } } })
local called_with = nil
res = Api.makeHttpRequest{
    url = A, method = "GET", headers = {},
    onRedirect = function()
        return function(rr) called_with = rr; return { status_code = 200, handled = true } end
    end,
}
r.check("cross-host: onRedirect function is invoked",
        res and res.handled == true and called_with and
        called_with.real_url_base == "https://b.example",
        "handled=" .. tostring(res and res.handled))

r.finish()
