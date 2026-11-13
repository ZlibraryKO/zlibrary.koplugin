-- What the reader can choose: the user agent, timeouts, download folder and categories, search
-- languages/formats/order, and view settings. Part of the Config facade; see config_core.lua.

local util = require("util")
local T = require("zlibrary.gettext")
local Config = require("zlibrary.config_core")

-- What the plugin calls itself.
--
-- It used to always send the browser string below, and that string had claimed to be Chrome 96 --
-- released November 2021 -- ever since #94. It was never worth much: probing the public domains
-- endpoint across four mirrors with this string, a current Chrome, an honest one and no
-- User-Agent at all returns the same status and the same bytes every time, and the mirrors that
-- refuse do it with a 307 loop back to themselves, which is a cookie challenge rather than
-- anything read off this header. The servers say so themselves -- they answer "Vary: Origin", not
-- "Vary: User-Agent".
--
-- A stale browser claim is also the worse lie of the two if that ever changes: nothing else about
-- the connection is Chrome -- no Accept-Language, no Sec-CH-UA, no Sec-Fetch-*, and a LuaSocket
-- TLS handshake -- so the mismatch is a louder signal than saying plainly what this is.
--
-- The browser string stays as something the reader can switch back on, because the day a mirror
-- does start refusing unfamiliar clients, that switch is the difference between a setting and a
-- release.
Config.BROWSER_USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/96.0.4664.110 Safari/537.36"

-- Set once at startup from the version Ota reads out of _meta.lua, because config cannot ask Ota
-- itself: ota requires config, and reading _meta.lua a second way here is how the two come to
-- disagree. nil until then, and the agent says so rather than inventing a number.
local plugin_version = nil

function Config.setPluginVersion(version)
    plugin_version = type(version) == "string" and version ~= "" and version or nil
end

function Config.getUserAgent()
    if Config.getUseBrowserUserAgent() then
        return Config.BROWSER_USER_AGENT
    end
    return string.format("zlibrary.koplugin/%s (KOReader; +https://github.com/ZlibraryKO/zlibrary.koplugin)",
        plugin_version or "unknown")
end

-- Timeout configuration for different operations: { block_timeout, total_timeout }.
-- block_timeout limits a single socket read; total_timeout limits the whole transfer, but only once
-- data is flowing -- socketutil enforces it through a sink that starts ticking on the first received
-- chunk. Before any byte arrives (a connect stall, or a server slow to first byte) only block_timeout
-- applies, so a stalled request fails at min(block, total). Keep block <= total (or total = -1 for
-- "no total limit") so the block value is the one that governs a stall; a block larger than total is
-- capped by total and never takes effect.
Config.TIMEOUT_LOGIN = { 10, 15 }        -- Login operations
-- Keep the block timeouts generous. They are the deadline for a request that has produced no data
-- at all, and that is also what decides whether retry_on_stall (api.lua) fires -- so a tight value
-- does double damage on a poor connection: it cuts off requests that were merely slow to arrive,
-- and then mistakes them for a stalled server and retries, doubling the wait and the load.
--
-- The measurements these were checked against came from a fibre connection, where transfer time was
-- 1-4ms and the whole wait was the server thinking, so they say nothing about someone whose network
-- adds handshake round-trips of its own. Fifteen seconds without a single byte is genuinely stuck
-- almost anywhere; ten is not. Users who want to fail faster can lower these in the settings.
Config.TIMEOUT_SEARCH = { 15, 15 }       -- Search operations
Config.TIMEOUT_BOOK_DETAILS = { 15, 15 } -- Book details operations
Config.TIMEOUT_RECOMMENDED = { 15, 30 }  -- Recommended books operations
Config.TIMEOUT_POPULAR = { 15, 30 }      -- Popular books operations
Config.TIMEOUT_DOWNLOAD = { 15, -1 }    -- Book download operations (infinite total timeout if data flows)
Config.TIMEOUT_COVER = { 5, 15 }        -- Cover image operations
Config.TIMEOUT_BOOK_COMMENTS = { 10, 15 } -- Comments operations

function Config.getDownloadDir()
    return Config.getSetting(Config.SETTINGS_DOWNLOAD_DIR_KEY, Config.DEFAULT_DOWNLOAD_DIR_FALLBACK)
end

function Config.getSearchLanguages()
    return Config.getSetting(Config.SETTINGS_SEARCH_LANGUAGES_KEY, {})
end

-- The multi-search cache key for the most-popular list. That list is narrowed to the search
-- languages and formats, so each selection gets its own entry: changing either must not serve
-- the list cached under the old one. No selection keeps the plain "popular" key.
function Config.getMostPopularCacheKey()
    local function sorted_part(values)
        if type(values) ~= "table" or #values == 0 then return nil end
        local sorted = {}
        for i, value in ipairs(values) do sorted[i] = tostring(value) end
        table.sort(sorted)
        return table.concat(sorted, "_")
    end
    local languages = sorted_part(Config.getSearchLanguages())
    local extensions = sorted_part(Config.getSearchExtensions())
    if not languages and not extensions then return "popular" end
    -- Labelled parts, so a language and a format with the same name can never collide.
    return "popular_l:" .. (languages or "") .. "_f:" .. (extensions or "")
end

function Config.getSearchExtensions()
    return Config.getSetting(Config.SETTINGS_SEARCH_EXTENSIONS_KEY, {})
end

function Config.getSearchOrder()
    return Config.getSetting(Config.SETTINGS_SEARCH_ORDERS_KEY, {})
end

function Config.getSearchOrderName()
    local search_order_name = T("Default")
    local selected_order = Config.getSearchOrder()
    local search_order = selected_order and selected_order[1]

    if search_order then
        for _, v in ipairs(Config.SUPPORTED_ORDERS) do
            if v.value == search_order then
                search_order_name = v.name
                break
            end
        end
    end
    return search_order_name
end

-- Off by default: the plugin says what it is. On, it sends BROWSER_USER_AGENT instead -- the
-- escape hatch for a mirror that turns out to care, which no mirror measurably does today.
function Config.getUseBrowserUserAgent()
    return Config.getSetting(Config.SETTINGS_BROWSER_USER_AGENT_KEY, false)
end

function Config.setUseBrowserUserAgent(use_browser)
    Config.saveSetting(Config.SETTINGS_BROWSER_USER_AGENT_KEY, use_browser)
end

function Config.getTurnOffWifiAfterDownload()
    return Config.getSetting(Config.SETTINGS_TURN_OFF_WIFI_AFTER_DOWNLOAD_KEY, false)
end

function Config.setTurnOffWifiAfterDownload(turn_off)
    Config.saveSetting(Config.SETTINGS_TURN_OFF_WIFI_AFTER_DOWNLOAD_KEY, turn_off)
end

-- Off by default: the prompt is the only confirmation most people get that a download finished,
-- so quietening it has to be asked for.
function Config.getSkipOpenBookPrompt()
    return Config.getSetting(Config.SETTINGS_SKIP_OPEN_BOOK_PROMPT_KEY, false)
end

function Config.setSkipOpenBookPrompt(skip)
    Config.saveSetting(Config.SETTINGS_SKIP_OPEN_BOOK_PROMPT_KEY, skip)
end

-- Timeout configuration functions
function Config.getTimeoutConfig(timeout_key, default_timeout)
    local saved_timeout = Config.getSetting(timeout_key)
    if saved_timeout and type(saved_timeout) == "table" and #saved_timeout == 2 then
        return saved_timeout
    end
    return default_timeout
end

function Config.setTimeoutConfig(timeout_key, block_timeout, total_timeout)
    Config.saveSetting(timeout_key, {block_timeout, total_timeout})
end

function Config.getLoginTimeout()
    return Config.getTimeoutConfig(Config.SETTINGS_TIMEOUT_LOGIN_KEY, Config.TIMEOUT_LOGIN)
end

function Config.getSearchTimeout()
    return Config.getTimeoutConfig(Config.SETTINGS_TIMEOUT_SEARCH_KEY, Config.TIMEOUT_SEARCH)
end

function Config.getBookDetailsTimeout()
    return Config.getTimeoutConfig(Config.SETTINGS_TIMEOUT_BOOK_DETAILS_KEY, Config.TIMEOUT_BOOK_DETAILS)
end

function Config.getRecommendedTimeout()
    return Config.getTimeoutConfig(Config.SETTINGS_TIMEOUT_RECOMMENDED_KEY, Config.TIMEOUT_RECOMMENDED)
end

function Config.getPopularTimeout()
    return Config.getTimeoutConfig(Config.SETTINGS_TIMEOUT_POPULAR_KEY, Config.TIMEOUT_POPULAR)
end

function Config.getDownloadTimeout()
    return Config.getTimeoutConfig(Config.SETTINGS_TIMEOUT_DOWNLOAD_KEY, Config.TIMEOUT_DOWNLOAD)
end

function Config.getCoverTimeout()
    return Config.getTimeoutConfig(Config.SETTINGS_TIMEOUT_COVER_KEY, Config.TIMEOUT_COVER)
end

function Config.getBookCommentsTimeout()
    return Config.getTimeoutConfig(Config.SETTINGS_TIMEOUT_BOOK_COMMENTS_KEY, Config.TIMEOUT_BOOK_COMMENTS)
end

-- Seconds in the compact form the menus and dialogs use.
--
-- The unit has to live inside the translated string. It is not "s" everywhere -- Korean writes
-- 15초, Japanese 15秒 -- and appending it in Lua also hard-codes a space that CJK does not want
-- and that some languages put elsewhere. Same reason the retry templates stopped concatenating.
function Config.formatSeconds(seconds)
    return string.format(T("%ds"), seconds)
end

function Config.formatTimeoutForDisplay(timeout_pair)
    local block_timeout = timeout_pair[1]
    local total_timeout = timeout_pair[2]
    
    local total_display = total_timeout == -1 and T("infinite") or Config.formatSeconds(total_timeout)
    return string.format(T("Block: %ds, Total: %s"), block_timeout, total_display)
end

function Config.setLoginTimeout(block_timeout, total_timeout)
    Config.setTimeoutConfig(Config.SETTINGS_TIMEOUT_LOGIN_KEY, block_timeout, total_timeout)
end

function Config.setSearchTimeout(block_timeout, total_timeout)
    Config.setTimeoutConfig(Config.SETTINGS_TIMEOUT_SEARCH_KEY, block_timeout, total_timeout)
end

function Config.setBookDetailsTimeout(block_timeout, total_timeout)
    Config.setTimeoutConfig(Config.SETTINGS_TIMEOUT_BOOK_DETAILS_KEY, block_timeout, total_timeout)
end

function Config.setRecommendedTimeout(block_timeout, total_timeout)
    Config.setTimeoutConfig(Config.SETTINGS_TIMEOUT_RECOMMENDED_KEY, block_timeout, total_timeout)
end

function Config.setPopularTimeout(block_timeout, total_timeout)
    Config.setTimeoutConfig(Config.SETTINGS_TIMEOUT_POPULAR_KEY, block_timeout, total_timeout)
end

function Config.setDownloadTimeout(block_timeout, total_timeout)
    Config.setTimeoutConfig(Config.SETTINGS_TIMEOUT_DOWNLOAD_KEY, block_timeout, total_timeout)
end

function Config.setCoverTimeout(block_timeout, total_timeout)
    Config.setTimeoutConfig(Config.SETTINGS_TIMEOUT_COVER_KEY, block_timeout, total_timeout)
end

function Config.setBookCommentsTimeout(block_timeout, total_timeout)
    Config.setTimeoutConfig(Config.SETTINGS_TIMEOUT_BOOK_COMMENTS_KEY, block_timeout, total_timeout)
end

-- View settings (items per page, cover toggles) are a device preference, so they live in the
-- persistent settings file. They used to be kept in the runtime cache, where they expired with
-- the cache's default TTL five days after they were last saved and silently reverted to
-- defaults -- and where "Clear runtime cache" wiped them outright.
function Config.setViewSettings(opts)
    if type(opts) ~= "table" then opts = {} end
    Config.saveSetting(Config.SETTINGS_VIEW_SETTINGS_KEY, opts)
    -- Drop the legacy cache entry so the settings file stays the only source of truth.
    Config.getConfigRuntimeCache():remove("view_settings")
    return true
end

function Config.getViewSettings()
    local opts = Config.getSetting(Config.SETTINGS_VIEW_SETTINGS_KEY)
    if type(opts) == "table" then
        return opts
    end
    -- One-time migration of a pre-settings-file entry. No expiry on the read: an entry older
    -- than the cache's default TTL is still the user's last choice, not stale data.
    local legacy = Config.getConfigRuntimeCache():get("view_settings", 0)
    if type(legacy) == "table" then
        Config.saveSetting(Config.SETTINGS_VIEW_SETTINGS_KEY, legacy)
        Config.getConfigRuntimeCache():remove("view_settings")
        return legacy
    end
    return {}
end

-- An on/off view setting that is on until the user turns it off (the cover toggles). Unset means
-- on, so a fresh install shows covers without writing anything, and every reader of these keys
-- tests `~= false` for the same reason.
function Config.getViewFlag(key)
    return Config.getViewSettings()[key] ~= false
end

-- Flip such a flag and return the new state. It flips what is in effect, not what is stored: the
-- menu used to store `not opts[key]`, and from the unset default that is `not nil` -- true, still
-- on -- so the first tap did nothing and only the second turned covers off. Always stores an
-- explicit boolean, so the state never depends on the default again.
function Config.toggleViewFlag(key)
    local opts = Config.getViewSettings()
    local on = opts[key] == false -- off becomes on; on, or unset, becomes off
    opts[key] = on
    Config.setViewSettings(opts)
    return on
end

-- Download categories. A category is only a name; its folder is <download dir>/<name>, and a
-- sub-category nests one level deeper (<download dir>/<parent>/<child>). The name doubles as the
-- folder segment, so it is sanitised with the same rule the download filename uses
-- (download.lua) and an empty result is rejected. Nesting is capped at one level: children are
-- plain name strings and never have children of their own.
--
-- Stored shape (persisted verbatim, like the view settings above):
--   { { name = "Fiction", children = { "Romance", "Sci-Fi" } }, { name = "Comics", children = {} } }
--
-- The mutation helpers return true on success, or false plus a short machine reason
-- ("empty" / "exists" / "not_found" / "no_parent") the UI turns into a message.
function Config.sanitizeCategoryName(name)
    if type(name) ~= "string" then return "" end
    return (util.trim(name):gsub("[/\\?%*:|\"<>%c]", "_"))
end

local function findCategoryIndex(list, name)
    for i, entry in ipairs(list) do
        if type(entry) == "table" and entry.name == name then return i end
    end
    return nil
end

function Config.setCategories(list)
    if type(list) ~= "table" then list = {} end
    Config.saveSetting(Config.SETTINGS_CATEGORIES_KEY, list)
    return true
end

function Config.getCategories()
    local list = Config.getSetting(Config.SETTINGS_CATEGORIES_KEY)
    if type(list) == "table" then return list end
    return {}
end

function Config.addCategory(name)
    local clean = Config.sanitizeCategoryName(name)
    if clean == "" then return false, "empty" end
    local list = Config.getCategories()
    if findCategoryIndex(list, clean) then return false, "exists" end
    table.insert(list, { name = clean, children = {} })
    Config.setCategories(list)
    return true
end

function Config.addSubcategory(parent, name)
    local clean = Config.sanitizeCategoryName(name)
    if clean == "" then return false, "empty" end
    local list = Config.getCategories()
    local idx = findCategoryIndex(list, parent)
    if not idx then return false, "no_parent" end
    local children = list[idx].children or {}
    for _, child in ipairs(children) do
        if child == clean then return false, "exists" end
    end
    table.insert(children, clean)
    list[idx].children = children
    Config.setCategories(list)
    return true
end

function Config.renameCategory(old_name, new_name)
    local clean = Config.sanitizeCategoryName(new_name)
    if clean == "" then return false, "empty" end
    local list = Config.getCategories()
    local idx = findCategoryIndex(list, old_name)
    if not idx then return false, "not_found" end
    if clean ~= old_name and findCategoryIndex(list, clean) then return false, "exists" end
    list[idx].name = clean
    Config.setCategories(list)
    return true
end

function Config.renameSubcategory(parent, old_name, new_name)
    local clean = Config.sanitizeCategoryName(new_name)
    if clean == "" then return false, "empty" end
    local list = Config.getCategories()
    local idx = findCategoryIndex(list, parent)
    if not idx then return false, "no_parent" end
    local children = list[idx].children or {}
    local child_idx, clash
    for i, child in ipairs(children) do
        if child == old_name then child_idx = i end
        if child == clean then clash = true end
    end
    if not child_idx then return false, "not_found" end
    if clean ~= old_name and clash then return false, "exists" end
    children[child_idx] = clean
    Config.setCategories(list)
    return true
end

function Config.removeCategory(name)
    local list = Config.getCategories()
    local idx = findCategoryIndex(list, name)
    if not idx then return false, "not_found" end
    table.remove(list, idx)
    Config.setCategories(list)
    return true
end

function Config.removeSubcategory(parent, name)
    local list = Config.getCategories()
    local idx = findCategoryIndex(list, parent)
    if not idx then return false, "no_parent" end
    local children = list[idx].children or {}
    for i, child in ipairs(children) do
        if child == name then
            table.remove(children, i)
            Config.setCategories(list)
            return true
        end
    end
    return false, "not_found"
end

return Config
