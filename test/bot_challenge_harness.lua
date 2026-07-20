-- Does the plugin recognise a bot-check page, and not mistake anything else for one?
--
-- Some mirrors sit behind a service that answers an API call with a "verifying your browser"
-- interstitial instead of JSON. There is no way past it here -- it wants a browser to run its
-- JavaScript -- so the useful behaviour is to say so and let the caller offer auto-discovery,
-- rather than report a bare "HTTP Error: 513" that tells the user nothing.
--
-- The false-positive cases matter as much as the positive one: branding a working mirror as
-- blocked would push users away from a server that was about to answer them.
--
-- The positive fixture is the real body captured from 1lib.sk in July 2026.

local PLUGIN = assert(arg[1], "usage: luajit bot_challenge_harness.lua <plugin-root> <luasocket-src>")
local LUASOCKET = assert(arg[2], "usage: luajit bot_challenge_harness.lua <plugin-root> <luasocket-src>")

package.path = PLUGIN .. "/?.lua;" .. package.path
local support = dofile(PLUGIN .. "/test/support.lua")
support.preload_socket(LUASOCKET)
support.preload_koreader_stubs()
local r = support.reporter()

package.preload["zlibrary.config"] = function()
    return {
        setCacheRealUrl = function() end,
        getCacheRealUrl = function() return nil end,
        clearCacheRealUrlIfPinned = function() return false end,
    }
end

local DIAMWALL_BODY = [[<html><head>
<meta charset="UTF-8">
<meta http-equiv="X-UA-Compatible" content="IE=edge">
<link rel="icon" type="image/x-icon" href="https://cdn.diamwall.com/cdn-cgi/static/img/favicon/favicon.ico">
<title>Verifying your browser | DiamWall</title>
</head><body style="margin:0px;padding:0px;overflow:hidden">
<iframe src="/.well-known/diamwall/load/html/5s.html" frameborder="0" id="verification"></iframe>
<script>
document.cookie="dwid=705a24e5b672def409d8d8dfbfc08352; path=/; domain="+location.hostname;
</script>
<script src="/cdn-cgi/mitigation/v2/chl/chlb.lib?bdt=0&b12=0&brc=0" defer></script>
</body></html>]]

local serve
package.preload["socket.http"] = function()
    return { request = function(p) return serve(p) end }
end
local Api = require("zlibrary.api")

-- ---------------------------------------------------------------- the observed sequence
-- 307 with a Set-Cookie, then 513 carrying the challenge page once the cookie is returned.
local n = 0
serve = function(p)
    n = n + 1
    if n == 1 then
        return 1, 307, { location = p.url, ["set-cookie"] = "dwid=abc; Path=/" }, "HTTP/1.1 307"
    end
    if p.sink then p.sink(DIAMWALL_BODY) end
    return 1, 513, {}, "HTTP/1.1 513 "
end
local res = Api.makeHttpRequest{ url = "https://1lib.sk/eapi/user/login", method = "GET", headers = {} }
r.check("challenge recognised, not reported as a bare status",
        res.error and res.error:find("refusing automated access", 1, true) ~= nil,
        "error=" .. tostring(res.error))
r.check("error names the host so the user can act",
        res.error and res.error:find("1lib.sk", 1, true) ~= nil, tostring(res.error))
r.check("error says what to do about it",
        res.error and res.error:find("different Z%-library server") ~= nil, tostring(res.error))
r.check("bounded: 2 requests, no hammering", n == 2, "made " .. n)

-- ---------------------------------------------------------------- must not misfire
n = 0
serve = function(p)
    n = n + 1
    if p.sink then p.sink('{"success":0,"error":"Incorrect email or password"}') end
    return 1, 401, {}, "HTTP/1.1 401"
end
res = Api.makeHttpRequest{ url = "https://good.example/eapi/user/login", method = "GET", headers = {} }
r.check("a JSON API error is not misread as a challenge",
        res.error and res.error:find("refusing automated access", 1, true) == nil,
        tostring(res.error))

n = 0
serve = function(p)
    n = n + 1
    if p.sink then p.sink("<html><head><title>502 Bad Gateway</title></head><body>nginx</body></html>") end
    return 1, 502, {}, "HTTP/1.1 502"
end
res = Api.makeHttpRequest{ url = "https://good.example/eapi/user/login", method = "GET", headers = {} }
r.check("an ordinary HTML error page is not misread as a challenge",
        res.error and res.error:find("refusing automated access", 1, true) == nil,
        tostring(res.error))

-- A book whose description happens to quote a challenge phrase must not poison a good response.
n = 0
serve = function(p)
    n = n + 1
    if p.sink then p.sink('{"success":1,"book":{"title":"Verifying your browser: a history"}}') end
    return 1, 200, {}, "HTTP/1.1 200"
end
res = Api.makeHttpRequest{ url = "https://good.example/eapi/book/1", method = "GET", headers = {} }
r.check("a successful response is never inspected for challenge markers",
        res.status_code == 200 and res.error == nil,
        "status=" .. tostring(res.status_code) .. " error=" .. tostring(res.error))

r.finish()
