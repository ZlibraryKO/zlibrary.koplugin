-- Login goes through rpc.php (action=login), not /eapi/user/login.
--
-- The old endpoint answers valid credentials with "Authorization failed"; the website (and the
-- desktop app's login webview) use rpc.php with a plain form POST -- no CSRF token, no prior cookie
-- (verified against the live server). rpc.php returns the session under `response`:
--   success      -> {"errors":[],"response":{"user_id":21699629,"user_key":"..."}}
--   wrong creds  -> {"errors":[],"response":{"validationError":true,"message":"Incorrect email or password"}}
--
-- Drives the real Api.login over a stubbed socket.http so the request it builds (endpoint + fields)
-- and the way it reads those two shapes are tested as they actually run.

local PLUGIN = assert(arg[1], "usage: luajit rpc_login_harness.lua <plugin-root> <luasocket-src>")
local LUASOCKET = assert(arg[2], "usage: luajit rpc_login_harness.lua <plugin-root> <luasocket-src>")

package.path = PLUGIN .. "/?.lua;" .. package.path
local support = dofile(PLUGIN .. "/test/support.lua")
support.preload_socket(LUASOCKET)
support.preload_koreader_stubs()
local r = support.reporter()

package.preload["zlibrary.config"] = function()
    return {
        USER_AGENT = "UA",
        getBaseUrl = function() return "https://z-lib.example" end,
        getLoginUrl = function() return "https://z-lib.example/rpc.php" end,
        getLoginTimeout = function() return { 10, 15 } end,
        -- makeHttpRequest collaborators (redirect cache + bot-block memory); no-ops here.
        setCacheRealUrl = function() end,
        getCacheRealUrl = function() return nil end,
        clearCacheRealUrlIfPinned = function() return false end,
        markMirrorBlocked = function() end,
    }
end

-- json.decode is a lookup keyed by the body the socket emits (the support stub refuses to parse).
local BODIES = {
    ok       = { errors = {}, response = { user_id = 21699629, user_key = "f34263e7cd15732f40dcb9850f8c6cef" } },
    wrong_pw = { errors = {}, response = { validationError = true, fields = { "email", "password" }, message = "Incorrect email or password" } },
    other    = { errors = { "Service temporarily unavailable" }, response = {} },
}
package.preload["json"] = function()
    return { decode = setmetatable({ simple = {} }, { __call = function(_, s)
        local v = BODIES[s]
        if not v then error("parse error: " .. tostring(s)) end
        return v
    end }) }
end

local last
local serve
package.preload["socket.http"] = function()
    return { request = function(p)
        -- Drain the ltn12 body source so the request body can be asserted.
        local body = ""
        if p.source then while true do local c = p.source(); if not c then break end; body = body .. c end end
        last = { url = p.url, method = p.method, body = body, headers = p.headers }
        if p.sink then p.sink(serve) end
        return 1, 200, {}, "HTTP/1.1 200"
    end }
end
local Api = require("zlibrary.api")

local function login_returning(key)
    serve = key
    return Api.login("reader@example.com", "correct horse")
end

-- ---------------------------------------------------------------- the request it builds
login_returning("ok")
r.check("login posts to rpc.php", last.url == "https://z-lib.example/rpc.php", "url = " .. tostring(last.url))
r.check("login is a POST", last.method == "POST", "method = " .. tostring(last.method))
r.check("the body carries action=login", last.body:find("action=login", 1, true) ~= nil, last.body)
r.check("the body carries the extra rpc fields",
        last.body:find("gg_json_mode=1", 1, true) and last.body:find("site_mode=books", 1, true)
            and last.body:find("isModal=true", 1, true), last.body)
r.check("the body carries the credentials",
        last.body:find("email=", 1, true) and last.body:find("password=", 1, true), last.body)

-- ---------------------------------------------------------------- success (session under `response`)
local res = login_returning("ok")
r.check("a successful login returns the session from `response`",
        res.error == nil and res.user_id == "21699629" and res.user_key == "f34263e7cd15732f40dcb9850f8c6cef",
        "error=" .. tostring(res.error) .. " id=" .. tostring(res.user_id) .. " key=" .. tostring(res.user_key))

-- ---------------------------------------------------------------- wrong password
res = login_returning("wrong_pw")
r.check("a wrong password surfaces the server's message",
        res.error == "Incorrect email or password" and res.user_id == nil,
        "error = " .. tostring(res.error))
r.check("and it is classified as a credential rejection (so it can be fixed in place)",
        Api.isCredentialRejection(res.error) == true, "not a rejection")

-- ---------------------------------------------------------------- some other server error
res = login_returning("other")
r.check("an errors[] entry with no session is surfaced as the error",
        res.error == "Service temporarily unavailable" and res.user_id == nil,
        "error = " .. tostring(res.error))
r.check("and an unrelated error is not a credential rejection",
        Api.isCredentialRejection(res.error) == false, "wrongly a rejection")

-- ---------------------------------------------------------------- wiring
local function slurp(p) local fh = assert(io.open(p)); local s = fh:read("*a"); fh:close(); return s end
r.check("getLoginUrl points at rpc.php",
        slurp(PLUGIN .. "/zlibrary/config.lua"):find("/rpc.php", 1, true) ~= nil,
        "config.lua no longer builds the rpc.php login URL")

r.finish()
