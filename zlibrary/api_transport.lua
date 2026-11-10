-- Every HTTP request the plugin makes goes through Api.makeHttpRequest: timeouts, the one-time stall
-- retry, following redirects (with the mirror-move pin, per-request cookies and the loop guard),
-- and recognising a bot-check page. Part of the Api facade; see api_core.lua.

local Config = require("zlibrary.config")
local time = require("ui/time") 
local logger = require("logger")
local ltn12 = require("ltn12")
local http = require("socket.http")
local socketutil = require("socketutil")
local socket_url = require("socket.url")
local T = require("zlibrary.gettext")
local Api = require("zlibrary.api_core")
local Shared = require("zlibrary.api_shared")
local _extractErrorFromJsonBody = Shared._extractErrorFromJsonBody

-- Reads the mirror's new address out of a 30x that the caller has already received. The headers
-- come from that very response: makeHttpRequest only asks for this check when options.redirect was
-- falsy, and that is the same flag it hands LuaSocket, so nothing was followed and the Location is
-- still there for the taking. This used to re-fetch the URL with a HEAD instead, which could not
-- work: the probe set redirect = true, so LuaSocket followed the chain itself and handed back the
-- final 200, and a final response carries no Location. Every redirect therefore ended in "empty
-- Location header" and no mirror move was ever followed.
local function _checkAndHandleRedirect(skip_check, status_code, current_url, headers)

    local result = { has_redirect = nil, real_url = nil, status_code = nil, error = nil }
    local redirect_codes = { [301] = true, [302] = true, [303] = true, [307] = true, [308] = true }
    if skip_check or type(current_url) ~= "string" or current_url == "" or
        type(status_code) ~= "number" or not redirect_codes[status_code]  then
            return result
    end

    local current_url_parse = socket_url.parse(current_url)

    result.has_redirect = true
    result.status_code = status_code

    -- LuaSocket lower-cases the header names it parses; Location is a belt-and-braces fallback.
    local location = type(headers) == "table" and (headers.location or headers.Location) or nil
    if type(location) ~= "string" or location == "" then
        logger.err("Zlibrary:Api - Redirect carried no Location header:", headers)
        result.error = string.format("Redirect from %s carried no Location header", current_url)
        return result
    end

    -- Location is allowed to be relative (RFC 9110 10.2.2), and mirrors send every shape of it:
    -- "/eapi/...", "login/", "//host/path". This used to require an absolute cross-host URL and
    -- refuse everything else, so an ordinary in-site redirect surfaced to the user as a raw
    -- "HTTP Error: 307". Resolve against the request URL instead, so there is always something
    -- absolute to re-issue.
    local real_url = socket_url.absolute(current_url, location)
    local real_url_parse = real_url and socket_url.parse(real_url) or nil
    if not (real_url_parse and real_url_parse.host and real_url_parse.scheme) then
        result.error = string.format("Redirect target could not be resolved against %s: %s",
            current_url, location)
        return result
    end
    result.real_url = real_url

    -- real_url_base is the mirror-move signal, and is deliberately set only for a cross-host hop:
    -- that is the only case with a new base URL worth pinning, and the only case where onRedirect
    -- has anything to rebuild. A same-host hop is an ordinary redirect and is simply followed.
    if real_url_parse.host ~= current_url_parse.host then
        logger.dbg(string.format("Zlibrary:Api - %s redirects to another host: %s -> %s",
            tostring(status_code), tostring(current_url_parse.host), real_url_parse.host))
        result.real_url_base = socket_url.build({
                scheme = real_url_parse.scheme,
                host = real_url_parse.host,
                -- A mirror move to a non-default port is pinned without it otherwise, and the
                -- cached base then points at a port nothing is listening on.
                port = real_url_parse.port
        })
    end
    return result
end

-- How many hops a chain may take before giving up. Mirrors that point at each other would
-- otherwise recurse until the stack goes; five is what browsers and curl settle on.
local MAX_REDIRECT_HOPS = 5

-- A mirror behind a bot-detection service answers an API call with an HTML "verifying your
-- browser" interstitial instead of JSON. That is not an outage and retrying cannot clear it: the
-- page wants a browser to run its JavaScript, which a KOReader plugin has no way to do, and
-- working around a check the operator deliberately put up is not the job either. Recognise it,
-- say so plainly, and let the caller offer auto-discovery -- a different mirror is the only thing
-- that helps. Observed on 1lib.sk, which answers 513 with a DiamWall challenge page.
local CHALLENGE_MARKERS = {
    "Verifying your browser",
    "DiamWall",
    "/cdn-cgi/mitigation/",
    "__cf_chl",
    "Just a moment",
    "Checking your browser",
}

local function _looksLikeBotChallenge(body)
    if type(body) ~= "string" or body == "" then
        return false
    end
    -- Only ever an HTML page where JSON was expected; bound the scan so a large body cannot
    -- turn every failed request into a full-text search.
    local head = string.sub(body, 1, 4096)
    if not string.find(head, "<", 1, true) then
        return false
    end
    for _, marker in ipairs(CHALLENGE_MARKERS) do
        if string.find(head, marker, 1, true) then
            return true
        end
    end
    return false
end

-- Attribute names that appear in a Set-Cookie beside the pair that matters. LuaSocket folds
-- repeated headers into a single comma-separated string, and an Expires date carries a comma of
-- its own, so splitting the header correctly is guesswork. Scan every name=value in it instead
-- and discard the ones that are attributes -- nothing else in a Set-Cookie looks like a pair.
local COOKIE_ATTRIBUTES = {
    expires = true, ["max-age"] = true, domain = true, path = true, secure = true,
    httponly = true, samesite = true, partitioned = true, priority = true,
    version = true, comment = true,
}

-- Cookies set by a 30x, carried to the hop that follows it and scoped to the host that issued
-- them.
--
-- Some mirrors sit behind a WAF that answers with 307 plus Set-Cookie and expects the cookie
-- returned; DiamWall in front of 1lib.sk does exactly that. Without this the retry is identical
-- to the request that was just challenged, so the mirror challenges it again and the chain
-- repeats until the loop guard ends it -- which is the sign-in failure users reported.
--
-- Deliberately per-request rather than a session-wide jar: the cookie never touches disk, never
-- outlives the request that earned it, and only ever goes back to the host that set it. A later
-- request that gets challenged answers its own challenge the same way. Returns true when
-- something new was learned, which is what lets the loop guard allow one more attempt at a URL.
local function _rememberCookies(options, from_url, headers)
    local raw = type(headers) == "table" and (headers["set-cookie"] or headers["Set-Cookie"]) or nil
    if type(raw) ~= "string" or raw == "" then
        return false
    end
    local parsed = socket_url.parse(from_url or "")
    local host = parsed and parsed.host
    if not host then
        return false
    end

    options._cookies = options._cookies or {}
    local jar = options._cookies[host] or {}
    options._cookies[host] = jar

    local learned = false
    for name, value in string.gmatch(raw, "([^%s;,=]+)%s*=%s*([^;,]*)") do
        if not COOKIE_ATTRIBUTES[string.lower(name)] and jar[name] ~= value then
            jar[name] = value
            learned = true
        end
    end
    return learned
end

-- Rebuild the Cookie header from the caller's own value plus whatever this chain has picked up
-- for the host being addressed. The caller's value is captured once and rebuilt from every time,
-- so following several hops cannot append the same cookie twice.
local function _applyCookies(options)
    local jar = options._cookies
    if not jar then
        return
    end
    local parsed = socket_url.parse(options.url or "")
    local cookies = parsed and parsed.host and jar[parsed.host]
    if not cookies or not next(cookies) then
        return
    end

    if options._cookie_header_base == nil then
        options._cookie_header_base =
            (type(options.headers) == "table" and options.headers["Cookie"]) or false
    end

    local parts = {}
    if type(options._cookie_header_base) == "string" and options._cookie_header_base ~= "" then
        table.insert(parts, options._cookie_header_base)
    end
    for name, value in pairs(cookies) do
        table.insert(parts, name .. "=" .. value)
    end

    local headers = {}
    if type(options.headers) == "table" then
        for k, v in pairs(options.headers) do
            headers[k] = v
        end
    end
    headers["Cookie"] = table.concat(parts, "; ")
    options.headers = headers
end

-- 307 and 308 exist precisely to preserve the method and body. 303 mandates a GET, and 301/302
-- are turned into one by every real client -- which is the whole reason these requests are issued
-- with redirect=false and handled here. Dropping the body also means dropping the headers that
-- describe it, or the next request advertises a Content-Length it will not send.
local function _applyRedirectMethod(options, status_code)
    if status_code == 307 or status_code == 308 then
        return
    end
    if string.upper(options.method or "GET") == "GET" then
        return
    end
    options.method = "GET"
    options.body = nil
    options.source = nil
    if type(options.headers) == "table" then
        local kept = {}
        for k, v in pairs(options.headers) do
            local lk = string.lower(k)
            if lk ~= "content-length" and lk ~= "content-type" then
                kept[k] = v
            end
        end
        options.headers = kept
    end
end

function Api.makeHttpRequest(options)
    logger.dbg(string.format("Zlibrary:Api.makeHttpRequest - START - URL: %s, Method: %s", options.url, options.method or "GET"))
    
    local response_body_table = {}
    local result = { body = nil, status_code = nil, error = nil, headers = nil }

    local sink_to_use = options.sink
    if not sink_to_use then
        response_body_table = {}
        sink_to_use = socketutil.table_sink(response_body_table)
    end

    -- Time to first byte, recorded by wrapping whichever sink is in play.
    --
    -- `elapsed` alone cannot distinguish the two failures that look identical in the log but call
    -- for opposite fixes. A timeout that never saw a byte means the connection was accepted and the
    -- server then never answered -- a fresh attempt often succeeds within seconds, so failing fast
    -- and retrying is the right response. A timeout that arrives after data had started means the
    -- transfer stalled or crawled, where retrying only re-downloads what was already coming.
    --
    -- Note the block timeout resets on every chunk, so a slow but steady transfer is not what dies
    -- here: a stall is. Which of the two we are looking at is exactly what this measures.
    local start_time            -- assigned just before the request; the closure below reads it then
    local first_byte_ms = nil
    -- Counted here rather than stat'ed afterwards: this is the one place every response passes
    -- through whatever sink the caller supplied, so it works for a download writing to a file as
    -- well as for a body collected in memory, and it costs no syscall and no new dependency.
    local bytes_received = 0
    do
        local inner_sink = sink_to_use
        sink_to_use = function(chunk, err)
            if chunk and chunk ~= "" then
                if not first_byte_ms and start_time then
                    first_byte_ms = time.to_ms(time.since(start_time))
                end
                bytes_received = bytes_received + #chunk
            end
            return inner_sink(chunk, err)
        end
    end

    if options.timeout then
        if type(options.timeout) == "table" then
            socketutil:set_timeout(options.timeout[1], options.timeout[2])
            logger.dbg(string.format("Zlibrary:Api.makeHttpRequest - Setting timeout to %s/%s seconds", options.timeout[1], options.timeout[2]))
        else
            socketutil:set_timeout(options.timeout)
            logger.dbg(string.format("Zlibrary:Api.makeHttpRequest - Setting timeout to %s seconds", options.timeout))
        end
    end

    -- Build the body source per attempt. An ltn12 source is a one-shot generator, so any request
    -- this function re-issues -- a redirect hop, or the stall retry below -- would otherwise go out
    -- with an empty body while still advertising the original Content-Length. Callers hand over
    -- options.body as a plain string and the source is made fresh here each time through.
    local body_source = options.source
    if not body_source and type(options.body) == "string" then
        body_source = ltn12.source.string(options.body)
    end

    _applyCookies(options)

    local request_params = {
        url = options.url,
        method = options.method or "GET",
        headers = options.headers,
        source = body_source,
        sink = sink_to_use,
        -- zlibrary mirror redirects may break API paths; disabled by default.
        redirect = options.redirect or false,
    }

    logger.dbg(string.format("Zlibrary:Api.makeHttpRequest - Request Params: URL: %s, Method: %s, Timeout: %s", request_params.url, request_params.method, tostring(options.timeout)))
    
    start_time = time.now()
    local req_ok, r_val, r_code, r_headers_tbl, r_status_str = pcall(http.request, request_params)
    result.elapsed = time.to_ms(time.since(start_time))
    result.first_byte_ms = first_byte_ms
    result.bytes_received = bytes_received

    if options.timeout then
        socketutil:reset_timeout()
        logger.dbg("Zlibrary:Api.makeHttpRequest - Reset timeout to default")
    end

    logger.dbg(string.format("Zlibrary:Api.makeHttpRequest - pcall result: ok=%s, r_val=%s (type %s), r_code=%s (type %s), r_headers_tbl type=%s, r_status_str=%s",
        tostring(req_ok), tostring(r_val), type(r_val), tostring(r_code), type(r_code), type(r_headers_tbl), tostring(r_status_str)))

    if not req_ok then
        local error_msg = tostring(r_val)
        if string.find(error_msg, "timeout") or 
           string.find(error_msg, "wantread") or 
           string.find(error_msg, "closed") or 
           string.find(error_msg, "connection") or
           string.find(error_msg, "sink timeout") then
            result.error = T("Request timed out - please check your connection and try again")
        else
            result.error = T("Network request failed") .. ": " .. error_msg
        end
        logger.err(string.format(
            "Zlibrary:Api.makeHttpRequest - END (pcall error) - %s %s - raw=[%s] elapsed=%dms first_byte=%s - Error: %s",
            tostring(request_params.method), tostring(options.url),
            error_msg, result.elapsed or -1,
            first_byte_ms and (first_byte_ms .. "ms") or "none", result.error))
        return result
    end

    result.status_code = r_code
    result.headers = r_headers_tbl


    if not options.sink then
        result.body = table.concat(response_body_table)
    end

    -- A pinned redirect target that fails at the transport layer, or answers 5xx, is not usable.
    -- Drop it now instead of keeping every request on it until the TTL lapses. 4xx must not clear
    -- the pin: a 401 or a download limit is a healthy host answering, not a broken one. 3xx must
    -- not either, since the redirect handling below still needs the pin to rebuild the retry URL.
    if not options.skipRedirectCache and
       (type(result.status_code) ~= "number" or result.status_code >= 500) then
        if Config.clearCacheRealUrlIfPinned(options.url) then
            logger.info(string.format(
                "Zlibrary:Api.makeHttpRequest - Dropped cached redirect target; it failed: %s (status: %s)",
                tostring(options.url), tostring(result.status_code)))
        end
    end

    if type(result.status_code) ~= "number" then
        -- socket.http is socket.protect'd: on a transport failure it returns (nil, err),
        -- so r_code holds the underlying LuaSocket/LuaSec error string, not a status code.
        local status_str = tostring(result.status_code)
        result.transport_error = status_str
        local is_timeout = string.find(status_str, "wantread", 1, true) or
           string.find(status_str, "wantwrite", 1, true) or
           string.find(status_str, "timeout", 1, true) or
           string.find(status_str, "closed", 1, true)

        -- A timeout where not one byte ever arrived means the connection was accepted and the server
        -- then said nothing. Device logs show that is transient and per-connection: the same URL,
        -- retried moments later, answered in about 1.5s after stalling for 10s. So retry it once.
        --
        -- Deliberately narrow. Only when no byte arrived: if the response had started and then
        -- stalled, a retry just re-fetches what was already coming. Only once, and only when the
        -- caller opted in, so background work never retries against what is a free service. And only
        -- when we own the sink, since re-running a caller's sink would write its output twice.
        if options.retry_on_stall and not options._retried and is_timeout
                and first_byte_ms == nil and not options.sink then
            options._retried = true
            logger.info(string.format(
                "Zlibrary:Api.makeHttpRequest - stalled with no response after %dms, retrying once - %s %s",
                result.elapsed or -1, tostring(request_params.method), tostring(options.url)))
            return Api.makeHttpRequest(options)
        end

        if is_timeout then
            result.error = T("Request timed out - please check your connection and try again")
        elseif string.find(status_str, "name resolution", 1, true) or
               string.find(status_str, "host or service not provided", 1, true) then
            -- getaddrinfo failed, so the address never resolved and nothing was sent. The
            -- connection itself is usually fine, and telling the user to check it sends them
            -- after the wrong problem: the base URL is dead or misspelled. LuaSocket returns
            -- these strings as fixed C literals, so matching them is locale-safe.
            local parsed = socket_url.parse(options.url or "")
            result.error = string.format("%s (%s). %s",
                Api.DNS_ERROR_TEXT,
                (parsed and parsed.host) or tostring(options.url),
                T("The Z-library address may be wrong or no longer exist."))
        else
            result.error = T("Network connection error - please check your internet connection and try again")
        end
        logger.err(string.format(
            "Zlibrary:Api.makeHttpRequest - END (Invalid response code type) - %s %s - transport_error=[%s] (type %s) elapsed=%dms first_byte=%s - Error: %s",
            tostring(request_params.method), tostring(options.url),
            status_str, type(result.status_code), result.elapsed or -1,
            first_byte_ms and (first_byte_ms .. "ms") or "none", result.error))
        return result
    end

    -- Skip only when LuaSocket is already following the chain itself. This used to skip whenever
    -- onRedirect was absent, which meant an ordinary redirect was never followed -- and neither was
    -- any hop after the first, because the retry clears onRedirect. Both surfaced to the user as a
    -- raw "HTTP Error: 307".
    local skip_redirect_check = options.redirect and true or false
    local redir_res = _checkAndHandleRedirect(skip_redirect_check, result.status_code, options.url, result.headers)
    if redir_res.has_redirect then
        if redir_res.real_url then
            if redir_res.real_url_base and not options.skipRedirectCache then
                Config.setCacheRealUrl(options.url, redir_res.real_url_base)
            end
            -- A mirror move, and the caller offered a rebuild: only it can reconstruct the API
            -- path from config against the new base, so let it.
            if redir_res.real_url_base and type(options.onRedirect) == "function" then
                local redirect_next_step = options.onRedirect()
                if type(redirect_next_step) == "string" then
                    options.url = redirect_next_step
                    options.onRedirect = nil
                    return Api.makeHttpRequest(options)
                elseif type(redirect_next_step) == "function" then
                     return redirect_next_step(redir_res)
                end
            end
            -- Otherwise follow it here: an in-site redirect, or a mirror move on a request that
            -- has no rebuild left to call.
            --
            -- A target already requested is a loop, and no number of hops escapes it. The observed
            -- case is a WAF (DiamWall on 1lib.sk) answering 307 with a Location pointing back at the
            -- request URL: following that spends the whole hop budget and seconds of wall clock on a
            -- free service to reach a conclusion available on the first hop. Stop at the first
            -- repeat. Browsers report loops as "too many redirects" as well, so the message users
            -- see stays the one they will recognise.
            -- Take any cookie the 30x set before deciding whether this is a loop: a challenge is
            -- answered by re-requesting the very same URL, so a repeat that carries a cookie we
            -- did not have before is progress, not a loop. MAX_REDIRECT_HOPS still bounds it if a
            -- host keeps issuing fresh cookies forever.
            local learned_cookies = _rememberCookies(options, options.url, result.headers)

            local seen = options._redirect_seen
            if not seen then
                seen = { [options.url] = true }
                options._redirect_seen = seen
            end
            if seen[redir_res.real_url] and not learned_cookies then
                result.error = string.format("%s (%s)", T("Too many redirects"), tostring(redir_res.real_url))
                logger.err(string.format(
                    "Zlibrary:Api.makeHttpRequest - Redirect loop: %s was already requested, not following it again",
                    tostring(redir_res.real_url)))
                return result
            end
            seen[redir_res.real_url] = true

            local hops = (options._redirect_hops or 0) + 1
            if hops > MAX_REDIRECT_HOPS then
                result.error = string.format("%s (%s)", T("Too many redirects"), tostring(options.url))
                logger.err(string.format(
                    "Zlibrary:Api.makeHttpRequest - Redirect chain exceeded %d hops, giving up at %s",
                    MAX_REDIRECT_HOPS, tostring(options.url)))
                return result
            end
            logger.info(string.format("Zlibrary:Api.makeHttpRequest - Following %s: %s -> %s (hop %d)",
                tostring(result.status_code), tostring(options.url), tostring(redir_res.real_url), hops))
            options._redirect_hops = hops
            _applyRedirectMethod(options, result.status_code)
            options.url = redir_res.real_url
            return Api.makeHttpRequest(options)
        elseif redir_res.error then
            -- Only the reason is worth keeping: redir_res describes why the redirect was not
            -- followable, it is not a response. Overwriting result with it used to throw away the
            -- real body, headers and elapsed time and replace the status with the probe's own.
            -- Leave the response intact and let the status handling below report it.
            logger.info("Zlibrary:Api.makeHttpRequest - Not following redirect: " .. tostring(redir_res.error))
        end
    end

    if result.status_code ~= 200 and result.status_code ~= 206 then
        if not result.error then
            local json_error = _extractErrorFromJsonBody(result.body)
            if _looksLikeBotChallenge(result.body) then
                local parsed = socket_url.parse(options.url or "")
                result.error = string.format("%s (%s). %s",
                    Api.BLOCKED_TEXT,
                    (parsed and parsed.host) or tostring(options.url),
                    T("Try a different Z-library server."))
                -- Remember this mirror so discovery skips it and stops re-selecting it every sweep.
                Config.markMirrorBlocked(options.url)
                logger.err(string.format(
                    "Zlibrary:Api.makeHttpRequest - %s answered a bot-check page (status %s), not the API",
                    tostring(options.url), tostring(result.status_code)))
            elseif json_error then
                result.error = json_error
            else
                result.error = string.format("%s: %s (%s)", T("HTTP Error"), result.status_code, r_status_str or T("Unknown Status"))
            end
        end
    elseif _looksLikeBotChallenge(result.body) then
        -- A WAF can answer 200 with the interstitial instead of an error status. Recognise it
        -- here too, before the caller parses the HTML as JSON: a generic "Invalid response
        -- format" would not trigger auto-discovery, and a different mirror is the only fix.
        local parsed = socket_url.parse(options.url or "")
        result.error = string.format("%s (%s). %s",
            Api.BLOCKED_TEXT,
            (parsed and parsed.host) or tostring(options.url),
            T("Try a different Z-library server."))
        -- Remember this mirror so discovery skips it and stops re-selecting it every sweep.
        Config.markMirrorBlocked(options.url)
        logger.err(string.format(
            "Zlibrary:Api.makeHttpRequest - %s answered a bot-check page with status %s, not the API",
            tostring(options.url), tostring(result.status_code)))
    end

    logger.dbg(string.format("Zlibrary:Api.makeHttpRequest - END - Status: %s, Headers found: %s, Error: %s",
        result.status_code, tostring(result.headers ~= nil), tostring(result.error)))
    return result
end

return Api
