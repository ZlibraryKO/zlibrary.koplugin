-- Does a search -- the first page, or "load more" on the results page -- retry authentication?
-- (The first-search half is at the end of this file.)
--
-- "Load more" must not. The first page was answered with the same session moments earlier, so a
-- refusal there is not a stale session. An earlier version carried an auth-retry in the load-more
-- handlers, copied from the authenticated fetch handlers, and it called on_goto_page_handler
-- again on "login success" with no one-shot guard: had the endpoint ever rejected the session it
-- would have looped fetch -> login -> fetch forever.
--
-- The first search may sign in once, since 2026-11-26: the endpoint answers "Access denied" to a
-- session it cannot use. That sign-in has to be the guarded, one-shot kind, keyed on that answer
-- only (search_account_harness drives it). The retry pattern stays right for the paths that
-- authenticate through _requestDispatcher; this asserts the contrast directly.

local PLUGIN = assert(arg[1], "usage: luajit search_pagination_auth_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

-- The plugin class: main.lua and the plugin_* parts it mixes its methods in from.
local MAIN = support.plugin_class_files(PLUGIN)

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
-- AsyncHelper.run or .runCancellable: the call became cancellable after this test was written.
local load_more = support.extract_block(MAIN,
    "(on_success_load_more = function.-AsyncHelper%.run%a*%(task_load_more)")
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

-- ---------------------------------------------------------------- the first search
-- Until 2026-11 performSearch carried the dispatcher's auth-retry, keyed on "Please login" --
-- which a search never answered. Since 2026-11-26 it signs in once on "Access denied" instead.
-- Pinned here: that sign-in is behind the one-shot flag and the "Access denied" check, and no
-- general auth classifier creeps back in.
local search = support.extract_block(MAIN, "(\nfunction Zlibrary:performSearch%(.-\nend\n)")
local search_code = strip_comments(search)

r.check("the first search signs in again only behind its one-shot guard",
        count(search_code, "self:login(") == 2
            and search_code:find("if may_renew_session and _mayRenewSessionFor(self, user_session) then", 1, true) ~= nil
            and search_code:find("attemptSearch(false)", 1, true) ~= nil,
        "performSearch's sign-in is no longer the account gate plus one guarded re-sign-in")
r.check("and never classifies its error as an auth failure",
        count(search_code, "Api.isAuthenticationError(") == 0,
        "Api.isAuthenticationError is called on a search result: a \"Please login\" in some other "
        .. "error text would put a credentials dialog in the middle of a search")

-- Removing the retry must not take the session with it. It carries the account's website
-- settings -- hiding 18+ books among them -- so every search request has to send it.
r.check("the first search still sends the stored session",
        search_code:find("Api.search(query, user_session and user_session.user_id, "
            .. "user_session and user_session.user_key", 1, true) ~= nil,
        "performSearch no longer passes the stored session to Api.search")
local dialog_calls = count(search_code, "Ui.showSearchErrorDialog(")
local dialog_with_session = select(2, search_code:gsub("Ui%.showSearchErrorDialog%([%w_%.]+, query, user_session,", ""))
r.check("and hands it to every retry dialog",
        dialog_calls > 0 and dialog_with_session == dialog_calls,
        string.format("%d of %d showSearchErrorDialog calls pass user_session", dialog_with_session, dialog_calls))

local retry = support.extract_block(support.ui_files(PLUGIN),
    "(\nfunction Ui%.showSearchErrorDialog%(.-\nend\n)")
r.check("whose Retry searches with that session",
        retry:find("Api.search(query, user_session.user_id, user_session.user_key", 1, true) ~= nil,
        "Ui.showSearchErrorDialog retries without the session it was given")

local more = support.extract_block(MAIN, "(local task_load_more = function%(%).-\n%s*end\n)")
r.check("and the next result page sends the session too",
        more:find("user_session_more.user_id, user_session_more.user_key", 1, true) ~= nil,
        "loading more results no longer passes the stored session")

r.finish()
