-- The base URL is the prefix of every request the plugin makes, and four small defects lived
-- around it:
--
--  * getBaseUrl's default branch returned the seed verbatim, trailing slash and all, so until a
--    setting or a redirect cache existed every builder emitted "https://z-lib.fo//eapi/...".
--  * setAndValidateBaseUrl's idea of validation was string.find(url, "%."), which waved through
--    paths, queries and user:password@ credentials and saved them as the base URL.
--  * saveSetting trimmed every string, silently altering a password with leading or trailing
--    whitespace typed into zlibrary_credentials.lua.
--  * the legacy-settings migration only ran when a legacy base URL existed (orphaning every
--    other legacy key for users who never had one) and never flushed G_reader_settings, so the
--    deletions replayed on every launch.
--
-- Unlike most harnesses here this one requires the real zlibrary.config module: the behaviour
-- under test is the interaction of these functions with the settings object, and an extracted
-- copy would only assert against itself.

local PLUGIN = assert(arg[1], "usage: luajit base_url_harness.lua <plugin-root> <luasocket-src>")
local LUASOCKET = assert(arg[2], "usage: luajit base_url_harness.lua <plugin-root> <luasocket-src>")

package.path = PLUGIN .. "/?.lua;" .. package.path
local support = dofile(PLUGIN .. "/test/support.lua")
support.preload_socket(LUASOCKET)
support.preload_koreader_stubs()
local r = support.reporter()

-- support's util.trim stub is the identity function, but the trim IS the behaviour under test.
package.preload["util"] = function()
    return {
        trim = function(s) return s:match("^%s*(.-)%s*$") end,
        urlEncode = function(s) return s end,
    }
end

-- A LuaSettings double backed by a plain table; flush is counted, not written.
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
        return make_settings() -- the credentials file: empty
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

-- Read by config.lua at load time for the download-dir fallback; returning a home dir keeps the
-- filemanagerutil require on the unused side of the `or`.
G_reader_settings = make_settings({ home_dir = "/home" })

local Config = require("zlibrary.config")

-- ---------------------------------------------------------------- legacy migration
-- This has to run first: the migration lives inside _getLuaSettings, which caches on first use,
-- and every later section touches settings. No legacy base URL on purpose -- that absence was
-- exactly what gated the old migration off.
G_reader_settings.data["zlibrary_search_languages"] = { "english" }
G_reader_settings.data["zlib_user_id"] = "42"
G_reader_settings.data["unrelated_key"] = "keep me"

local migrated_langs = Config.getSetting(Config.SETTINGS_SEARCH_LANGUAGES_KEY)
r.check("migration runs without a legacy base URL",
        type(migrated_langs) == "table" and migrated_langs[1] == "english",
        "languages came through as " .. tostring(migrated_langs))
r.check("non-base-url legacy keys are migrated too",
        plugin_settings.data["zlib_user_id"] == "42",
        "zlib_user_id = " .. tostring(plugin_settings.data["zlib_user_id"]))
r.check("legacy keys are deleted from the global settings",
        G_reader_settings.data["zlibrary_search_languages"] == nil
            and G_reader_settings.data["zlib_user_id"] == nil,
        "legacy keys survived")
r.check("unrelated global keys are left alone",
        G_reader_settings.data["unrelated_key"] == "keep me",
        "unrelated_key = " .. tostring(G_reader_settings.data["unrelated_key"]))
r.check("G_reader_settings is flushed so the deletions persist",
        G_reader_settings.flushes > 0,
        "never flushed -- the migration would replay on the next launch")

-- ---------------------------------------------------------------- default base URL
-- No setting and no redirect cache at this point, so this is the SEED_URLS[1] fallback.
r.check("default base URL has no trailing slash",
        Config.getBaseUrl() == "https://z-lib.fo",
        "got " .. tostring(Config.getBaseUrl()))
r.check("login URL is built without a double slash",
        Config.getLoginUrl() == "https://z-lib.fo/eapi/user/login",
        "got " .. tostring(Config.getLoginUrl()))

-- ---------------------------------------------------------------- setAndValidateBaseUrl
-- Every shape that was accepted before must still be accepted, with the same saved value.
local accepts = {
    { "z-lib.io",             "https://z-lib.io",  "bare host gets the scheme added" },
    { "https://z-lib.fo",     "https://z-lib.fo",  "full URL kept" },
    { "https://z-lib.fo/",    "https://z-lib.fo",  "trailing slash stripped" },
    { "http://z-lib.fm",      "http://z-lib.fm",   "http scheme kept" },
    { "  z-lib.gd  ",         "https://z-lib.gd",  "surrounding whitespace trimmed" },
    { "https://z-lib.fo:8443", "https://z-lib.fo:8443", "explicit port kept" },
}
for _, c in ipairs(accepts) do
    local input, want, label = c[1], c[2], c[3]
    local ok, err = Config.setAndValidateBaseUrl(input)
    r.check("accepts " .. label,
            ok and Config.getBaseUrl() == want,
            string.format("ok=%s saved=%s err=%s", tostring(ok),
                          tostring(Config.getBaseUrl()), tostring(err)))
end

-- What the old string.find("%.") check let through and the parse must refuse. The saved base
-- URL must stay at the last accepted value ("https://z-lib.fo:8443") after each refusal.
local rejects = {
    { "https://z-lib.fo/eapi",      "a path" },
    { "https://z-lib.fo?x=1",       "a query" },
    { "https://z-lib.fo/#frag",     "a fragment" },
    { "https://user:pass@z-lib.fo", "credentials in the URL" },
    { "z-l ib.fo",                  "a space in the host" },
    { "z-lib",                      "a host without a dot" },
}
for _, c in ipairs(rejects) do
    local input, label = c[1], c[2]
    local ok = Config.setAndValidateBaseUrl(input)
    r.check("rejects " .. label,
            not ok and Config.getBaseUrl() == "https://z-lib.fo:8443",
            string.format("ok=%s saved=%s", tostring(ok), tostring(Config.getBaseUrl())))
end

-- ---------------------------------------------------------------- saveSetting trimming
Config.saveSetting(Config.SETTINGS_USERNAME_KEY, "  user@example.com ")
r.check("ordinary string settings are trimmed",
        plugin_settings.data[Config.SETTINGS_USERNAME_KEY] == "user@example.com",
        "saved as " .. string.format("%q", tostring(plugin_settings.data[Config.SETTINGS_USERNAME_KEY])))
Config.saveSetting(Config.SETTINGS_PASSWORD_KEY, "  secret  ")
r.check("the password keeps its whitespace",
        plugin_settings.data[Config.SETTINGS_PASSWORD_KEY] == "  secret  ",
        "saved as " .. string.format("%q", tostring(plugin_settings.data[Config.SETTINGS_PASSWORD_KEY])))

-- ---------------------------------------------------------------- the small cleanups
r.check("getSearchUrl still builds the search endpoint",
        Config.getSearchUrl() == "https://z-lib.fo:8443/eapi/book/search",
        "got " .. tostring(Config.getSearchUrl()))
r.check("downloaded-books URL defaults to order=date",
        string.find(Config.getDownloadedBooksUrl(), "&order=date", 1, true) ~= nil,
        "got " .. tostring(Config.getDownloadedBooksUrl()))

r.finish()
