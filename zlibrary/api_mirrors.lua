-- Checking a mirror answers, and fetching the current list of mirror domains. Part of the Api
-- facade; see api_core.lua.

local Config = require("zlibrary.config")
local logger = require("logger")
local json = require("json")
local Api = require("zlibrary.api_core")

function Api.healthCheck(baseUrl, skip_redir_cache, redir_url)
    local is_redir_callback = (type(redir_url) == "string")
    local url = (is_redir_callback and redir_url or baseUrl) .. "/eapi/info/ok"

    local http_result = Api.makeHttpRequest{
        url = url,
        method = "GET",
        headers = {
            ["User-Agent"] = Config.getUserAgent(),
        },
        timeout = {5, 10},
        skipRedirectCache = skip_redir_cache or false,
        onRedirect = (not is_redir_callback) and function()
            return function(redir_res)
                local next_base_url = redir_res and redir_res.real_url_base or nil
                return Api.healthCheck(baseUrl, skip_redir_cache, next_base_url)
            end
        end,
    }

    if is_redir_callback then return http_result end
    if http_result.error then
        logger.dbg("Api.healthCheck - Failed for " .. baseUrl .. ": " .. tostring(http_result.error))
        return { success = false, error = http_result.error, elapsed = http_result.elapsed}
    end

    if not http_result.status_code or http_result.status_code < 200 or http_result.status_code >= 300 then
        logger.dbg("Api.healthCheck - Invalid status code " .. tostring(http_result.status_code) .. " for " .. baseUrl)
        return { success = false, elapsed = http_result.elapsed, error = "Invalid status code: " .. tostring(http_result.status_code) }
    end

    if not http_result.body or http_result.body == "" then
        logger.dbg("Api.healthCheck - No response body from " .. baseUrl)
        return { success = false, error = "No response body", elapsed = http_result.elapsed}
    end

    local success_parse, data = pcall(json.decode, http_result.body, json.decode.simple)
    if not success_parse or not data then
        logger.dbg("Api.healthCheck - Failed to parse JSON from " .. baseUrl)
        return { success = false, error = "Invalid JSON response", elapsed = http_result.elapsed}
    end

    if data.success == 1 then
        logger.info("Api.healthCheck - Success for " .. baseUrl .. " (status: " .. tostring(http_result.status_code) .. ")")
        return { success = true, url = baseUrl, elapsed = http_result.elapsed }
    end

    logger.dbg("Api.healthCheck - Invalid response data from " .. baseUrl .. ", success=" .. tostring(data.success))
    return { success = false, error = "Invalid API response", elapsed = http_result.elapsed}
end

-- Which CDN fetchDynamicDomains tries next. Picking at random needed a reseed per call, and the
-- reseed was os.time(): retries within the same second -- Discovery.refreshDomainsCache fires up
-- to three back-to-back, and fast failures like NXDOMAIN answer in milliseconds -- re-picked the
-- CDN that had just failed, so the rest of the list was never tried. Rotating guarantees every
-- attempt, retry included, gets a CDN the previous one did not.
local next_cdn_index = 1

function Api.fetchDynamicDomains()
     -- Data reference: https://z-lib.gd/eapi/info/domains
    local cdn_urls = {
        "https://fastly.jsdelivr.net/gh/ZlibraryKO/zlibrary.koplugin@main/assets/domains.json",
        "https://cdn.jsdelivr.net/gh/ZlibraryKO/zlibrary.koplugin@main/assets/domains.json",
        "https://raw.githubusercontent.com/ZlibraryKO/zlibrary.koplugin/main/assets/domains.json",
        "https://gh.xxooo.cf/https://raw.githubusercontent.com/ZlibraryKO/zlibrary.koplugin/main/assets/domains.json"
    }

    -- Last resort, appended so the CDNs are always tried first. They serve the curated
    -- assets/domains.json, which carries hosts the endpoint has never returned and stays
    -- reachable when Z-Library itself is not -- the common failure this plugin sees. The
    -- endpoint covers the opposite case: GitHub blocked, or the committed file trailing
    -- the operator's list. It needs a working mirror to answer, which is exactly what
    -- discovery is still looking for, so it cannot lead.
    local dynamic_domains_url = Config.getDynamicDomainsUrl()
    if dynamic_domains_url then
        table.insert(cdn_urls, dynamic_domains_url)
    end

    -- The list is one shorter on a call where no base URL is resolvable, so an index left
    -- pointing at the endpoint entry by the previous call would index past the end and hand
    -- makeHttpRequest a nil url. Wrap first, then rotate.
    if next_cdn_index > #cdn_urls then next_cdn_index = 1 end
    local url = cdn_urls[next_cdn_index]
    next_cdn_index = next_cdn_index % #cdn_urls + 1

    logger.info(string.format("Api.fetchDynamicDomains - START - URL: %s", url))

    local http_result = Api.makeHttpRequest{
        url = url,
        method = "GET",
        headers = {
            ["User-Agent"] = Config.getUserAgent(),
            ["Accept"] = "application/json"
        },
        timeout = {5, 10},
        redirect = true,
    }

    if http_result.error then
        logger.warn("Api.fetchDynamicDomains - HTTP request error: ",  tostring(http_result.error))
        return { success = false, error = http_result.error }
    end

    if not http_result.body or http_result.body == "" then
        logger.warn("Api.fetchDynamicDomains - No response body")
        return { success = false }
    end

    local success, data = pcall(json.decode, http_result.body, json.decode.simple)
    if not success or type(data) ~= "table" then
        logger.warn("Api.fetchDynamicDomains - Failed to decode JSON: ", http_result.body)
        return { success = false }
    end

    logger.info("Api.fetchDynamicDomains - END (Success)")
    return { success = true, domains = data }
end

return Api
