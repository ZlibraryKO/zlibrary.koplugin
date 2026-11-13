-- Signing in: the two login endpoints and the fallback between them. Part of the Api facade; see
-- api_core.lua.

local Config = require("zlibrary.config")
local util = require("util")
local logger = require("logger")
local json = require("json")
local T = require("zlibrary.gettext")
local Api = require("zlibrary.api_core")

-- The sign-in endpoints, in the order they are tried.
--
-- rpc.php is what the website and the desktop app use. /eapi/user/login is what the plugin used
-- before 1.0.48, dropped when it started answering valid credentials with "Authorization failed";
-- it serves login again now. Neither has proved to be permanently the right one -- the server has
-- switched which of them works at least twice -- and readers whose credentials work in a browser
-- keep being told their password is wrong, so a sign-in one endpoint refuses is put to the other
-- before the reader is told anything.
--
-- Data, not code. Every entry here is a string, a number or a list of them: no functions, nothing
-- that has to be compiled. That is the point of the shape. Twice this year a Z-Library sign-in
-- change has cost a release -- and a release only reaches the readers who take it -- while the
-- mirror list, which changes far more often, is fixed by committing assets/domains.json and
-- reaches everyone within the hour. This table is the next thing that should be fixable that way,
-- and it cannot be until it is expressible as JSON. Nothing fetches it yet; this is only the shape.
--
-- Placeholders in a body value are substituted and then URL-encoded, so a value may hold a URL:
--   {email}     the address as typed          {password}  the password as typed
--   {base}      the current base URL, no trailing slash
-- The fields are a list of pairs rather than a table because the order is part of the request --
-- it matches what the website sends -- and JSON objects have no order to rely on.
Api.LOGIN_ENDPOINTS = {
    {
        label = "rpc.php",
        path = "/rpc.php",
        -- rpc.php's login action, exactly as the website sends it: the extra fields (action,
        -- site_mode, gg_json_mode, isModal, redirectUrl) are what make it return the session as
        -- JSON rather than an HTML redirect, and no CSRF token or prior cookie is needed
        -- (verified against the live server).
        body = {
            { "isModal", "true" },
            { "email", "{email}" },
            { "password", "{password}" },
            { "site_mode", "books" },
            { "action", "login" },
            { "gg_json_mode", "1" },
            { "redirectUrl", "{base}/" },
        },
    },
    {
        label = "/eapi/user/login",
        path = "/eapi/user/login",
        -- The bare pair the old endpoint has always taken. It answers the same JSON envelope as
        -- the rest of /eapi ({success, user:{id, remix_userkey}}), which the reader below already
        -- understands.
        body = {
            { "email", "{email}" },
            { "password", "{password}" },
        },
    },
}

-- nil when there is no base URL to resolve against, or when the entry names no path.
local function _loginEndpointUrl(endpoint)
    local base = Config.getBaseUrl()
    if not base then return nil end
    if type(endpoint.path) ~= "string" or endpoint.path == "" then return nil end
    return base .. endpoint.path
end

-- One endpoint's body, expanded and form-encoded. nil when the entry cannot be rendered.
--
-- An unknown placeholder is a refusal, not an empty string. The failure it prevents is the quiet
-- one: a body template saying {passwd} would otherwise post an empty password, the server would
-- answer "Incorrect email or password", and the reader would be told their credentials are wrong
-- about a request that never carried them.
local function _renderLoginBody(endpoint, email, password)
    if type(endpoint.body) ~= "table" or #endpoint.body == 0 then return nil end
    local values = {
        email = email or "",
        password = password or "",
        base = Config.getBaseUrl() or "",
    }
    local parts = {}
    for _, field in ipairs(endpoint.body) do
        local name, template = field[1], field[2]
        if type(name) ~= "string" or name == "" or type(template) ~= "string" then return nil end
        local unknown = false
        -- Substituted first and encoded after: redirectUrl is "{base}/", and what has to be
        -- encoded is the finished URL, not the placeholder. Encoding the literals too is a no-op
        -- ("books", "login", "1" survive unchanged), so one rule covers every field.
        local value = template:gsub("{(%w+)}", function(key)
            if values[key] == nil then unknown = true return "" end
            return values[key]
        end)
        if unknown then return nil end
        parts[#parts + 1] = name .. "=" .. util.urlEncode(value)
    end
    return table.concat(parts, "&")
end

-- One sign-in request. Returns makeHttpRequest's raw result; a redirect that moves the mirror
-- re-enters here, and what that returns is handed back to the first caller. The URL and the body
-- are both rebuilt on the retry rather than captured, so the retry follows the move.
local function _postCredentials(endpoint, email, password, is_redirect_retry)
    local base = Config.getBaseUrl()
    -- Rendered here rather than passed in, so a redirect that moves the mirror rebuilds the body
    -- against the new base: redirectUrl is "{base}/", and a body carrying the old host would ask
    -- the new mirror to redirect back to the one we just left.
    local body = _renderLoginBody(endpoint, email, password)

    return Api.makeHttpRequest{
        url = _loginEndpointUrl(endpoint),
        method = "POST",
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8",
            ["Accept"] = "application/json, text/javascript, */*; q=0.01",
            ["User-Agent"] = Config.getUserAgent(),
            ["X-Requested-With"] = "XMLHttpRequest",
            ["Origin"] = base,
            ["Referer"] = base and (base .. "/") or nil,
            ["Content-Length"] = tostring(#body),
        },
        body = body,
        timeout = Config.getLoginTimeout(),
        -- Avoid redirects - 301/302 convert POST to GET per RFC.
        redirect = false,
        -- retry after URL redirection
        onRedirect = (not is_redirect_retry) and function()
            return function() return _postCredentials(endpoint, email, password, true) end
        end,
    }
end

-- What one endpoint made of the credentials: the caller-facing result, and why it produced no
-- session. Only "declined" is worth putting to the other endpoint --
--   no_answer: nothing came back at all (timeout, transport failure, no status). A second request
--              over the same dead connection would only make the reader wait twice.
--   blocked:   the mirror answered with a browser check, which it answers to every endpoint on it.
--              makeHttpRequest has already marked the mirror and produced the message that helps
--              ("try a different Z-library server"); a second refusal would only bury it.
--   declined:  the server read the request and refused it -- a validationError, an HTTP error, a
--              body that is not the JSON we expect. This is the case the other endpoint is for.
local function _attemptLogin(endpoint, email, password)
    local result = { user_id = nil, user_key = nil, error = nil }

    local login_url = _loginEndpointUrl(endpoint)
    if not login_url then
        result.error = T("The Z-library server address (URL) is not set. Please configure it in the Z-library plugin settings.")
        logger.err(string.format("Zlibrary:Api.login - END (Configuration error) - Error: %s", result.error))
        return result, "no_answer"
    end

    -- The entry is broken rather than the server: a field naming a placeholder that does not
    -- exist, or no fields at all. Refuse it before it reaches the network, because the request it
    -- would send is one with an empty password in it, and the server's answer to that is
    -- indistinguishable from the reader having typed the wrong one.
    -- Rendered once here to check it can be, and again in _postCredentials to send -- which is
    -- also where a redirect re-renders it against the mirror it moved to.
    if not _renderLoginBody(endpoint, email, password) then
        result.error = T("Login failed")
        logger.err(string.format("Zlibrary:Api.login - END (Unusable endpoint) - %s has no usable request body",
            tostring(endpoint.label)))
        return result, "unusable"
    end

    local http_result = _postCredentials(endpoint, email, password) or {}

    -- Credential-safe diagnostics for the "signs in for me, not for them" reports. Which endpoint
    -- the request reached and the HTTP status are what separate a genuinely wrong password (rpc.php's
    -- JSON validationError, status 200) from an endpoint that does not serve login at all (a
    -- browser check or HTML page: a non-JSON body, or an odd status). login_url carries no secret;
    -- the request body is deliberately never logged, since it holds the password.
    local diag = string.format(" [server=%s status=%s]",
        tostring(login_url), tostring(http_result.status_code))

    -- No status at all: nothing answered, so there is nothing for the other endpoint to improve on.
    if type(http_result.status_code) ~= "number" then
        result.error = http_result.error or T("Login failed: Empty response from server")
        logger.err(string.format("Zlibrary:Api.login - END (No answer) - Error: %s%s", result.error, diag))
        return result, "no_answer"
    end

    if http_result.error and string.find(tostring(http_result.error), Api.BLOCKED_TEXT, 1, true) then
        result.error = http_result.error
        logger.warn(string.format("Zlibrary:Api.login - END (Mirror blocked) - Error: %s%s", result.error, diag))
        return result, "blocked"
    end

    if not http_result.body or http_result.body == "" then
        result.error = http_result.error or T("Login failed: Empty response from server")
        logger.err(string.format("Zlibrary:Api.login - END (Empty body) - Error: %s%s", result.error, diag))
        return result, "declined"
    end

    -- json.decode raises on an unparseable body rather than returning an error, so it needs the
    -- pcall the other decode sites already use; without it a Cloudflare challenge or any HTML error
    -- page escapes Api.login as a raw Lua error. json.decode.simple maps json null to nil -- without
    -- it null decodes to a function sentinel, which is truthy and defeats the guards below.
    local success, data = pcall(json.decode, http_result.body, json.decode.simple)

    if not success or type(data) ~= "table" then
        result.error = http_result.error or T("Login failed: Invalid response format")
        -- Truncated: a mirror serving a browser-check or HTML error page instead of JSON can return
        -- a large document, and the first part is enough to recognise what it is.
        logger.err(string.format("Zlibrary:Api.login - END (JSON error) - Error: %s%s, Body: %s",
            result.error, diag, tostring(http_result.body):sub(1, 300)))
        return result, "declined"
    end

    -- rpc.php returns the session under `response` on success --
    --   {"errors":[],"response":{"user_id":21699629,"user_key":"..."}}
    -- and a validation error there on bad credentials --
    --   {"errors":[],"response":{"validationError":true,"message":"Incorrect email or password"}}
    -- so read the session first and only treat the reply as a failure when no session is present.
    -- data.user is kept as a fallback for the older /eapi shape ({user:{id,remix_userkey}}).
    local session = (type(data.response) == "table" and data.response)
                 or (type(data.user) == "table" and data.user) or {}
    local user_id = tostring(session.id or session.user_id or "")
    local user_key = session.remix_userkey or session.user_key or ""

    if user_id ~= "" and user_key ~= "" then
        result.user_id = user_id
        result.user_key = user_key
        logger.info(string.format("Zlibrary:Api.login - END (Success) - UserID: %s%s", result.user_id, diag))
        return result, "session"
    end

    -- No session: surface the server's message. session.message carries rpc.php's wording
    -- ("Incorrect email or password"), which Api.isCredentialRejection matches so a wrong password is
    -- corrected in place. Guard every error index the way Api.search does, or a structured error
    -- surfaces as "table: 0x..." and defeats that classifier.
    local errors = data.errors
    local api_message = session.message
        or (type(data.error) == "table" and data.error.message) or data.error
        or (type(errors) == "table" and type(errors[1]) == "table" and errors[1].message)
        or (type(errors) == "table" and type(errors[1]) == "string" and errors[1])
        or data.message
    result.error = (api_message and tostring(api_message))
        or http_result.error
        or (T("Login failed") .. ": " .. Api.CREDENTIALS_REJECTED_TEXT)
    logger.warn(string.format("Zlibrary:Api.login - END (API error) - Error: %s%s", result.error, diag))
    return result, "declined"
end

function Api.login(email, password)
    logger.info(string.format("Zlibrary:Api.login - START"))

    local primary, secondary = Api.LOGIN_ENDPOINTS[1], Api.LOGIN_ENDPOINTS[2]
    local result, outcome = _attemptLogin(primary, email, password)
    -- "unusable" joins "declined" here: a first entry that could not be built into a request says
    -- nothing about the second, so the second is still worth asking.
    if outcome ~= "declined" and outcome ~= "unusable" then return result end

    -- A lockout is not a verdict on the credentials, and a second sign-in is exactly what the
    -- server just asked us to stop doing: it would spend another attempt for nothing and push the
    -- lockout further out. Without this the fallback would burn two attempts per try and reach the
    -- limit twice as fast, on the failure path where readers retry most.
    if Api.isRateLimited(result.error) then
        logger.warn(string.format("Zlibrary:Api.login - %s is rate-limiting sign-ins; not asking %s",
            primary.label, secondary.label))
        return result
    end

    -- The server read these credentials and refused them. That is worth a second opinion before the
    -- reader is told their password is wrong: the endpoints have taken turns being the broken one,
    -- and a refusal from one of them has meant nothing about the other. Only on this path, so a
    -- sign-in that works still costs a single request.
    logger.info(string.format("Zlibrary:Api.login - %s refused the sign-in (%s); asking %s",
        primary.label, tostring(result.error), secondary.label))

    local fallback = _attemptLogin(secondary, email, password)
    if fallback.user_id then
        logger.info(string.format("Zlibrary:Api.login - %s accepted the sign-in %s refused",
            secondary.label, primary.label))
        return fallback
    end

    -- Both refused. Report the first endpoint's error, unless only the second recognised these as
    -- credentials it read and rejected: "Incorrect email or password" can be corrected in place,
    -- where "Invalid response format" only tells the reader that something is broken.
    if Api.isCredentialRejection(fallback.error) and not Api.isCredentialRejection(result.error) then
        return fallback
    end
    return result
end

return Api
