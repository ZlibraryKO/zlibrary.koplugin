-- What a forked child is allowed to write, and how anything it learns gets home.
--
-- Every background task this plugin runs -- preloader warmers, cover fetches, discovery probes,
-- downloads -- happens in a forked child. A child has a copy-on-write snapshot of the parent's
-- memory and shares its files, so a flush of the settings file writes that snapshot over whatever
-- the parent has saved since the fork, while the parent (holding its own copy in memory) never
-- sees what the child wrote. Discovery runs three probes at once, each able to mark a mirror
-- blocked, so they also overwrite each other: only the last writer's map survived, which is why
-- bot-blocked mirrors kept coming back after 1.0.47 supposedly remembered them.
--
-- Two halves are tested here, because the fix only works as a pair:
--   * the child writes nothing shared (Config.disableSubprocessWrites), and
--   * anything worth keeping travels back in the result for the parent to write -- a renewed
--     session (ApiHelper.fetchWithAuth -> _adoptRenewedSession) and a blocked mirror
--     (Api.isBlockedError -> discovery's on_item_end).

local USAGE = "usage: luajit subprocess_writes_harness.lua <plugin-root> <luasocket-src> <koreader-root>"
local PLUGIN = assert(arg[1], USAGE)
local LUASOCKET = assert(arg[2], USAGE)

package.path = PLUGIN .. "/?.lua;" .. package.path
local support = dofile(PLUGIN .. "/test/support.lua")
support.preload_socket(LUASOCKET)
support.preload_koreader_stubs()
local r = support.reporter()

package.preload["util"] = function()
    return {
        trim = function(s) return s:match("^%s*(.-)%s*$") end,
        urlEncode = function(s) return s end,
    }
end

-- A LuaSettings double that counts flushes: the flush is exactly what the guard removes.
local function make_settings(data)
    local s = { data = data or {}, flushes = 0 }
    function s:readSetting(key, default)
        local v = self.data[key]
        if v == nil then return default end
        return v
    end
    function s:saveSetting(key, value) self.data[key] = value return self end
    function s:delSetting(key) self.data[key] = nil return self end
    function s:flush() self.flushes = self.flushes + 1 return self end
    return s
end

local plugin_settings = make_settings()
package.preload["datastorage"] = function()
    return { getSettingsDir = function() return "/nonexistent-test-dir" end }
end
package.preload["luasettings"] = function()
    return { open = function(_, path)
        if string.find(path, "zlibrary%.lua$") then return plugin_settings end
        return make_settings()
    end }
end
-- The runtime cache, with its writes counted the same way.
local runtime_writes = 0
package.preload["zlibrary.cache"] = function()
    return { new = function()
        local store = {}
        return {
            get = function(_, k) return store[k] end,
            insert = function(_, k, v) store[k] = v; runtime_writes = runtime_writes + 1 return true end,
            remove = function(_, k) store[k] = nil; runtime_writes = runtime_writes + 1 return true end,
            clear = function() store = {} return true end,
        }
    end }
end
G_reader_settings = make_settings({ home_dir = "/home" })

local Config = require("zlibrary.config")

-- ---------------------------------------------------------------- before the guard
Config.saveSetting("zlibrary_username", "reader@example.com")
r.check("a normal write reaches the settings file", plugin_settings.flushes > 0,
        "nothing was flushed, so this harness cannot show the guard doing anything")

-- ---------------------------------------------------------------- in a child
Config.disableSubprocessWrites()
local flushes_at_fork = plugin_settings.flushes
local cache_writes_at_fork = runtime_writes

Config.saveSetting("zlibrary_username", "someone-else@example.com")
Config.saveUserSession("999", "childkey")
Config.markMirrorBlocked("https://blocked.example/eapi/info/ok")
Config.deleteSetting("zlibrary_password")

r.check("a child's settings writes never reach the file",
        plugin_settings.flushes == flushes_at_fork,
        string.format("%d flush(es) got through", plugin_settings.flushes - flushes_at_fork))
r.check("a child's runtime-cache writes are dropped too",
        runtime_writes == cache_writes_at_fork,
        string.format("%d cache write(s) got through", runtime_writes - cache_writes_at_fork))
-- The in-memory effect is deliberately kept: code in the child may read back what it just set,
-- and a half-applied write is harder to reason about than one that simply is not persisted.
r.check("but the child still reads back what it set",
        Config.getSetting("zlibrary_username") == "someone-else@example.com",
        "got " .. tostring(Config.getSetting("zlibrary_username")))

-- ---------------------------------------------------------------- a session found in a child
-- fetchWithAuth is driven for real: it is the only thing that mints a session in a child, and the
-- point of the fix is that it hands the session back rather than saving it where nothing can see.
local saved_sessions = {}
local calls = {}
local function build_fetchWithAuth(opts)
    local env = {
        type = type, tostring = tostring, ipairs = ipairs, string = string,
        Config = {
            getUserSession = function() return { user_id = "1", user_key = "stale" } end,
            getSetting = function(key)
                if key == "USER" then return opts.email end
                return opts.password
            end,
            SETTINGS_USERNAME_KEY = "USER",
            SETTINGS_PASSWORD_KEY = "PASS",
            saveUserSession = function(id, key)
                saved_sessions[#saved_sessions + 1] = { id, key }
            end,
        },
        Api = {
            isAuthenticationError = function(err) return err == "Please login" end,
            login = function() return opts.login_result end,
        },
    }
    local block = support.extract_block(PLUGIN .. "/zlibrary/preloader.lua",
        "(\nfunction ApiHelper%.fetchWithAuth%(.-\nend\n)")
    env.ApiHelper = {}
    local chunk = assert(loadstring(block, "=fetchWithAuth"))
    setfenv(chunk, env)
    chunk()
    return env.ApiHelper.fetchWithAuth
end

local function api_method(user_id, user_key)
    calls[#calls + 1] = { user_id, user_key }
    if user_key == "stale" then return { error = "Please login" } end
    return { books = { "a book" } }
end

saved_sessions, calls = {}, {}
local fetchWithAuth = build_fetchWithAuth{
    email = "reader@example.com", password = "hunter2",
    login_result = { user_id = "42", user_key = "fresh" },
}
local res = fetchWithAuth(api_method)
r.check("a stale session is retried with the one the re-login minted",
        #calls == 2 and calls[2][2] == "fresh", "calls: " .. #calls)
r.check("the child does not save the session itself", #saved_sessions == 0,
        #saved_sessions .. " save(s) attempted where nothing can see them")
r.check("it travels back with the result instead",
        type(res) == "table" and type(res.renewed_session) == "table"
            and res.renewed_session.user_id == "42" and res.renewed_session.user_key == "fresh",
        "renewed_session = " .. tostring(res and res.renewed_session))
r.check("and the result the caller wanted is still the result",
        type(res.books) == "table" and res.books[1] == "a book", "the payload was lost")

-- A sign-in that fails changes nothing: no session to hand back, and the original error stands.
saved_sessions, calls = {}, {}
fetchWithAuth = build_fetchWithAuth{
    email = "reader@example.com", password = "hunter2",
    login_result = { error = "Incorrect email or password" },
}
res = fetchWithAuth(api_method)
r.check("a failed re-login hands back no session and keeps the original error",
        res.error == "Please login" and res.renewed_session == nil,
        "error=" .. tostring(res.error) .. " session=" .. tostring(res.renewed_session))

-- ---------------------------------------------------------------- the parent adopts it
local adopt_env = {
    type = type,
    logger = { info = function() end },
    Config = { saveUserSession = function(id, key) saved_sessions[#saved_sessions + 1] = { id, key } end },
}
local adopt = support.extract_function(PLUGIN .. "/zlibrary/preloader.lua", "_adoptRenewedSession", adopt_env)

saved_sessions = {}
local adopted = adopt({ books = {}, renewed_session = { user_id = "42", user_key = "fresh" } })
r.check("the parent saves a session a task brought home",
        #saved_sessions == 1 and saved_sessions[1][1] == "42" and saved_sessions[1][2] == "fresh",
        #saved_sessions .. " save(s)")
r.check("and strips it from the result it passes on", adopted.renewed_session == nil,
        "the marker was left on the result")

saved_sessions = {}
adopt({ books = {} })
adopt({ renewed_session = { user_id = "42" } }) -- half a session is no session
adopt(nil)
r.check("a result with no usable session saves nothing", #saved_sessions == 0,
        #saved_sessions .. " save(s) from results that carried none")

-- ---------------------------------------------------------------- a blocked mirror found in a child
-- Extracted rather than required: api.lua pulls in the socket stack, and the classifier is the
-- whole of what matters here. BLOCKED_TEXT is a sentinel in this env, so a match proves the
-- function compares against the exported value and not an English literal -- which is what keeps
-- it working in the other fifteen locales.
local api_env = { string = string, tostring = tostring,
                  Api = { BLOCKED_TEXT = "<<blocked-text>>" } }
local blocked_block = support.extract_block(PLUGIN .. "/zlibrary/api.lua",
    "(\nfunction Api%.isBlockedError%(.-\nend\n)")
local blocked_chunk = assert(loadstring(blocked_block, "=isBlockedError"))
setfenv(blocked_chunk, api_env)
blocked_chunk()
local Api = api_env.Api
r.check("a bot-check error is recognised wherever it lands",
        Api.isBlockedError(Api.BLOCKED_TEXT .. " (mirror.example). Try a different Z-library server.")
            == true, "the blocked-mirror error was not classified")
r.check("and an ordinary failure is not mistaken for one",
        Api.isBlockedError("Request timed out - please check your connection and try again") == false
            and Api.isBlockedError(nil) == false,
        "something unrelated was classified as a block")

local function read(path) local fh = assert(io.open(path)); local s = fh:read("*a"); fh:close(); return s end
r.check("discovery marks the mirror in the parent, where the write survives",
        read(PLUGIN .. "/zlibrary/discovery.lua"):find("Config.markMirrorBlocked(seed.url)", 1, true) ~= nil,
        "discovery no longer marks blocked mirrors from its own callback")
r.check("every fork site disables shared writes first",
        select(2, read(PLUGIN .. "/zlibrary/async_helper.lua"):gsub("disableSubprocessWrites", "")) == 2
            and read(PLUGIN .. "/zlibrary/download.lua"):find("disableSubprocessWrites", 1, true) ~= nil,
        "a fork site runs without the guard")

r.finish()
