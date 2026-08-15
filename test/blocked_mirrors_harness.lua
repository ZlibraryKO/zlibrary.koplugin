-- A mirror can pass discovery's /eapi/info/ok health check and still answer a real /eapi/book/search
-- with a bot-check page (observed on tw.101d.by). Before this fix, discovery kept re-selecting such a
-- mirror on every sweep. Now a mirror that answers any request with a challenge is remembered, and
-- discovery skips it until the block ages out.
--
-- The seams under test:
--   * markMirrorBlocked / isMirrorBlocked round-trip, keyed by scheme://host[:port] so the path of
--     the challenged request is irrelevant, with a TTL so the block is not permanent
--   * getSeedUrls drops blocked mirrors -- which is also what stops the same bad mirror winning every
--     sweep -- but never returns an empty list purely because everything is currently blocked
--
-- Uses the real zlibrary.config (like base_url_harness): the behaviour is the interaction of these
-- functions with the settings object and the real URL parsing, which a transcription could not test.

local PLUGIN = assert(arg[1], "usage: luajit blocked_mirrors_harness.lua <plugin-root> <luasocket-src>")
local LUASOCKET = assert(arg[2], "usage: luajit blocked_mirrors_harness.lua <plugin-root> <luasocket-src>")

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

local function contains(list, url)
    for _, s in ipairs(list) do if s.url == url then return true end end
    return false
end

-- ---------------------------------------------------------------- mark / isBlocked / key / TTL
local NOW = 1000000
Config.markMirrorBlocked("https://tw.101d.by/eapi/book/search", NOW)

r.check("a challenged mirror is remembered as blocked",
        Config.isMirrorBlocked("https://tw.101d.by", NOW) == true,
        "not blocked")
r.check("the block is keyed by host, not the challenged path",
        Config.isMirrorBlocked("https://tw.101d.by/eapi/info/ok", NOW) == true,
        "a different path on the same host was not recognised")
r.check("a trailing slash does not change the key",
        Config.isMirrorBlocked("https://tw.101d.by/", NOW) == true,
        "trailing slash broke the match")
r.check("an unrelated mirror is not blocked",
        Config.isMirrorBlocked("https://z-lib.fo", NOW) == false,
        "wrongly reported blocked")

r.check("the block still holds just before the TTL",
        Config.isMirrorBlocked("https://tw.101d.by", NOW + Config.BLOCKED_MIRROR_TTL - 1) == true,
        "expired too early")
r.check("the block expires once the TTL passes",
        Config.isMirrorBlocked("https://tw.101d.by", NOW + Config.BLOCKED_MIRROR_TTL + 1) == false,
        "still blocked after the TTL -- a recovered mirror would be shunned forever")

-- ---------------------------------------------------------------- getSeedUrls drops blocked mirrors
-- getSeedUrls checks against real os.time(), so mark without an injected timestamp (a fresh block).
local seeds_before = Config.getSeedUrls()
r.check("discovery offers seeds to begin with", #seeds_before > 0, "no seeds")

local victim = seeds_before[1].url
Config.markMirrorBlocked(victim)
local seeds_after = Config.getSeedUrls()
r.check("a bot-blocked mirror is dropped from the seed list",
        not contains(seeds_after, victim), victim .. " is still offered")
r.check("exactly the blocked mirror is dropped, nothing else",
        #seeds_after == #seeds_before - 1,
        string.format("before=%d after=%d", #seeds_before, #seeds_after))

-- ---------------------------------------------------------------- never strand discovery
-- Blocking every known seed must not leave discovery with nothing to try: the block is transient,
-- so a last-resort list of the blocked ones is better than an empty sweep.
for _, u in ipairs(Config.SEED_URLS) do Config.markMirrorBlocked(u) end
local fallback = Config.getSeedUrls()
r.check("when every seed is blocked, discovery still gets a non-empty fallback list",
        #fallback > 0, "discovery was left with no seeds at all")

-- ---------------------------------------------------------------- wiring
local api_src = (function()
    local fh = assert(io.open(PLUGIN .. "/zlibrary/api.lua")); local s = fh:read("*a"); fh:close(); return s
end)()
r.check("makeHttpRequest records a mirror that answers a bot-check page",
        select(2, api_src:gsub("Config%.markMirrorBlocked%(options%.url%)", "")) == 2,
        "expected both challenge branches (status!=200 and 200-with-interstitial) to record the block")

r.finish()
