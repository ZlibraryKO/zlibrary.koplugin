-- The settings store every other part of Config reads and writes, and the caches it hands out.
--
-- zlibrary.config used to be one 1,347-line module. It is now a facade (config.lua) over this core
-- and five parts -- config_catalog, config_mirrors, config_urls, config_account, config_prefs --
-- which all fill the one Config table created here. Each part requires this module, never the
-- facade, so there is no cycle; callers keep requiring zlibrary.config. The code was moved, not
-- rewritten: diff with --color-moved against the commit before the split to see where it came from.

local util = require("util")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local Cache = require("zlibrary.cache")

local Config = {
    _lua_settings = nil,
    _runtime_cache = nil,
    _multi_search_cache = nil,
}

Config.SETTINGS_BASE_URL_KEY = "zlibrary_base_url"
Config.SETTINGS_USERNAME_KEY = "zlibrary_username"
Config.SETTINGS_PASSWORD_KEY = "zlibrary_password"
Config.SETTINGS_USER_ID_KEY = "zlib_user_id"
Config.SETTINGS_USER_KEY_KEY = "zlib_user_key"
Config.SETTINGS_SEARCH_LANGUAGES_KEY = "zlibrary_search_languages"
Config.SETTINGS_SEARCH_EXTENSIONS_KEY = "zlibrary_search_extensions"
Config.SETTINGS_SEARCH_ORDERS_KEY = "zlibrary_search_order"
Config.SETTINGS_SEARCH_HISTORY_KEY = "zlibrary_search_history"
Config.SETTINGS_VIEW_SETTINGS_KEY = "zlibrary_view_settings"
Config.SETTINGS_DOWNLOAD_DIR_KEY = "zlibrary_download_dir"
Config.SETTINGS_CATEGORIES_KEY = "zlibrary_categories"
Config.SETTINGS_TURN_OFF_WIFI_AFTER_DOWNLOAD_KEY = "zlibrary_turn_off_wifi_after_download"
Config.SETTINGS_SKIP_OPEN_BOOK_PROMPT_KEY = "zlibrary_skip_open_book_prompt"
Config.SETTINGS_BROWSER_USER_AGENT_KEY = "zlibrary_browser_user_agent"
Config.SETTINGS_TIMEOUT_LOGIN_KEY = "zlibrary_timeout_login"
Config.SETTINGS_TIMEOUT_SEARCH_KEY = "zlibrary_timeout_search"
Config.SETTINGS_TIMEOUT_BOOK_DETAILS_KEY = "zlibrary_timeout_book_details"
Config.SETTINGS_TIMEOUT_RECOMMENDED_KEY = "zlibrary_timeout_recommended"
Config.SETTINGS_TIMEOUT_POPULAR_KEY = "zlibrary_timeout_popular"
Config.SETTINGS_TIMEOUT_DOWNLOAD_KEY = "zlibrary_timeout_download"
Config.SETTINGS_TIMEOUT_COVER_KEY = "zlibrary_timeout_cover"
Config.SETTINGS_TIMEOUT_BOOK_COMMENTS_KEY = "zlibrary_timeout_book_comments"
Config.SETTINGS_BLOCKED_MIRRORS_KEY = "zlibrary_blocked_mirrors"
Config.CREDENTIALS_FILENAME = "zlibrary_credentials.lua"

-- How long a mirror that answered a request with a bot-check page stays skipped by discovery.
-- Deliberately long: a mirror put behind a WAF tends to stay there, and re-selecting it sooner just
-- reproduces the failed request the user already saw. The cost of over-skipping a mirror that has
-- since recovered is small -- there are dozens of other seeds plus the dynamic domain list, and
-- getSeedUrls falls back to the blocked ones if every candidate is blocked -- so err towards a long
-- block rather than a short one. Not permanent, so a recovered mirror is eventually retried.
Config.BLOCKED_MIRROR_TTL = 180 * 24 * 3600 -- ~6 months

Config.DEFAULT_DOWNLOAD_DIR_FALLBACK = G_reader_settings:readSetting("home_dir")
             or require("apps/filemanager/filemanagerutil").getDefaultDir()

Config.SEARCH_RESULTS_LIMIT = 30
Config.BOOKLIST_PAGE_SIZE = 20

local function _getLuaSettings()
    if not Config._lua_settings then
        local settings_file = DataStorage:getSettingsDir() .. "/zlibrary.lua"
        Config._lua_settings = LuaSettings:open(settings_file)

        -- Migrate legacy settings that predate the plugin's own zlibrary.lua and were kept in
        -- KOReader's global settings. Any leftover legacy key triggers this, not just the base
        -- URL: a user who never had one set would otherwise keep every other zlib_*/zlibrary_*
        -- key orphaned in the global file. G_reader_settings is flushed afterwards so the
        -- deletions survive the session and the migration does not replay on every launch.
        if not Config._lua_settings:readSetting(Config.SETTINGS_BASE_URL_KEY) and G_reader_settings and G_reader_settings.data then
            local migrated = false
            for key, value in pairs(G_reader_settings.data) do
                if type(key) == "string" and (key:match("^zlib_") or key:match("^zlibrary_")) then
                    Config._lua_settings:saveSetting(key, value)
                    G_reader_settings:delSetting(key)
                    migrated = true
                end
            end
            if migrated then
                Config._lua_settings:flush()
                G_reader_settings:flush()
            end
        end
    end
    return Config._lua_settings
end
-- Shared with config_mirrors, whose getSeedUrls reads the user's seedUrls through it.
Config._getLuaSettings = _getLuaSettings

-- Singleton lazy instance to avoid recreating Cache on every call
function Config.getConfigRuntimeCache()
    if not Config._runtime_cache then
        Config._runtime_cache = Cache:new{ name = "_runtime_cache" }
    end
    return Config._runtime_cache
end

-- Shared instance of the "multi_search" cache. Each KVCache holds its own in-memory copy of the
-- file and flushes the whole thing on every insert/remove, so a second instance for the same
-- name is not a shortcut to the same data -- it is a stale copy whose next flush resurrects
-- whatever another writer just removed (clearPersonalCaches hitting a long-deleted dialog's
-- instance was exactly that). Everyone touching this cache goes through here.
function Config.getMultiSearchCache()
    if not Config._multi_search_cache then
        Config._multi_search_cache = Cache:new{ name = "multi_search" }
    end
    return Config._multi_search_cache
end

-- A forked child inherits a copy of the parent's in-memory settings but SHARES the file behind them.
-- Anything it writes is invisible to the parent, is clobbered by the parent's next flush, and can
-- destroy it outright: KVCache:remove purges the file when its last key goes, and LuaSettings:flush
-- renames the file aside before rewriting it, which is not atomic across processes. Children run to
-- os.exit, so their writes are worthless anyway. Neuter the writes and keep the reads: `get` still
-- resolves through the metatable, so the child can still read the base URL it inherited.
function Config.disableRuntimeCacheWrites()
    local cache = Config.getConfigRuntimeCache()
    cache.insert = function() return false end
    cache.remove = function() return false end
    cache.clear = function() return true end
end

-- Everything a forked child must not write. Called first thing in every child this plugin forks.
--
-- A child gets a copy-on-write snapshot of the parent's memory and shares its files, so anything
-- it flushes to the settings file is written from that snapshot -- reverting whatever the parent
-- has saved since the fork -- while the parent, holding its own copy in memory, never sees what
-- the child wrote. Children racing each other do the same to one another: discovery probes three
-- mirrors at once, and each of those probes can mark a mirror blocked.
--
-- The in-memory effect of a write is kept, because code in the child may read back what it just
-- set; only the flush goes. Anything a child genuinely needs to persist has to come back in its
-- result and be written by the parent -- see ApiHelper.fetchWithAuth for a session, and
-- discovery's on_item_end for a blocked mirror.
--
-- Per-book cache files are deliberately left writable: a child writing <hash>_info.lua or a cover
-- is how the preloader warms those caches, and each of those files belongs to one book.
function Config.disableSubprocessWrites()
    Config.disableRuntimeCacheWrites()
    local settings = _getLuaSettings()
    settings.flush = function(s) return s end
end

function Config.getSetting(key, default)
    -- fix default = true and value = false
    return _getLuaSettings():readSetting(key, default)
end

function Config.saveSetting(key, value)
    -- The password is exempt from the trim: leading or trailing whitespace can be a real part
    -- of it, and zlibrary_credentials.lua is written by hand, so its values must be stored
    -- verbatim. The UI input sites already trim deliberately before calling this.
    if type(value) == "string" and key ~= Config.SETTINGS_PASSWORD_KEY then
        _getLuaSettings():saveSetting(key, util.trim(value)):flush()
    else
        _getLuaSettings():saveSetting(key, value):flush()
    end
end

function Config.deleteSetting(key)
    _getLuaSettings():delSetting(key):flush()
end

return Config
