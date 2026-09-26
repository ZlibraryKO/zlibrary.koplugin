-- Login goes through rpc.php (action=login) first, then /eapi/user/login.
--
-- The website (and the desktop app's login webview) use rpc.php with a plain form POST -- no CSRF
-- token, no prior cookie (verified against the live server). It returns the session under
-- `response`:
--   success      -> {"errors":[],"response":{"user_id":21699629,"user_key":"..."}}
--   wrong creds  -> {"errors":[],"response":{"validationError":true,"message":"Incorrect email or password"}}
--
-- /eapi/user/login is the endpoint 1.0.48 moved away from, when it began answering valid
-- credentials with "Authorization failed". It serves login again, and readers whose credentials
-- work in a browser keep being told by rpc.php that their password is wrong (#239), so a refusal
-- from one endpoint is now put to the other before the reader hears about it. That fallback has
-- to stay narrow: it runs when the server read the request and refused it, never when nothing
-- answered or when the mirror is refusing automated access altogether.
--
-- Drives the real Api.login over a stubbed socket.http so the requests it builds (endpoints +
-- fields), the order it tries them in, and the way it reads both shapes are tested as they run.

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
        getLegacyLoginUrl = function() return "https://z-lib.example/eapi/user/login" end,
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
    -- The /eapi envelope, which is a different shape: the session sits under `user`, with the key
    -- named remix_userkey, and the error is a bare string.
    eapi_ok    = { success = 1, user = { id = 21699629, remix_userkey = "f34263e7cd15732f40dcb9850f8c6cef" } },
    eapi_wrong = { success = 0, error = "Incorrect email or password" },
    eapi_authz = { success = 0, error = "Authorization failed" },
    -- What a run of sign-ins earns: rpc.php says it with a 200 and an errors[] entry, /eapi with a
    -- 400 and a bare string. Seen while probing the live server.
    rate_limit      = { errors = { { code = 99, message = "Too many logins #2. Try again later." } }, response = nil },
    eapi_rate_limit = { success = 0, error = "Too many logins #2. Try again later." },
}
package.preload["json"] = function()
    return { decode = setmetatable({ simple = {} }, { __call = function(_, s)
        local v = BODIES[s]
        if not v then error("parse error: " .. tostring(s)) end
        return v
    end }) }
end

local RPC = "https://z-lib.example/rpc.php"
local EAPI = "https://z-lib.example/eapi/user/login"

-- What the server answers. A bare value answers every request with it; a table keyed by URL scripts
-- the endpoints separately, which is how the fallback is driven. A value of false makes the request
-- fail at the transport, the way a timeout does.
local last, requests, serve
local function scripted_for(url)
    if type(serve) == "table" then
        local body = serve[url]
        assert(body ~= nil, "harness: nothing scripted for " .. tostring(url))
        return body
    end
    return serve
end
package.preload["socket.http"] = function()
    return { request = function(p)
        -- Drain the ltn12 body source so the request body can be asserted.
        local body = ""
        if p.source then while true do local c = p.source(); if not c then break end; body = body .. c end end
        last = { url = p.url, method = p.method, body = body, headers = p.headers }
        requests[#requests + 1] = last
        local answer = scripted_for(p.url)
        if answer == false then return nil, "timeout" end
        if p.sink then p.sink(answer) end
        return 1, 200, {}, "HTTP/1.1 200"
    end }
end
local function requested(url)
    local n = 0
    for _, req in ipairs(requests) do if req.url == url then n = n + 1 end end
    return n
end
-- Capture logger output so the login diagnostics can be asserted -- and, above all, that they never
-- leak the password. preload_koreader_stubs made logger a no-op; override it before api.lua loads.
local logs = {}
package.preload["logger"] = function()
    local function cap(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        logs[#logs + 1] = table.concat(parts, " ")
    end
    return { dbg = cap, info = cap, warn = cap, err = cap }
end
local function logged(needle)
    for _, line in ipairs(logs) do if line:find(needle, 1, true) then return true end end
    return false
end

local Api = require("zlibrary.api")

local function login_returning(script)
    serve = script
    requests = {}
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

-- ---------------------------------------------------------------- diagnostics are credential-safe
-- The "signs in for me, not for them" reports need logs that say WHICH mirror rejected the login and
-- with what HTTP status -- to tell a wrong password (JSON validationError, 200) apart from a mirror
-- whose rpc.php does not serve login -- but never the password.
login_returning("wrong_pw")
r.check("a rejected login logs the mirror and the HTTP status",
        logged("server=https://z-lib.example/rpc.php") and logged("status=200"),
        "logs: " .. table.concat(logs, " | "))

-- A mirror answering with a non-JSON body (an HTML error or browser-check page) logs a truncated
-- slice -- enough to recognise it, without dumping a whole page into crash.log.
local NONJSON = string.rep("A", 350) .. "TAILMARKER"
login_returning(NONJSON)
r.check("a non-JSON response logs the mirror and a truncated body",
        logged("server=https://z-lib.example/rpc.php") and logged("AAAAAAAAAA")
            and not logged("TAILMARKER"),
        "logs: " .. table.concat(logs, " | "))

-- The whole point of building the diagnostics by hand rather than dumping the request: the password
-- is in the request body, which is never logged. Checked across every login run above.
r.check("no log line ever contains the password (credential-safe)",
        not logged("correct horse"), "the password leaked into a log line")

-- ---------------------------------------------------------------- the /eapi/user/login fallback
-- The case the fallback exists for: rpc.php says the password is wrong, the old endpoint signs the
-- same credentials in. The reader is signed in and never sees a rejection.
res = login_returning{ [RPC] = "wrong_pw", [EAPI] = "eapi_ok" }
r.check("a refusal from rpc.php is put to the legacy endpoint", requested(EAPI) == 1,
        requested(EAPI) .. " requests to " .. EAPI)
r.check("and a session from there signs the reader in",
        res.error == nil and res.user_id == "21699629"
            and res.user_key == "f34263e7cd15732f40dcb9850f8c6cef",
        "error=" .. tostring(res.error) .. " id=" .. tostring(res.user_id))
r.check("the fallback posts the bare pair the old endpoint takes, not the rpc fields",
        last.url == EAPI and last.body:find("email=", 1, true) and last.body:find("password=", 1, true)
            and not last.body:find("action=login", 1, true), last.body)

-- A sign-in that works must still cost one request: the fallback is a failure path only.
res = login_returning{ [RPC] = "ok" }
r.check("a successful sign-in costs a single request",
        res.user_id == "21699629" and #requests == 1 and requested(EAPI) == 0,
        #requests .. " requests")

-- Both refuse: one rejection, reported once, still correctable in place.
res = login_returning{ [RPC] = "wrong_pw", [EAPI] = "eapi_wrong" }
r.check("when both refuse, the reader is told the credentials were rejected",
        res.error == "Incorrect email or password" and res.user_id == nil
            and Api.isCredentialRejection(res.error) == true,
        "error = " .. tostring(res.error))

-- The old endpoint's own breakage (what 1.0.48 moved away from) must not become the message: it
-- says nothing the reader can act on, where rpc.php's rejection does.
res = login_returning{ [RPC] = "wrong_pw", [EAPI] = "eapi_authz" }
r.check("a fallback failure does not replace a rejection from the first endpoint",
        res.error == "Incorrect email or password", "error = " .. tostring(res.error))

-- The other way round: rpc.php serves something unreadable, the fallback reads the credentials and
-- refuses them. "Incorrect email or password" can be fixed in place; "Invalid response format"
-- cannot, so the fallback's message is the one worth showing.
res = login_returning{ [RPC] = NONJSON, [EAPI] = "eapi_wrong" }
r.check("a rejection from the fallback beats an unreadable answer from the first endpoint",
        res.error == "Incorrect email or password", "error = " .. tostring(res.error))

-- A lockout is the server asking for fewer requests, not a verdict on the password. Asking the
-- other endpoint would spend another attempt for nothing and reach the limit twice as fast, on the
-- very path where readers retry most.
res = login_returning{ [RPC] = "rate_limit", [EAPI] = "eapi_ok" }
r.check("a rate-limited sign-in is not retried against the other endpoint", requested(EAPI) == 0,
        requested(EAPI) .. " requests to " .. EAPI)
r.check("and the reader is told to try again later, not that the password is wrong",
        res.error == "Too many logins #2. Try again later." and res.user_id == nil
            and Api.isCredentialRejection(res.error) == false,
        "error = " .. tostring(res.error))
r.check("the lockout is recognised in either endpoint's wording",
        Api.isRateLimited("Too many logins #2. Try again later.") == true
            and Api.isRateLimited("Incorrect email or password") == false,
        "isRateLimited misreads one of the two")

-- Nothing answered: a second endpoint on the same dead connection would only double the wait.
res = login_returning{ [RPC] = false }
r.check("a transport failure is not retried against the other endpoint",
        requested(EAPI) == 0 and res.user_id == nil, requested(EAPI) .. " requests to " .. EAPI)

-- A mirror refusing automated access refuses both endpoints, and its message is the one that tells
-- the reader what to do, so it must survive rather than be replaced by a second refusal.
local CHALLENGE = "<html><head><title>Access Denied | DiamWall</title></head><body></body></html>"
res = login_returning{ [RPC] = CHALLENGE }
r.check("a blocked mirror is not retried against the other endpoint", requested(EAPI) == 0,
        requested(EAPI) .. " requests to " .. EAPI)
r.check("and it keeps the \"try a different server\" message",
        res.error and res.error:find(Api.BLOCKED_TEXT, 1, true) ~= nil,
        "error = " .. tostring(res.error))

-- ---------------------------------------------------------------- wiring
local function slurp(p) local fh = assert(io.open(p)); local s = fh:read("*a"); fh:close(); return s end
r.check("getLoginUrl points at rpc.php",
        slurp(PLUGIN .. "/zlibrary/config.lua"):find("/rpc.php", 1, true) ~= nil,
        "config.lua no longer builds the rpc.php login URL")
r.check("getLegacyLoginUrl points at /eapi/user/login",
        slurp(PLUGIN .. "/zlibrary/config.lua"):find("/eapi/user/login", 1, true) ~= nil,
        "config.lua no longer builds the legacy login URL")

r.finish()
