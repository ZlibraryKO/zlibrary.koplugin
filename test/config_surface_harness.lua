-- Does zlibrary.config still expose exactly what it did before it was split into parts?
--
-- config.lua was one 1,347-line module. It is now a facade over config_core, config_catalog,
-- config_mirrors, config_urls, config_account and config_prefs, which all fill the one Config
-- table. Nine modules call Config.<name> and none of them changed, so the split is only safe if
-- every name they could reach is still there, with the same kind of value. A function that was
-- left behind, or moved into two parts (the second silently replaces the first), shows up here
-- rather than as a nil call on someone's e-reader.
--
-- The list below was recorded from the real, unsplit config.lua on 2026-11-10 (139 fields, 97 of
-- them functions). Loads the real module with the same stubs as base_url_harness.

local PLUGIN = assert(arg[1], "usage: luajit config_surface_harness.lua <plugin-root> <luasocket-src>")
local LUASOCKET = assert(arg[2], "usage: luajit config_surface_harness.lua <plugin-root> <luasocket-src>")

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

local EXPECTED = {
    "BLOCKED_MIRROR_TTL:number",
    "BOOKLIST_PAGE_SIZE:number",
    "BROWSER_USER_AGENT:string",
    "CREDENTIALS_FILENAME:string",
    "DEFAULT_DOWNLOAD_DIR_FALLBACK:string",
    "SEARCH_RESULTS_LIMIT:number",
    "SEED_URLS:table",
    "SETTINGS_BASE_URL_KEY:string",
    "SETTINGS_BLOCKED_MIRRORS_KEY:string",
    "SETTINGS_BROWSER_USER_AGENT_KEY:string",
    "SETTINGS_CATEGORIES_KEY:string",
    "SETTINGS_DOWNLOAD_DIR_KEY:string",
    "SETTINGS_PASSWORD_KEY:string",
    "SETTINGS_SEARCH_EXTENSIONS_KEY:string",
    "SETTINGS_SEARCH_HISTORY_KEY:string",
    "SETTINGS_SEARCH_LANGUAGES_KEY:string",
    "SETTINGS_SEARCH_ORDERS_KEY:string",
    "SETTINGS_SKIP_OPEN_BOOK_PROMPT_KEY:string",
    "SETTINGS_TIMEOUT_BOOK_COMMENTS_KEY:string",
    "SETTINGS_TIMEOUT_BOOK_DETAILS_KEY:string",
    "SETTINGS_TIMEOUT_COVER_KEY:string",
    "SETTINGS_TIMEOUT_DOWNLOAD_KEY:string",
    "SETTINGS_TIMEOUT_LOGIN_KEY:string",
    "SETTINGS_TIMEOUT_POPULAR_KEY:string",
    "SETTINGS_TIMEOUT_RECOMMENDED_KEY:string",
    "SETTINGS_TIMEOUT_SEARCH_KEY:string",
    "SETTINGS_TURN_OFF_WIFI_AFTER_DOWNLOAD_KEY:string",
    "SETTINGS_USERNAME_KEY:string",
    "SETTINGS_USER_ID_KEY:string",
    "SETTINGS_USER_KEY_KEY:string",
    "SETTINGS_VIEW_SETTINGS_KEY:string",
    "SUPPORTED_EXTENSIONS:table",
    "SUPPORTED_LANGUAGES:table",
    "SUPPORTED_ORDERS:table",
    "TIMEOUT_BOOK_COMMENTS:table",
    "TIMEOUT_BOOK_DETAILS:table",
    "TIMEOUT_COVER:table",
    "TIMEOUT_DOWNLOAD:table",
    "TIMEOUT_LOGIN:table",
    "TIMEOUT_POPULAR:table",
    "TIMEOUT_RECOMMENDED:table",
    "TIMEOUT_SEARCH:table",
    "addCategory:function",
    "addSearchHistory:function",
    "addSubcategory:function",
    "clearCacheRealUrl:function",
    "clearCacheRealUrlIfPinned:function",
    "clearCredentials:function",
    "clearPersonalCaches:function",
    "clearSearchHistory:function",
    "clearUserSession:function",
    "credentialsComeFromFile:function",
    "deleteSetting:function",
    "disableRuntimeCacheWrites:function",
    "disableSubprocessWrites:function",
    "formatSeconds:function",
    "formatTimeoutForDisplay:function",
    "getBaseUrl:function",
    "getBookCommentsTimeout:function",
    "getBookCommentsUrl:function",
    "getBookDetailsTimeout:function",
    "getBookDetailsUrl:function",
    "getBookUrl:function",
    "getBooklistBooksUrl:function",
    "getBooklistsUrl:function",
    "getCacheRealUrl:function",
    "getCategories:function",
    "getConfigRuntimeCache:function",
    "getCoverTimeout:function",
    "getCredentials:function",
    "getDeleteDownloadedUrl:function",
    "getDownloadDir:function",
    "getDownloadLinkUrl:function",
    "getDownloadQuotaUrl:function",
    "getDownloadTimeout:function",
    "getDownloadUrl:function",
    "getDownloadedBooksUrl:function",
    "getDynamicDomainsUrl:function",
    "getFavoriteBookIdsUrl:function",
    "getFavoriteBooksUrl:function",
    "getFavoriteUrl:function",
    "getLoginTimeout:function",
    "getMostPopularBooksUrl:function",
    "getMostPopularCacheKey:function",
    "getMultiSearchCache:function",
    "getPopularTimeout:function",
    "getRecommendedBooksUrl:function",
    "getRecommendedTimeout:function",
    "getSearchExtensions:function",
    "getSearchHistory:function",
    "getSearchLanguages:function",
    "getSearchOrder:function",
    "getSearchOrderName:function",
    "getSearchTimeout:function",
    "getSearchUrl:function",
    "getSeedUrls:function",
    "getSetting:function",
    "getSimilarBooksUrl:function",
    "getSkipOpenBookPrompt:function",
    "getTimeoutConfig:function",
    "getTurnOffWifiAfterDownload:function",
    "getUnFavoriteUrl:function",
    "getUseBrowserUserAgent:function",
    "getUserAgent:function",
    "getUserSession:function",
    "getViewFlag:function",
    "getViewSettings:function",
    "hasCredentials:function",
    "hasUserSession:function",
    "isMirrorBlocked:function",
    "loadCredentialsFromFile:function",
    "markMirrorBlocked:function",
    "removeCategory:function",
    "removeSearchHistory:function",
    "removeSubcategory:function",
    "renameCategory:function",
    "renameSubcategory:function",
    "sanitizeCategoryName:function",
    "saveSetting:function",
    "saveUserSession:function",
    "sessionComesFromFile:function",
    "setAndValidateBaseUrl:function",
    "setBookCommentsTimeout:function",
    "setBookDetailsTimeout:function",
    "setCacheRealUrl:function",
    "setCategories:function",
    "setCoverTimeout:function",
    "setDownloadTimeout:function",
    "setLoginTimeout:function",
    "setPluginVersion:function",
    "setPopularTimeout:function",
    "setRecommendedTimeout:function",
    "setSearchTimeout:function",
    "setSkipOpenBookPrompt:function",
    "setTimeoutConfig:function",
    "setTurnOffWifiAfterDownload:function",
    "setUseBrowserUserAgent:function",
    "setViewSettings:function",
    "toggleViewFlag:function",
}

-- Added on purpose: the settings accessor config_mirrors shares with config_core (the split), and
-- the Detailed logging setting (2026-11-22, see zlibrary/log.lua).
local ALLOWED_EXTRA = {
    ["_getLuaSettings:function"] = true,
    ["SETTINGS_DETAILED_LOGGING_KEY:string"] = true,
    ["getDetailedLogging:function"] = true,
    ["setDetailedLogging:function"] = true,
}

local actual = {}
for k, v in pairs(Config) do actual[k .. ":" .. type(v)] = true end
local expected = {}
for _, entry in ipairs(EXPECTED) do expected[entry] = true end

-- Removed on purpose: "Identify as a web browser" (2026-11-22, see user_agent_harness).
local REMOVED = {
    ["BROWSER_USER_AGENT:string"] = true,
    ["SETTINGS_BROWSER_USER_AGENT_KEY:string"] = true,
    ["getUseBrowserUserAgent:function"] = true,
    ["setUseBrowserUserAgent:function"] = true,
}

local missing, extra, still_there = {}, {}, {}
for entry in pairs(expected) do
    if REMOVED[entry] then
        if actual[entry] then still_there[#still_there + 1] = entry end
    elseif not actual[entry] then
        missing[#missing + 1] = entry
    end
end
for entry in pairs(actual) do
    if not expected[entry] and not ALLOWED_EXTRA[entry] then extra[#extra + 1] = entry end
end
table.sort(missing)
table.sort(extra)

local removed_count = 0
for _ in pairs(REMOVED) do removed_count = removed_count + 1 end
table.sort(still_there)
r.check("the fields removed on purpose are gone", #still_there == 0,
        "still there: " .. table.concat(still_there, ", "))
r.check(string.format("all %d other recorded Config fields are still there, with the same type",
                      #EXPECTED - removed_count),
        #missing == 0, "missing: " .. table.concat(missing, ", "))
r.check("and nothing unexpected was added",
        #extra == 0, "extra: " .. table.concat(extra, ", "))

r.finish()
