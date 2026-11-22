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
-- The agent is honest now. The browser string survived for a while as "Identify as a web browser",
-- in case a mirror started to care; none did, and the setting was removed on 2026-11-22. A reader
-- who had it on still has the stored value, so that is checked too: it must change nothing.
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
    -- The removed setting, stored on, as a reader who had switched it on still has it.
    return { open = function() return make_settings({ zlibrary_browser_user_agent = true }) end }
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

-- ---------------------------------------------------------------- the removed setting
-- The settings file above has "Identify as a web browser" stored on. Every check so far ran with
-- it there, so this only names that and makes sure nothing of the setting is left to call.
r.check("a stored browser setting from an older version is ignored",
        Config.getUserAgent():find("zlibrary.koplugin/", 1, true) == 1, Config.getUserAgent())
r.check("and nothing of the setting is left on Config",
        Config.getUseBrowserUserAgent == nil and Config.setUseBrowserUserAgent == nil
            and Config.BROWSER_USER_AGENT == nil and Config.SETTINGS_BROWSER_USER_AGENT_KEY == nil)

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
