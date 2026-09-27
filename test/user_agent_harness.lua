-- What the plugin calls itself when it talks to a mirror.
--
-- It sent a Chrome 96 string -- a browser released in November 2021 -- to every endpoint, and had
-- since #94. Probing the public domains endpoint across four mirrors with that string, a current
-- Chrome, an honest agent and no User-Agent at all returned the same status and the same bytes
-- every time; the mirrors that refuse do it with a 307 loop back to themselves, and they advertise
-- "Vary: Origin", not "Vary: User-Agent". So the claim bought nothing, and a five-year-stale
-- browser claim from a client that sends no Accept-Language, no Sec-CH-UA and a LuaSocket TLS
-- handshake is the louder signal of the two if anything ever does start looking.
--
-- The default is now honest and the browser string is a setting, because the day a mirror starts
-- refusing unfamiliar clients that switch is the difference between a setting and a release. Both
-- halves are tested: that the default says what this is, and that the escape hatch still works.
--
-- Requires the real zlibrary.config: what is under test is how these read the settings object.

local PLUGIN = assert(arg[1], "usage: luajit user_agent_harness.lua <plugin-root> <luasocket-src>")
local LUASOCKET = assert(arg[2], "usage: luajit user_agent_harness.lua <plugin-root> <luasocket-src>")

package.path = PLUGIN .. "/?.lua;" .. package.path
local support = dofile(PLUGIN .. "/test/support.lua")
support.preload_socket(LUASOCKET)
support.preload_koreader_stubs()
local r = support.reporter()

local function make_settings(data)
    local s = { data = data or {} }
    function s:readSetting(key, default)
        local v = self.data[key]
        if v == nil then return default end
        return v
    end
    function s:saveSetting(key, value) self.data[key] = value return self end
    function s:delSetting(key) self.data[key] = nil return self end
    function s:flush() return self end
    return s
end

package.preload["datastorage"] = function()
    return { getSettingsDir = function() return "/nonexistent-test-dir" end }
end
package.preload["luasettings"] = function()
    return { open = function() return make_settings() end }
end
package.preload["zlibrary.cache"] = function()
    return { new = function()
        local store = {}
        return {
            get = function(_, k) return store[k] end,
            insert = function(_, k, v) store[k] = v return true end,
            remove = function(_, k) store[k] = nil return true end,
            clear = function() store = {} return true end,
        }
    end }
end
G_reader_settings = make_settings({ home_dir = "/home" })

local Config = require("zlibrary.config")

-- ---------------------------------------------------------------- the default
Config.setPluginVersion("1.0.51")
local ua = Config.getUserAgent()

r.check("the default agent names the plugin and its version",
        ua:find("zlibrary.koplugin/1.0.51", 1, true) ~= nil, ua)
r.check("and does not claim to be a browser",
        ua:find("Mozilla", 1, true) == nil and ua:find("Chrome", 1, true) == nil, ua)
r.check("and points at somewhere an operator can reach the project",
        ua:find("github.com/ZlibraryKO/zlibrary.koplugin", 1, true) ~= nil, ua)
-- A header holding a newline or a control character is a request-splitting bug waiting for a
-- version string that comes from somewhere less trustworthy than _meta.lua.
r.check("and is a single clean header line",
        ua:match("^[\32-\126]+$") ~= nil, ua)

-- ---------------------------------------------------------------- an unknown version
-- Ota returns nil when _meta.lua cannot be read. The agent has to stay well-formed through that:
-- a nil interpolated into the string would raise, and an empty one would ship "zlibrary.koplugin/".
Config.setPluginVersion(nil)
r.check("an unreadable version does not break the agent",
        Config.getUserAgent() == "zlibrary.koplugin/unknown (KOReader; +https://github.com/ZlibraryKO/zlibrary.koplugin)",
        Config.getUserAgent())
Config.setPluginVersion("")
r.check("and neither does an empty one",
        Config.getUserAgent():find("zlibrary.koplugin/unknown", 1, true) ~= nil,
        Config.getUserAgent())
Config.setPluginVersion("1.0.51")

-- ---------------------------------------------------------------- the escape hatch
r.check("the browser string is off by default",
        Config.getUseBrowserUserAgent() == false, tostring(Config.getUseBrowserUserAgent()))

Config.setUseBrowserUserAgent(true)
r.check("switching it on sends a browser agent",
        Config.getUserAgent() == Config.BROWSER_USER_AGENT, Config.getUserAgent())
r.check("and that agent is a browser one, not a relabelled plugin string",
        Config.BROWSER_USER_AGENT:find("Mozilla/5.0", 1, true) == 1
            and Config.BROWSER_USER_AGENT:find("Chrome/", 1, true) ~= nil,
        Config.BROWSER_USER_AGENT)

Config.setUseBrowserUserAgent(false)
r.check("switching it off restores the plugin's own agent",
        Config.getUserAgent():find("zlibrary.koplugin/", 1, true) == 1, Config.getUserAgent())

-- ---------------------------------------------------------------- no caller left behind
-- Every request builds its headers from getUserAgent now. A Config.USER_AGENT left anywhere would
-- read as nil and send no header at all -- silently, since a missing header raises nothing.
local function slurp(p) local fh = assert(io.open(p)); local s = fh:read("*a"); fh:close(); return s end
local stale = {}
for _, mod in ipairs({ "api", "config", "download", "ota", "discovery", "preloader", "ui" }) do
    if slurp(PLUGIN .. "/zlibrary/" .. mod .. ".lua"):find("Config%.USER_AGENT") then
        stale[#stale + 1] = mod
    end
end
r.check("nothing still reads the removed Config.USER_AGENT", #stale == 0,
        "stale in: " .. table.concat(stale, ", "))

r.finish()
