-- Does "load more" on the search results page retry authentication?
--
-- It must not, and here is why. Search is an unauthenticated endpoint -- Api.search sends the
-- session cookie only when there is one, and the server answers without it -- so a search can
-- never come back with "Please login", and Api.isAuthenticationError can never match one. An
-- earlier version nonetheless carried an auth-retry in the load-more handlers, copied wholesale
-- from the authenticated fetch handlers where it belongs. It was dead code, and worse: it called
-- on_goto_page_handler again on "login success" with no one-shot guard, so had the endpoint ever
-- started rejecting a session it would have looped fetch -> login -> fetch forever.
--
-- The retry pattern is right for the paths that actually authenticate (My Books, book details,
-- downloads), which go through _requestDispatcher with a guarded, one-shot retry. This asserts
-- the contrast directly: absent from the search-pagination path, present in the fetch path. A
-- future copy-paste that reintroduces it fails here instead of on someone's device.

local PLUGIN = assert(arg[1], "usage: luajit search_pagination_auth_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local MAIN = PLUGIN .. "/main.lua"

-- Drop whole-line comments, so the prose above the code -- which names isAuthenticationError on
-- purpose -- is never mistaken for a live call to it.
local function strip_comments(src)
    return (src:gsub("[^\n]*", function(line)
        return line:match("^%s*%-%-") and "" or line
    end))
end

local function count(src, needle)
    local n, pos = 0, 1
    while true do
        local s, e = string.find(src, needle, pos, true)
        if not s then break end
        n, pos = n + 1, e + 1
    end
    return n
end

-- ---------------------------------------------------------------- the search-pagination path
-- The two load-more handlers plus the async call that drives them, captured as one region.
local load_more = support.extract_block(MAIN,
    "(on_success_load_more = function.-AsyncHelper%.run%(task_load_more)")
local load_more_code = strip_comments(load_more)

r.check("the search load-more path never re-logs-in", count(load_more_code, "self:login(") == 0,
        "self:login appears in the load-more handlers -- search does not authenticate, so this "
        .. "is the dead auth-retry (and its unguarded self-recursion) come back")
r.check("and never classifies an error as an auth failure",
        count(load_more_code, "Api.isAuthenticationError(") == 0,
        "Api.isAuthenticationError is called on a search result, which cannot be an auth error")
r.check("and does not call on_goto_page_handler from inside its own handlers",
        count(load_more_code, "on_goto_page_handler(") == 0,
        "the load-more handlers re-enter the pager -- the shape that looped without a one-shot guard")

-- Guard against the assertion passing for the wrong reason: it must not be satisfied by simply
-- deleting auth-retry everywhere. The authenticated fetch path has to keep it.
local dispatcher = support.extract_block(MAIN,
    "(\nfunction Zlibrary:_requestDispatcher%(.-\nend\n)")
local dispatcher_code = strip_comments(dispatcher)

r.check("the authenticated fetch path still retries a rejected session",
        count(dispatcher_code, "Api.isAuthenticationError(") > 0
            and count(dispatcher_code, "self:login(") > 0,
        "_requestDispatcher lost its auth-retry -- this test would then be passing because the "
        .. "behaviour was removed from where it is needed, not just from where it was dead")
r.check("and that retry is the guarded, one-shot kind",
        count(dispatcher_code, "retry_on_auth_error") > 0,
        "the fetch retry is no longer gated by retry_on_auth_error, so it can loop")

r.finish()
