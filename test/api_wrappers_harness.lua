-- What request does each Api.* call actually issue, and what does it make of the answer?
--
-- Around a dozen of these functions are the same twenty lines with different nouns: fetch a URL
-- from Config, attach the session cookie, call makeHttpRequest, then check the error, the body,
-- the JSON and the API's own success flag in turn. That repetition is worth collapsing, but
-- until now none of it was covered -- makeHttpRequest was tested and its callers were not -- so
-- there was nothing to say a consolidation had preserved their behaviour.
--
-- This pins the behaviour down: which Config getter supplies the URL and the timeout, whether
-- the session cookie is attached, which flags are set, and what each of the four failure paths
-- returns. It is deliberately about observable behaviour rather than structure, so it holds
-- across a refactor rather than describing one particular shape of code.

local PLUGIN = assert(arg[1], "usage: luajit api_wrappers_harness.lua <plugin-root> <luasocket-src>")
local LUASOCKET = assert(arg[2], "usage: luajit api_wrappers_harness.lua <plugin-root> <luasocket-src>")

package.path = PLUGIN .. "/?.lua;" .. package.path
local support = dofile(PLUGIN .. "/test/support.lua")
support.preload_socket(LUASOCKET)
support.preload_koreader_stubs()
local r = support.reporter()

-- Bodies are named rather than parsed. A JSON parser written for a harness is a second thing
-- that can be wrong -- the first draft of this one mangled arrays and reported four plugin
-- failures that were its own -- and nothing here is testing a decoder anyway.
local BODIES = {
    books      = { success = 1, books = { { id = 1, title = "T", author = "A" } } },
    -- The paginated calls reject a response with no pagination block, so they need their own.
    -- "current", not "current_page": the paging hint compares it against the page that was
    -- asked for, so the field name matters.
    books_paged = { success = 1, books = { { id = 1, title = "T", author = "A" } },
                    pagination = { total_pages = 3, current = 1 } },
    books_last_page = { success = 1, books = { { id = 1, title = "T", author = "A" } },
                        pagination = { total_pages = 1, current = 1 } },
    -- Same, but with pagination as a string. getDownloadedBooks type-checks it and refuses;
    -- getFavoriteBooks only tests truthiness and accepts. That difference is real, not an
    -- oversight of this harness, and collapsing these two would erase it.
    books_paged_loose = { success = 1, books = { { id = 1, title = "T", author = "A" } },
                          pagination = "3" },
    book       = { success = 1, book = { id = 1, title = "T", author = "A" } },
    ok         = { success = 1 },
    api_failed = { success = 0, message = "nope" },
}
package.preload["json"] = function()
    return {
        decode = setmetatable({ simple = {} }, { __call = function(_, s)
            local v = BODIES[s]
            if not v then error("parse error: " .. tostring(s)) end
            return v
        end }),
    }
end

-- Any Config.getFooUrl() answers with a URL naming itself, and any Config.getFooTimeout() with a
-- recognisable pair, so a wrapper reaching for the wrong one is visible rather than merely wrong.
local asked
package.preload["zlibrary.config"] = function()
    return setmetatable({ USER_AGENT = "test-agent" }, {
        __index = function(_, key)
            return function()
                asked[#asked + 1] = key
                if key:match("Url$") then return "https://z.example/eapi/" .. key end
                if key:match("Timeout$") then return { 11, 22 } end
                return nil
            end
        end,
    })
end

-- api.lua requires socket.http at load; nothing here reaches the real transport, since
-- makeHttpRequest is replaced below, but the require still has to resolve.
package.preload["socket.http"] = function()
    return { request = function() error("the transport is stubbed in this harness") end }
end

local Api = require("zlibrary.api")

-- Intercept the transport. The wrappers call Api.makeHttpRequest through the module table, so
-- replacing it here captures exactly what each one would have put on the wire.
local sent, reply
local real_makeHttpRequest = Api.makeHttpRequest
Api.makeHttpRequest = function(options)
    sent = options
    return reply
end

local function call(fn, args, response)
    asked, sent = {}, nil
    reply = response
    local ok, result = pcall(Api[fn], unpack(args))
    return ok and result or { error = "RAISED: " .. tostring(result) }, sent, asked
end

local function asked_for(list, name)
    for _, k in ipairs(list) do if k == name then return true end end
    return false
end

local UID, UKEY = "42", "secret"
local COOKIE = "remix_userid=42; remix_userkey=secret"

-- name, args, the Config getters it must use, the field it reads out of a good response
local WRAPPERS = {
    { "getRecommendedBooks", { UID, UKEY }, "getRecommendedBooksUrl", "getRecommendedTimeout",
      "books", "books" },
    { "getMostPopularBooks", { UID, UKEY }, "getMostPopularBooksUrl", "getPopularTimeout",
      "books", "books" },
    { "getDownloadedBooks", { UID, UKEY, 1, "date" }, "getDownloadedBooksUrl", "getPopularTimeout",
      "books_paged", "books" },
    { "getFavoriteBooks", { UID, UKEY, 1, "date" }, "getFavoriteBooksUrl", "getPopularTimeout",
      "books_paged", "books" },
}

for _, w in ipairs(WRAPPERS) do
    local name, args, url_getter, timeout_getter, good_body, field = unpack(w)

    -- ---------------------------------------------------------------- the request
    local _, req, used = call(name, args, { body = good_body })
    r.check(name .. ": issues a request at all", req ~= nil, "makeHttpRequest was not called")
    if req then
        r.check(name .. ": takes its URL from " .. url_getter,
                asked_for(used, url_getter), "asked for: " .. table.concat(used, ", "))
        r.check(name .. ": takes its timeout from " .. timeout_getter,
                asked_for(used, timeout_getter), "asked for: " .. table.concat(used, ", "))
        r.check(name .. ": sends the session cookie",
                req.headers and req.headers["Cookie"] == COOKIE,
                "Cookie: " .. tostring(req.headers and req.headers["Cookie"]))
        r.check(name .. ": identifies itself",
                req.headers and req.headers["User-Agent"] == "test-agent",
                "UA: " .. tostring(req.headers and req.headers["User-Agent"]))
        r.check(name .. ": can rebuild its URL after a mirror move",
                type(req.onRedirect) == "function" or type(req.onRedirect) == "table",
                "onRedirect = " .. type(req.onRedirect))
    end

    -- ---------------------------------------------------------------- no credentials
    local no_cred_args = {}
    for i, a in ipairs(args) do no_cred_args[i] = a end
    no_cred_args[1], no_cred_args[2] = nil, nil
    local _, req2 = call(name, no_cred_args, { body = good_body })
    r.check(name .. ": omits the cookie when signed out",
            req2 == nil or not (req2.headers and req2.headers["Cookie"]),
            "sent: " .. tostring(req2 and req2.headers and req2.headers["Cookie"]))

    -- ---------------------------------------------------------------- the four failures
    local res = call(name, args, { error = "boom" })
    r.check(name .. ": passes a transport error through", res.error ~= nil, "no error returned")

    res = call(name, args, {})
    r.check(name .. ": reports a missing body", res.error ~= nil, "no error for an empty response")

    res = call(name, args, { body = "unparseable" })
    r.check(name .. ": reports an undecodable body", res.error ~= nil, "no error for bad JSON")

    res = call(name, args, { body = "api_failed" })
    r.check(name .. ": reports an API failure", res.error ~= nil, "no error for success=0")

    -- ---------------------------------------------------------------- the happy path
    res = call(name, args, { body = good_body })
    r.check(name .. ": returns " .. field .. " on success",
            res[field] ~= nil and res.error == nil,
            "got error=" .. tostring(res.error))
end

-- Every authenticated JSON call builds the same header table. Twelve sites wrote it out by hand,
-- two of them with the keys in a different order, which in Lua is the same table. Assert the
-- shape on all of them rather than only the four exercised above, so consolidating that block
-- cannot quietly change what any one of them sends. Only the request matters here, so a canned
-- transport error is answer enough.
local AUTHED = {
    { "getRecommendedBooks", { UID, UKEY } },
    { "getMostPopularBooks", { UID, UKEY } },
    { "getBookDetails", { UID, UKEY, "1", "h" } },
    { "getDownloadLink", { UID, UKEY, "1", "h" } },
    { "getSimilarBooks", { UID, UKEY, "1", "h" } },
    { "getDownloadedBooks", { UID, UKEY, 1, "date" } },
    { "getFavoriteBooks", { UID, UKEY, 1, "date" } },
    { "deleteDownloadedBook", { UID, UKEY, { id = "1", hash = "h" } } },
    { "unfavoriteBook", { UID, UKEY, { id = "1", hash = "h" } } },
    { "getDownloadQuotaStatus", { UID, UKEY } },
    { "getFavoriteBookIds", { UID, UKEY } },
    { "favoriteBook", { UID, UKEY, { id = "1", hash = "h" } } },
}
for _, w in ipairs(AUTHED) do
    local name, args = w[1], w[2]
    local _, req = call(name, args, { error = "stop here" })
    local h = req and req.headers or {}
    r.check(name .. ": header block is the standard one",
            h["Cookie"] == COOKIE
                and h["User-Agent"] == "test-agent"
                and h["Content-Type"] == "application/x-www-form-urlencoded",
            req and string.format("Cookie=%s UA=%s CT=%s", tostring(h["Cookie"]),
                tostring(h["User-Agent"]), tostring(h["Content-Type"])) or "no request issued")
end

-- The paginated pair return a paging hint alongside the books.
for _, name in ipairs({ "getDownloadedBooks", "getFavoriteBooks" }) do
    local res = call(name, { UID, UKEY, 1, "date" }, { body = "books_paged" })
    r.check(name .. ": reports whether more pages follow", res.has_more_results ~= nil,
            "has_more_results = " .. tostring(res.has_more_results))
    r.check(name .. ": says more follow when the page is not the last", res.has_more_results == true,
            "has_more_results = " .. tostring(res.has_more_results))
    res = call(name, { UID, UKEY, 1, "date" }, { body = "books_last_page" })
    r.check(name .. ": says no more follow on the last page", not res.has_more_results,
            "has_more_results = " .. tostring(res.has_more_results))
    res = call(name, { UID, UKEY, 1, "date" }, { body = "books" })
    r.check(name .. ": refuses a response with no pagination block", res.error ~= nil,
            "accepted it")
end

-- Pinned because it is a genuine difference between two functions that otherwise read alike.
-- Whichever way a future refactor unifies them, it should be a decision rather than an accident.
local loose = call("getFavoriteBooks", { UID, UKEY, 1, "date" }, { body = "books_paged_loose" })
r.check("getFavoriteBooks: accepts a non-table pagination value", loose.error == nil,
        "error = " .. tostring(loose.error))
local strict = call("getDownloadedBooks", { UID, UKEY, 1, "date" }, { body = "books_paged_loose" })
r.check("getDownloadedBooks: requires pagination to be a table", strict.error ~= nil,
        "accepted a string")

-- The outliers are asserted only where they differ, since their whole point is differing.
local _, req = call("getBookDetails", { UID, UKEY, "1", "h" }, { body = "book" })
r.check("getBookDetails: retries a stalled request", req and req.retry_on_stall == true,
        "retry_on_stall = " .. tostring(req and req.retry_on_stall))

_, req = call("healthCheck", { "https://z.example" }, { status_code = 200, body = "ok" })
r.check("healthCheck: does not consult the pinned redirect target",
        req and req.skipRedirectCache ~= nil, "skipRedirectCache = " .. tostring(req and req.skipRedirectCache))
r.check("healthCheck: sends no session cookie",
        req and not (req.headers and req.headers["Cookie"]), "sent a cookie")

Api.makeHttpRequest = real_makeHttpRequest
r.finish()
