-- Detailed logging: the plugin's dbg lines reach crash.log on their own when the reader asks.
--
-- Routine lines are dbg (see log_level_harness), which KOReader writes only with its own debug
-- logging on, and that brings all of KOReader's debug output with it. zlibrary/log.lua is the
-- narrower switch: with Detailed logging on, the plugin's dbg goes out at info. This drives the
-- real log.lua over a recording KOReader logger: off by default, dbg at dbg; on, dbg at info;
-- info, warn and err untouched either way; and KOReader's logger looked up per call, since
-- Logger:setLevel swaps its functions in place. Then the real Config getter/setter (stored and
-- applied at once), main.lua's init applying it before its first log line, and the menu entry.

local PLUGIN = assert(arg[1], "usage: luajit log_detailed_harness.lua <plugin-root> <luasocket-src>")

package.path = PLUGIN .. "/?.lua;" .. package.path
local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local lines = {}
local function recorder(level)
    return function(...) lines[#lines + 1] = { level = level, text = table.concat({ ... }, " ") } end
end
local koreader_logger = { dbg = recorder("dbg"), info = recorder("info"),
                          warn = recorder("warn"), err = recorder("err") }
package.preload["logger"] = function() return koreader_logger end

local Log = require("zlibrary.log")
local function last() return lines[#lines] or {} end

-- ---------------------------------------------------------------- the switch
r.check("off by default", Log.isDetailed() == false)
Log.dbg("a", "b")
r.check("off: dbg goes to KOReader's dbg", last().level == "dbg" and last().text == "a b",
        tostring(last().level) .. " " .. tostring(last().text))

Log.setDetailed(true)
Log.dbg("c")
r.check("on: dbg goes to KOReader's info", last().level == "info" and last().text == "c", tostring(last().level))

for _, level in ipairs({ "info", "warn", "err" }) do
    Log.setDetailed(false); Log[level]("x")
    local off = last().level
    Log.setDetailed(true); Log[level]("y")
    r.check(level .. " is passed through unchanged, on or off", off == level and last().level == level,
            tostring(off) .. " / " .. tostring(last().level))
end

Log.setDetailed("yes")
r.check("only true turns it on", Log.isDetailed() == false, "a truthy non-boolean turned it on")

-- KOReader's setLevel replaces logger.dbg (a no-op below the level). A captured reference would
-- keep writing at the old level; the replacement must be what is called.
local swapped = false
koreader_logger.dbg = function() swapped = true end
Log.setDetailed(false)
Log.dbg("z")
r.check("KOReader's logger is looked up per call", swapped, "log.lua kept the function it saw at load")
koreader_logger.dbg = recorder("dbg")

-- ---------------------------------------------------------------- the setting
local store = {}
local Config = {
    SETTINGS_DETAILED_LOGGING_KEY = "zlibrary_detailed_logging",
    getSetting = function(k, default) if store[k] == nil then return default end return store[k] end,
    saveSetting = function(k, v) store[k] = v end,
}
local env = { Config = Config, Log = Log }
for _, pattern in ipairs({
    "(\nfunction Config%.getDetailedLogging%(.-\nend\n)",
    "(\nfunction Config%.setDetailedLogging%(.-\nend\n)",
}) do
    local chunk = assert(loadstring(support.extract_block(PLUGIN .. "/zlibrary/config_prefs.lua", pattern), "=config_prefs"))
    setfenv(chunk, env)
    chunk()
end

r.check("the setting is off on a fresh install", Config.getDetailedLogging() == false)
Config.setDetailedLogging(true)
r.check("turning it on stores it", store.zlibrary_detailed_logging == true and Config.getDetailedLogging() == true)
r.check("and applies it at once, no restart", Log.isDetailed() == true)
Config.setDetailedLogging(false)
r.check("turning it off stores and applies that too",
        store.zlibrary_detailed_logging == false and Log.isDetailed() == false)
store.zlibrary_detailed_logging = "true"
r.check("a hand-edited non-boolean reads as off", Config.getDetailedLogging() == false)

-- ---------------------------------------------------------------- startup and the menu
local init = support.extract_block(support.plugin_class_files(PLUGIN), "(\nfunction Zlibrary:init%(.-\nend\n)")
local apply = init:find("logger.setDetailed(Config.getDetailedLogging())", 1, true)
local first_log = init:find("Config.loadCredentialsFromFile", 1, true)
r.check("init applies the stored setting", apply ~= nil, "the setting is never read at startup")
r.check("before the first startup line is logged", apply and first_log and apply < first_log,
        "loadCredentialsFromFile logs before the setting is applied")

local menu = support.read_plugin_class(PLUGIN)
r.check("the menu offers Detailed logging", menu:find('T("Detailed logging")', 1, true) ~= nil)
r.check("and the entry toggles the setting",
        menu:find("Config.setDetailedLogging(not Config.getDetailedLogging())", 1, true) ~= nil)

r.finish()
