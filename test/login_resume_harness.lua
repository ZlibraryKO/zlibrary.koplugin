-- Does a successful re-login actually resume what the user was doing?
--
-- Three seams carry that promise, and a mutation experiment proved none of them was pinned:
-- each edit below was applied to the real source and the entire suite stayed green.
--
--   1. swapping the "rejected"/"transport" verdicts in _verifyCredentials (main.lua)
--   2. inverting `if login_ok then` in the auth gate of _requestDispatcher (main.lua)
--   3. inverting `if login_ok then` in the credentials gate of Download.run (download.lua)
--
-- The verdict CONSUMERS are already covered: first_run_login_harness drives the credentials
-- broker with a fake _verifyCredentials and asserts a rejection keeps the dialog open and
-- stores nothing while a transport failure stores unchecked. What nobody drove is the code
-- that PRODUCES the verdict, and the two gates that decide whether a parked action runs once
-- login answers. Each section below drives the real function through a fake login and is
-- written so its mutation fails it -- that is the whole point of this file.

local PLUGIN = assert(arg[1], "usage: luajit login_resume_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local MAIN = PLUGIN .. "/main.lua"
local DOWNLOAD = PLUGIN .. "/zlibrary/download.lua"

-- AsyncHelper.run's decision shape, minus the coroutine: a task result carrying .error, or a
-- task that raised, goes to on_error; anything else to on_success. The seams below sit behind
-- that routing, so the stub reproduces it instead of handing the harness the raw callbacks.
local function fakeAsyncHelper()
    return { run = function(task, on_success, on_error)
        local ok, result = pcall(task)
        if ok and not (type(result) == "table" and result.error) then
            if on_success then on_success(result) end
        elseif on_error then
            on_error(ok and tostring(result.error) or tostring(result))
        end
    end }
end

-- ---------------------------------------------------------------- which verdict the check reports
--
-- Seam 1. "rejected" keeps the typed-in pair on screen for a correction; "transport" stores it
-- unchecked. Swapping the two stores a password the server refused and refuses to store one it
-- never saw -- and every consumer test still passed, because they inject the verdict by hand.
do
    -- The real classifier, so the chain from error text to verdict has no stub in the middle.
    local api_env = { string = string, tostring = tostring, Api = {} }
    api_env.Api.CREDENTIALS_REJECTED_TEXT = "Credentials rejected or invalid response"
    local classifier_body = support.extract_block(PLUGIN .. "/zlibrary/api.lua",
        "(\nfunction Api%.isCredentialRejection%(.-\n)end\n")
    local classifier_chunk = assert(loadstring(
        "local Api = ...\n" .. classifier_body .. "end\nreturn Api", "=isCredentialRejection"))
    setfenv(classifier_chunk, api_env)
    local isCredentialRejection = classifier_chunk(api_env.Api).isCredentialRejection

    local function newVerifyRig(login_result)
        local rig = { login_calls = {}, results = {} }
        local env = { tostring = tostring }
        env.AsyncHelper = fakeAsyncHelper()
        env.Api = {
            isCredentialRejection = isCredentialRejection,
            login = function(email, password)
                table.insert(rig.login_calls, { email = email, password = password })
                return login_result
            end,
        }
        local body = support.extract_block(MAIN, "(\nfunction Zlibrary%:_verifyCredentials%(.-\n)end\n")
        local chunk = assert(loadstring("local Zlibrary = {}\n" .. body .. "end\nreturn Zlibrary",
                                        "=_verifyCredentials"))
        setfenv(chunk, env)
        rig.Z = chunk()
        rig.verify = function()
            rig.Z:_verifyCredentials("reader@example.com", "hunter2",
                function(status, message, session)
                    table.insert(rig.results,
                        { status = status, message = message, session = session })
                end)
        end
        return rig
    end

    local ok_rig = newVerifyRig({ user_id = "42", user_key = "abc" })
    ok_rig.verify()
    r.check("the check submits exactly the pair that was typed",
            #ok_rig.login_calls == 1
                and ok_rig.login_calls[1].email == "reader@example.com"
                and ok_rig.login_calls[1].password == "hunter2",
            "ran " .. #ok_rig.login_calls .. " logins")
    r.check("an accepted pair is reported as ok, with the session the server minted",
            #ok_rig.results == 1 and ok_rig.results[1].status == "ok"
                and ok_rig.results[1].session.user_id == "42"
                and ok_rig.results[1].session.user_key == "abc",
            "got " .. tostring(ok_rig.results[1] and ok_rig.results[1].status))
    r.check("and carries no error message", ok_rig.results[1].message == nil,
            "carried " .. tostring(ok_rig.results[1].message))

    local refused = newVerifyRig({ error = "Login failed: Incorrect email or password" })
    refused.verify()
    r.check("a pair the server refused is reported as rejected, so the dialog keeps it for a correction",
            #refused.results == 1 and refused.results[1].status == "rejected",
            "got " .. tostring(refused.results[1] and refused.results[1].status)
                .. " -- as transport the refused password would be stored unchecked")

    local unreachable = newVerifyRig({ error = "Request timed out" })
    unreachable.verify()
    r.check("an unreachable server is reported as transport, so the pair is stored unchecked",
            #unreachable.results == 1 and unreachable.results[1].status == "transport",
            "got " .. tostring(unreachable.results[1] and unreachable.results[1].status)
                .. " -- as rejected a dead mirror would make credentials impossible to store")
end

-- ---------------------------------------------------------------- the queued action resumes
--
-- Seam 2. An operation that needs an account on a device with none parks itself behind login.
-- Inverting the gate resumes the action when login FAILS and drops it when login SUCCEEDS --
-- the exact opposite of the promise -- with every presence grep still green.
do
    local function newDispatcherRig()
        local rig = {
            ticks = {},
            credentials = false,
            logins = 0,
            login_cb = nil,
            fetches = {},
            resolved = {},
        }
        local env = {
            type = type, tostring = tostring, string = string, table = table,
            T = function(s) return s end,
        }
        env.logger = { err = function() end, info = function() end, warn = function() end }
        env.UIManager = { nextTick = function(_, fn) table.insert(rig.ticks, fn) end }
        env.Config = {
            hasCredentials = function() return rig.credentials end,
            getUserSession = function() return nil end,
        }
        env.NetworkMgr = { willRerunWhenOnline = function() return false end }
        env.Ui = {
            showLoadingMessage = function() return {} end,
            closeMessage = function() end,
            showInfoMessage = function() end,
            showErrorMessage = function() end,
            showRetryErrorDialog = function() end,
            colonConcat = function(a, b) return tostring(a) .. ": " .. tostring(b) end,
        }
        env.Api = { isAuthenticationError = function() return false end }
        env.AsyncHelper = fakeAsyncHelper()

        local body = support.extract_block(MAIN, "(\nfunction Zlibrary%:_requestDispatcher%(.-\n)end\n")
        local chunk = assert(loadstring("local Zlibrary = {}\n" .. body .. "end\nreturn Zlibrary",
                                        "=_requestDispatcher"))
        setfenv(chunk, env)
        local Z = chunk()
        Z.ui = {}
        function Z:login(cb)
            rig.logins = rig.logins + 1
            rig.login_cb = cb
        end

        rig.dispatch = function()
            Z:_requestDispatcher({
                requires_auth = true,
                log_context = "harness",
                loading_text_key = "Loading...",
                error_prefix_key = "Failed",
                api_method = function(user_id, user_key, extra)
                    table.insert(rig.fetches, extra)
                    return { books = { "book" } }
                end,
                resolve_result = function(ui, result)
                    table.insert(rig.resolved, result)
                end,
            }, "extra-arg")
        end
        rig.drainTicks = function()
            local pending = rig.ticks
            rig.ticks = {}
            for _, fn in ipairs(pending) do fn() end
        end
        -- A login that succeeds leaves credentials behind, as the real one does; a failed one
        -- changes nothing.
        rig.answerLogin = function(ok)
            if ok then rig.credentials = true end
            rig.login_cb(ok)
        end
        return rig
    end

    local ok_rig = newDispatcherRig()
    ok_rig.dispatch()
    r.check("an operation needing an account asks for one first", ok_rig.logins == 1,
            "asked " .. ok_rig.logins .. " times")
    r.check("and nothing is fetched while login is unanswered", #ok_rig.fetches == 0,
            "fetched before login answered")

    ok_rig.answerLogin(true)
    ok_rig.drainTicks()
    r.check("a successful login resumes the queued fetch exactly once", #ok_rig.fetches == 1,
            "fetched " .. #ok_rig.fetches .. " times -- an inverted gate drops the action "
                .. "the user just logged in for")
    r.check("with its arguments carried through the round trip", ok_rig.fetches[1] == "extra-arg",
            "got " .. tostring(ok_rig.fetches[1]))
    r.check("and resolves with the fetched result, not a failure",
            #ok_rig.resolved == 1 and type(ok_rig.resolved[1]) == "table"
                and ok_rig.resolved[1].books ~= nil,
            "resolved with " .. tostring(ok_rig.resolved[1]))

    local fail_rig = newDispatcherRig()
    fail_rig.dispatch()
    fail_rig.answerLogin(false)
    fail_rig.drainTicks()
    r.check("a failed login does not run the queued fetch", #fail_rig.fetches == 0,
            "fetched anyway -- an inverted gate resumes the action when login fails")
    r.check("and does not ask for credentials a second time", fail_rig.logins == 1,
            "asked " .. fail_rig.logins .. " times")
    r.check("the caller is released as failed, not left parked",
            #fail_rig.resolved == 1 and fail_rig.resolved[1] == false,
            "resolved " .. #fail_rig.resolved .. " time(s), first "
                .. tostring(fail_rig.resolved[1]))
end

-- ---------------------------------------------------------------- the download resumes
--
-- Seam 3. Download.run holds the same gate on the path that spends the user's quota, and its
-- `if login_ok then` had the same blind spot: inverted, a cancelled login starts the download
-- and a completed one does not.
do
    local function newDownloadRig()
        local rig = { logins = 0, login_cb = nil, downloads = {} }
        -- Only the credentials gate runs in these cases, so the env stops there.
        local env = { Config = { hasCredentials = function() return rig.credentials end } }
        local body = support.extract_block(DOWNLOAD, "(\nfunction Download%.run%(.-\n)end\n")
        -- Download.run is a plain function taking `self`; hand it a stand-in receiver.
        local chunk = assert(loadstring("local Download = {}\n" .. body .. "end\nreturn Download",
                                        "=Download.run"))
        setfenv(chunk, env)
        local run = chunk().run
        rig.receiver = {
            login = function(_, cb) rig.logins = rig.logins + 1; rig.login_cb = cb end,
            downloadBook = function(_, book) table.insert(rig.downloads, book) end,
        }
        rig.start = function(book) run(rig.receiver, book) end
        return rig
    end

    local book = { id = "1", hash = "abc", format = "epub" }

    local ok_rig = newDownloadRig()
    ok_rig.start(book)
    r.check("a download with no account asks for one first", ok_rig.logins == 1,
            "asked " .. ok_rig.logins .. " times")
    r.check("and does not start while login is unanswered", #ok_rig.downloads == 0,
            "started before login answered")

    ok_rig.login_cb(true)
    r.check("a successful login starts the queued download", #ok_rig.downloads == 1,
            "started " .. #ok_rig.downloads
                .. " -- an inverted gate drops the book after a completed login")
    r.check("of the book that was asked for", ok_rig.downloads[1] == book,
            "downloaded the wrong book")

    local fail_rig = newDownloadRig()
    fail_rig.start(book)
    fail_rig.login_cb(false)
    r.check("a failed login does not start the download", #fail_rig.downloads == 0,
            "started anyway -- an inverted gate downloads after a cancelled login")
end

r.finish()
