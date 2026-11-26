-- Does a search ask for an account, and sign in again once when its session is refused?
--
-- Since 2026-11-26 Z-library answers a search with HTTP 400 {"success":0,"error":"Access denied"}
-- when the request has no session or one it cannot use, and with results for a valid one. (On
-- 2026-11-10 it still ignored a bad session and answered anyway; from 2026-11-23 to 11-26 it
-- refused every search.) So performSearch must:
--
--   * ask for credentials before anything else when there is no account, and search once they
--     are saved (dropping the search when the dialog is closed);
--   * on "Access denied", sign in once and repeat the search -- but only with a password to sign
--     in with, and not for a session that was refused straight after a sign-in, so a server-wide
--     refusal costs one sign-in rather than one per search;
--   * never sign in for any other error.
--
-- Drives the real performSearch from zlibrary/plugin_search.lua with a scripted Api.search and a
-- fake login. Each check is written so that inverting the branch it covers fails it.

local PLUGIN = assert(arg[1], "usage: luajit search_account_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local SRC = PLUGIN .. "/zlibrary/plugin_search.lua"
local helper = support.extract_block(SRC, "(\nlocal function _mayRenewSessionFor%(.-\nend\n)")
local perform = support.extract_block(SRC, "(\nfunction Zlibrary:performSearch%(.-\nend\n)")

local DENIED = { error = "Z-library is refusing searches right now.", api_error = "Access denied", status_code = 400 }
local RESULTS = { results = { { id = 1, title = "Dune" } } }

-- opts.account: "password" (email + password stored), "file" (session only), or "none".
-- opts.answers: what each Api.search call returns, in order (the last one repeats).
-- opts.login_ok: what the fake login reports; on success it hands out opts.fresh_key.
local function newRig(opts)
    local rig = {
        account = opts.account or "password",
        session_key = opts.session_key or "stale",
        answers = opts.answers or { RESULTS },
        searches = {},        -- the session key each Api.search call carried
        logins = 0,
        error_dialogs = 0,
        shown = 0,            -- result lists displayed
        network_asks = 0,
    }
    local env = {
        type = type, tostring = tostring, string = string, table = table, ipairs = ipairs,
        T = function(s) return s end,
    }
    env.logger = { dbg = function() end, info = function() end, warn = function() end, err = function() end }
    env.UIManager = { nextTick = function(_, fn) fn() end }
    env.NetworkMgr = { willRerunWhenOnline = function() rig.network_asks = rig.network_asks + 1; return false end }
    env.Config = {
        hasCredentials = function() return rig.account ~= "none" end,
        getCredentials = function()
            if rig.account == "password" then return { username = "reader@example.com", password = "hunter2" } end
            return {}
        end,
        getUserSession = function()
            if rig.account == "none" then return {} end
            return { user_id = "42", user_key = rig.session_key }
        end,
        getSearchLanguages = function() return {} end,
        getSearchExtensions = function() return {} end,
        getSearchOrder = function() return {} end,
        getSearchContentType = function() return "book" end,
        addSearchHistory = function() end,
    }
    env.Api = {
        search = function(_, _, user_key)
            table.insert(rig.searches, tostring(user_key))
            return rig.answers[math.min(#rig.searches, #rig.answers)]
        end,
    }
    env.math = math
    env.Ui = {
        showCancellableLoadingMessage = function() return {} end,
        closeMessage = function() end,
        showInfoMessage = function() end,
        showSearchErrorDialog = function() rig.error_dialogs = rig.error_dialogs + 1 end,
    }
    -- The real routing (async_helper.lua): a result carrying .error goes to on_error as a bare
    -- string, everything else to on_success. A fake that handed every result to on_success hid
    -- that the refusal's api_error never reached performSearch (found on the Kindle 2026-11-26).
    env.AsyncHelper = { runCancellable = function(task, on_success, on_error)
        local res = task()
        if res and res.error then
            if on_error then on_error(tostring(res.error)) end
        else
            on_success(res)
        end
    end }

    local chunk = assert(loadstring("local Zlibrary = {}\n" .. helper .. perform .. "return Zlibrary",
                                    "=performSearch"))
    setfenv(chunk, env)
    local Z = chunk()
    Z.displaySearchResults = function() rig.shown = rig.shown + 1 end
    Z.login = function(_, callback)
        rig.logins = rig.logins + 1
        -- A sign-in loop would recurse until the stack runs out; stop it so the counts fail
        -- a check instead.
        if opts.login_ok == false or rig.logins > 5 then callback(false); return end
        if rig.account == "none" then rig.account = "password" end
        rig.session_key = opts.fresh_key or "fresh"
        callback(true)
    end
    rig.Z = Z
    rig.search = function(q) Z:performSearch(q or "dune") end
    return rig
end

-- ---------------------------------------------------------------- no account
do
    local rig = newRig({ account = "none" })
    rig.search()
    r.check("a search with no account asks for one", rig.logins == 1, "logins: " .. rig.logins)
    r.check("and searches once it is saved, with the new session",
            #rig.searches == 1 and rig.searches[1] == "fresh" and rig.shown == 1,
            "searches: " .. table.concat(rig.searches, ","))

    local dismissed = newRig({ account = "none", login_ok = false })
    dismissed.search()
    r.check("closing the credentials dialog drops the search, without an error or a Wi-Fi prompt",
            #dismissed.searches == 0 and dismissed.error_dialogs == 0 and dismissed.network_asks == 0,
            string.format("searches %d, error dialogs %d, network asks %d",
                #dismissed.searches, dismissed.error_dialogs, dismissed.network_asks))
end

-- ---------------------------------------------------------------- a session that stopped working
do
    local rig = newRig({ answers = { DENIED, RESULTS } })
    rig.search()
    r.check("a refused search signs in again once", rig.logins == 1, "logins: " .. rig.logins)
    r.check("and repeats the search with the new session, showing its results",
            #rig.searches == 2 and rig.searches[2] == "fresh" and rig.shown == 1 and rig.error_dialogs == 0,
            string.format("searches %s, shown %d, error dialogs %d",
                table.concat(rig.searches, ","), rig.shown, rig.error_dialogs))
end

-- ---------------------------------------------------------------- Z-library refusing everyone
do
    local rig = newRig({ answers = { DENIED } })
    rig.search()
    r.check("a search still refused after the fresh sign-in shows the refusal",
            rig.logins == 1 and #rig.searches == 2 and rig.error_dialogs == 1,
            string.format("logins %d, searches %d, error dialogs %d", rig.logins, #rig.searches, rig.error_dialogs))
    rig.search()
    r.check("and the next search is refused without another sign-in",
            rig.logins == 1 and #rig.searches == 3 and rig.error_dialogs == 2,
            string.format("logins %d, searches %d, error dialogs %d", rig.logins, #rig.searches, rig.error_dialogs))

    -- Once searches are answered again, the guard lifts: the same session refused later is
    -- worth its one sign-in again.
    rig.answers = { RESULTS }
    rig.searches = {}
    rig.search()
    rig.answers = { DENIED, RESULTS }
    rig.searches = {}
    rig.search()
    r.check("after a search is answered, a later refusal signs in again",
            rig.logins == 2 and rig.shown == 2,
            string.format("logins %d, shown %d", rig.logins, rig.shown))
end

-- ---------------------------------------------------------------- nothing to sign in with
do
    local rig = newRig({ account = "file", answers = { DENIED } })
    rig.search()
    r.check("a session set only in the credentials file is not renewed: the refusal shows",
            rig.logins == 0 and #rig.searches == 1 and rig.error_dialogs == 1,
            string.format("logins %d, searches %d, error dialogs %d", rig.logins, #rig.searches, rig.error_dialogs))
end

-- ---------------------------------------------------------------- other errors
do
    local rig = newRig({ answers = { { error = "Search API error: Please login", api_error = "Please login" } } })
    rig.search()
    r.check("any other error goes to the retry dialog, without a sign-in",
            rig.logins == 0 and rig.error_dialogs == 1,
            string.format("logins %d, error dialogs %d", rig.logins, rig.error_dialogs))

    local ok = newRig({})
    ok.search()
    r.check("a search that is answered signs in no one", ok.logins == 0 and ok.shown == 1,
            string.format("logins %d, shown %d", ok.logins, ok.shown))
end

r.finish()
