-- What does the reader see when the login endpoint refuses them?
--
-- Z-library answers /eapi/user/login with two different wordings, confirmed on device:
--   * "Incorrect email or password" -- the password really is wrong
--   * "Authorization failed"        -- credentials are valid but the server is refusing the sign-in
--                                      (seen hitting many accounts at once and clearing on its own)
--
-- The bare "Authorization failed" is cryptic and, worse, invites the reader to doubt an account that
-- is fine. So Api.login rewrites just that case into a clear, reassuring message -- while leaving the
-- genuinely-wrong-password wording (and everything else) exactly as the server sent it. Crucially the
-- rewritten message must NOT read as a credential rejection, or the plugin would stop saving the
-- (valid) credentials and blame them.
--
-- Drives the real Api.login with a stubbed socket.http, so the mapping and the classifier are tested
-- together as they actually run.

local PLUGIN = assert(arg[1], "usage: luajit login_message_harness.lua <plugin-root> <luasocket-src>")
local LUASOCKET = assert(arg[2], "usage: luajit login_message_harness.lua <plugin-root> <luasocket-src>")

package.path = PLUGIN .. "/?.lua;" .. package.path
local support = dofile(PLUGIN .. "/test/support.lua")
support.preload_socket(LUASOCKET)
support.preload_koreader_stubs()
local r = support.reporter()

package.preload["zlibrary.config"] = function()
    return {
        USER_AGENT = "UA",
        getLoginUrl = function() return "https://z-lib.example/eapi/user/login" end,
        getLoginTimeout = function() return { 10, 15 } end,
        -- Needed by makeHttpRequest's redirect-cache handling.
        setCacheRealUrl = function() end,
        getCacheRealUrl = function() return nil end,
        clearCacheRealUrlIfPinned = function() return false end,
    }
end

-- json.decode is a lookup keyed by the exact body the socket emits (the support stub's json
-- deliberately refuses to parse, so it must be overridden). Each case sends a short key as the body.
local BODIES = {
    auth_failed = { success = 0, error = "Authorization failed" },
    wrong_pw    = { success = 0, error = "Incorrect email or password" },
    other_error = { success = 0, error = "Some other problem" },
    ok          = { success = 1, user = { id = "42", remix_userkey = "deadbeef" } },
}
package.preload["json"] = function()
    return { decode = setmetatable({ simple = {} }, { __call = function(_, s)
        local v = BODIES[s]
        if not v then error("parse error: " .. tostring(s)) end
        return v
    end }) }
end

local serve
package.preload["socket.http"] = function()
    return { request = function(p) return serve(p) end }
end
local Api = require("zlibrary.api")

-- Answer the login POST with the body keyed by `key` at status 200 (the server returns its JSON
-- errors with 200).
local function login_returning(key)
    serve = function(p)
        if p.sink then p.sink(key) end
        return 1, 200, {}, "HTTP/1.1 200"
    end
    return Api.login("reader@example.com", "correct-horse-battery-staple")
end

-- ---------------------------------------------------------------- "Authorization failed" (the outage)
local res = login_returning("auth_failed")
r.check("the bare 'Authorization failed' string is not what the reader sees",
        res.error and res.error:find("Authorization failed", 1, true) == nil,
        "error = " .. tostring(res.error))
r.check("a clearer, reassuring message is shown instead",
        res.error and res.error:lower():find("temporary", 1, true) ~= nil
            and res.error:find("Z-library", 1, true) ~= nil,
        "error = " .. tostring(res.error))
r.check("it is NOT classified as a credential rejection, so valid credentials are kept, not blamed",
        Api.isCredentialRejection(res.error) == false,
        "wrongly classified as a rejection: " .. tostring(res.error))

-- ---------------------------------------------------------------- genuinely wrong password
res = login_returning("wrong_pw")
r.check("a genuinely wrong password keeps the server's own wording",
        res.error == "Incorrect email or password", "error = " .. tostring(res.error))
r.check("and it IS still classified as a credential rejection",
        Api.isCredentialRejection(res.error) == true,
        "no longer classified as a rejection")

-- ---------------------------------------------------------------- an unrelated server error
res = login_returning("other_error")
r.check("an unrelated server error passes through unchanged",
        res.error == "Some other problem", "error = " .. tostring(res.error))
r.check("and an unrelated error is not treated as a rejection",
        Api.isCredentialRejection(res.error) == false, "wrongly a rejection")

-- ---------------------------------------------------------------- a successful login still works
res = login_returning("ok")
r.check("a successful login still returns the session, no error",
        res.error == nil and res.user_id == "42" and res.user_key == "deadbeef",
        "error=" .. tostring(res.error) .. " id=" .. tostring(res.user_id))

r.finish()
