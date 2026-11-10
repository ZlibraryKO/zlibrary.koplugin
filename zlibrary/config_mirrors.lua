-- Which Z-library server the plugin talks to: the base URL, the cached redirect target a mirror
-- moved to, mirrors marked as bot-walled, and the candidate list discovery probes. Part of the
-- Config facade; see config_core.lua.

local util = require("util")
local socket_url = require("socket.url")
local Cache = require("zlibrary.cache")
local Config = require("zlibrary.config_core")

-- The settings accessor lives in config_core; see Config._getLuaSettings there.
local function _getLuaSettings() return Config._getLuaSettings() end

function Config.getCacheRealUrl()
    return Config.getConfigRuntimeCache():get("api_real_url", 600)
end

function Config.clearCacheRealUrl()
    return Config.getConfigRuntimeCache():remove("api_real_url")
end

-- scheme://host[:port] of a url, or nil when it has no parsable origin.
local function _getUrlOrigin(url)
    if type(url) ~= "string" or url == "" then
        return nil
    end
    local parsed = socket_url.parse(url)
    if not (parsed and parsed.scheme and parsed.host) then
        return nil
    end
    return socket_url.build({
        scheme = parsed.scheme,
        host = parsed.host,
        port = parsed.port,
    })
end

function Config.setCacheRealUrl(original_url, real_url)
    if not (original_url and real_url) then
        return
    end

    -- The redirected request was built by Config.getBaseUrl(), which prefers the cached real url
    -- over the configured one, so accept either origin. Matching only the configured one would
    -- reject every hop after the first (A -> B -> C never records C) and leave onRedirect
    -- retrying the stale host.
    local origin = _getUrlOrigin(original_url)
    if not origin then
        return
    end
    if origin ~= _getUrlOrigin(Config.getBaseUrl(true)) and origin ~= _getUrlOrigin(Config.getCacheRealUrl()) then
        return
    end

    if string.sub(real_url, -1) == "/" then
        real_url = string.sub(real_url, 1, -2)
    end

    return Config.getConfigRuntimeCache():insert("api_real_url", real_url)
end

-- Drop the cached redirect target when that very host is the one that just failed.
-- The cache is otherwise write-once and expire-only, so a target that goes bad keeps every
-- request pointed at it for the rest of its TTL. Only a failure from the pinned host itself
-- clears it: a failure from any other host says nothing about whether the pin is still good.
-- Returns true when a pin was dropped.
function Config.clearCacheRealUrlIfPinned(url)
    local cached_url = Config.getCacheRealUrl()
    if not cached_url then
        return false
    end

    local origin = _getUrlOrigin(url)
    if not origin or origin ~= _getUrlOrigin(cached_url) then
        return false
    end

    Config.clearCacheRealUrl()
    return true
end

function Config.getBaseUrl(is_original)
    local configured_url = (not is_original and Config.getCacheRealUrl()) or Config.getSetting(Config.SETTINGS_BASE_URL_KEY)
    if configured_url == nil or configured_url == "" then
        -- default; the seeds carry a trailing slash, and the URL builders below append
        -- "/eapi/..." verbatim, so it has to come off here like the setting (setAndValidateBaseUrl)
        -- and the redirect cache (setCacheRealUrl) already strip theirs
        configured_url = (Config.SEED_URLS and #Config.SEED_URLS > 0) and Config.SEED_URLS[1] or nil
        if configured_url then
            configured_url = configured_url:gsub("/$", "")
        end
    end
    return configured_url
end

-- Mirrors that answered a request with a bot-check page instead of the API. Discovery skips them so
-- a server that passes /eapi/info/ok but blocks /eapi/book/search (observed on tw.101d.by) is not
-- selected again on every sweep. Keyed by scheme://host[:port], so the path of the challenged
-- request does not matter and a match with a bare seed URL is stable; entries expire after
-- BLOCKED_MIRROR_TTL.
local function _normalizeMirrorKey(url)
    if type(url) ~= "string" or url == "" then return nil end
    local parsed = socket_url.parse(url)
    if parsed and parsed.host and parsed.host ~= "" then
        local key = (parsed.scheme or "https") .. "://" .. parsed.host:lower()
        if parsed.port then key = key .. ":" .. parsed.port end
        return key
    end
    -- Fall back to a crude strip so even a malformed URL yields a stable key.
    return (url:gsub("[/?#].*$", ""))
end

function Config.markMirrorBlocked(url, now)
    local key = _normalizeMirrorKey(url)
    if not key then return end
    now = now or os.time()
    local map = Config.getSetting(Config.SETTINGS_BLOCKED_MIRRORS_KEY)
    if type(map) ~= "table" then map = {} end
    -- Drop aged-out entries while we are here so the map cannot grow without bound.
    for k, ts in pairs(map) do
        if type(ts) ~= "number" or (now - ts) >= Config.BLOCKED_MIRROR_TTL then
            map[k] = nil
        end
    end
    map[key] = now
    Config.saveSetting(Config.SETTINGS_BLOCKED_MIRRORS_KEY, map)
end

function Config.isMirrorBlocked(url, now)
    local key = _normalizeMirrorKey(url)
    if not key then return false end
    local map = Config.getSetting(Config.SETTINGS_BLOCKED_MIRRORS_KEY)
    if type(map) ~= "table" then return false end
    local ts = map[key]
    if type(ts) ~= "number" then return false end
    now = now or os.time()
    return (now - ts) < Config.BLOCKED_MIRROR_TTL
end

function Config.getSeedUrls()
    local new_seed_urls, seen = {}, {}
    -- Seeds that would have been included but are currently bot-blocked. Kept only for the fallback
    -- below: if every candidate is blocked, trying them beats leaving discovery with nothing.
    local blocked_bucket = {}

    local base = Config.getBaseUrl()
    local clean_base = (type(base) == "string" and base ~= "") and base:gsub("/$", "") or nil
    if clean_base then seen[clean_base] = true end

    local function shuffle(t)
        for i = #t, 2, -1 do
            local j = math.random(i)
            t[i], t[j] = t[j], t[i]
        end
    end

    local function processAndMerge(source_urls , src_name)
        if type(source_urls) ~= "table" or #source_urls == 0 then return end
        local temp_urls, blocked_temp = {}, {}

        -- clean & deduplicate
        for _, url in ipairs(source_urls) do
            if type(url) == "string" and url ~= "" then
                local clean_url = url:gsub("/$", "")
                if not clean_url:match("^https?://") then
                    clean_url  = "https://" .. clean_url
                end
                if not seen[clean_url] then
                    seen[clean_url] = true
                    if Config.isMirrorBlocked(clean_url) then
                        table.insert(blocked_temp, {url = clean_url, src = src_name})
                    else
                        table.insert(temp_urls, {url = clean_url, src = src_name})
                    end
                end
            end
        end
        shuffle(temp_urls)
        shuffle(blocked_temp)
        for _, item in ipairs(temp_urls) do table.insert(new_seed_urls, item) end
        for _, item in ipairs(blocked_temp) do table.insert(blocked_bucket, item) end
    end

    -- User-defined  > Hardcoded > Dynamic
    local settings =  _getLuaSettings()
    processAndMerge(settings and settings:readSetting("seedUrls"), "U")
    processAndMerge(Config.SEED_URLS, "C")
    local domains_cache = Cache:new{ name = "_domains_cache" }
    -- domains are updated passively, no expiration set here
    processAndMerge(domains_cache:get("domains"), "D")

    -- Never hand discovery an empty list purely because everything is blocked right now.
    if #new_seed_urls == 0 then
        for _, item in ipairs(blocked_bucket) do table.insert(new_seed_urls, item) end
    end

    return new_seed_urls
end

function Config.setAndValidateBaseUrl(url_string)
    if not url_string or url_string == "" then
        return false, "Error: URL cannot be empty."
    end

    url_string = util.trim(url_string)

    if not (string.sub(url_string, 1, 8) == "https://" or string.sub(url_string, 1, 7) == "http://") then
        url_string = "https://" .. url_string
    end

    if string.sub(url_string, -1) == "/" then
        url_string = string.sub(url_string, 1, -2)
    end

    -- A base URL is an origin and nothing more: a scheme, and a host that looks like a domain.
    -- The bare string.find("%.") this replaces waved through "https://host/path" or credentials
    -- in the URL, and they were saved verbatim and broke every request built on them.
    if string.find(url_string, "%s") then
        return false, "Error: URL must include a valid domain name (e.g., example.com)."
    end
    local parsed = socket_url.parse(url_string)
    if not (parsed and parsed.scheme and parsed.host and string.find(parsed.host, "%."))
            or parsed.path or parsed.params or parsed.query or parsed.fragment or parsed.userinfo then
        return false, "Error: URL must include a valid domain name (e.g., example.com)."
    end

    Config.saveSetting(Config.SETTINGS_BASE_URL_KEY, url_string)
    Config.clearCacheRealUrl()
    return true, nil
end

return Config
