-- Does a fresh install ask for credentials instead of dead-ending?
--
-- It used to not. Tapping Search with nothing stored showed "Please set both username and
-- password first." and stopped there, leaving the user to find
-- Menu > Z-library > Settings > Set credentials on their own and then start over.
--
-- Zlibrary:login is the single choke point every credential-needing path goes through, so the
-- prompt lives there. That placement is what makes the hazards worth testing: the plugin is
-- instantiated once per UI (FileManager and ReaderUI), several callers can want a sign-in at
-- once, and a modal that gets stuck open or a callback that never fires both strand the reader.
--
-- Drives the real _promptForCredentials. The counts matter more than the presence: "a dialog
-- appeared" was true of the double-confirmation bug too.

local PLUGIN = assert(arg[1], "usage: luajit first_run_login_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local MAIN = PLUGIN .. "/main.lua"

local function read(path)
    local fh = assert(io.open(path), "cannot open " .. path)
    local s = fh:read("*a"); fh:close(); return s
end

local main_src = read(MAIN)

-- ---------------------------------------------------------------- a rig for the broker
-- The broker is a method, so extract_function (which only knows `local function`) does not
-- apply. Pull the block and give it a table to hang off.
local BROKER_PATTERN = "(\nfunction Zlibrary:_promptForCredentials%(.-\n)end\n"

local function newRig(opts)
    opts = opts or {}
    local rig = {
        dialogs_opened = 0,
        errors_shown = 0,
        info_shown = 0,
        saved = {},
        session_cleared = 0,
        session_saved = 0,
        ticks = {},
        checks = {},
        closes = 0,
        loading_shown = 0,
        loading_closed = 0,
        last_dialog = nil,
        last_opts = nil,
        last_test_cb = "unset",
        inherited_calls = 0,
        widget_shown = true,
        connected = true,
    }

    local env = {
        type = type, ipairs = ipairs, table = table, tostring = tostring,
        T = function(s) return s end,
    }

    env.Config = {
        SETTINGS_USERNAME_KEY = "zlibrary_username",
        SETTINGS_PASSWORD_KEY = "zlibrary_password",
        saveSetting = function(k, v) rig.saved[k] = v end,
        clearUserSession = function() rig.session_cleared = rig.session_cleared + 1 end,
        saveUserSession = function() rig.session_saved = rig.session_saved + 1 end,
    }

    env.NetworkMgr = { isConnected = function() return rig.connected end }

    env.Ui = {
        showInfoMessage = function() rig.info_shown = rig.info_shown + 1 end,
        showErrorMessage = function() rig.errors_shown = rig.errors_shown + 1 end,
        showLoadingMessage = function() rig.loading_shown = rig.loading_shown + 1; return {} end,
        closeMessage = function() rig.loading_closed = rig.loading_closed + 1 end,
        -- Closing for real goes through UIManager:close and so reaches the plugin's own
        -- onCloseWidget wrapper. Model that, or the tests would never exercise settle().
        closeDialog = function(d)
            rig.closes = rig.closes + 1
            if d and d.onCloseWidget then d:onCloseWidget() end
        end,
        showCredentialsDialog = function(save_cb, test_cb, dialog_opts)
            rig.dialogs_opened = rig.dialogs_opened + 1
            rig.last_opts = dialog_opts
            rig.last_test_cb = test_cb
            if opts.dialog_fails then return nil end
            local dialog = {
                save = save_cb,
                -- Stands in for InputDialog:onCloseWidget, which frees the input widgets and the
                -- virtual keyboard. If the plugin replaces it rather than wrapping it, this
                -- counter stays at zero and the keyboard would be left on screen on a device.
                onCloseWidget = function() rig.inherited_calls = rig.inherited_calls + 1 end,
            }
            rig.last_dialog = dialog
            return dialog
        end,
    }

    env.UIManager = {
        nextTick = function(_, fn) table.insert(rig.ticks, fn) end,
        isWidgetShown = function(_, w) return rig.widget_shown and w == rig.last_dialog end,
    }

    env.logger = { warn = function() end, info = function() end, err = function() end }

    -- The file-local the broker coordinates through.
    env.credential_prompt = { waiters = nil, dialog = nil }
    rig.state = env.credential_prompt

    local body = support.extract_block(MAIN, BROKER_PATTERN)
    local chunk = assert(loadstring("local Zlibrary = {}\n" .. body .. "end\nreturn Zlibrary",
                                    "=_promptForCredentials"))
    setfenv(chunk, env)
    local Z = chunk()

    -- The real one talks to the server. Record the request and let each test decide the verdict.
    function Z:_verifyCredentials(email, password, on_result)
        table.insert(rig.checks, { email = email, password = password, resolve = on_result })
    end

    rig.Z = Z
    -- Tap "Set and verify" with what is in the fields.
    rig.submit = function(email, password)
        return rig.last_dialog.save(email or "reader@example.com", password or "hunter2")
    end
    rig.drainTicks = function()
        local pending = rig.ticks
        rig.ticks = {}
        for _, fn in ipairs(pending) do fn() end
    end
    return rig
end

-- ---------------------------------------------------------------- one caller, one dialog
do
    local rig = newRig()
    local results = {}
    rig.Z:_promptForCredentials(function(ok) table.insert(results, ok) end)

    r.check("a caller with no credentials opens exactly one dialog", rig.dialogs_opened == 1,
            "opened " .. rig.dialogs_opened)
    r.check("and shows no error message", rig.errors_shown == 0,
            "showed " .. rig.errors_shown .. " errors")
    r.check("the caller is not resolved while the dialog is still open", #results == 0,
            "resolved " .. #results .. " times early")
    r.check("the dialog is asked to save quietly",
            rig.last_opts ~= nil and rig.last_opts.quiet_save == true,
            "quiet_save was not requested")
end

-- ---------------------------------------------------------- wrong password vs no answer
--
-- The classification that decides everything below. Getting the default backwards -- treating an
-- unrecognised failure as a rejection -- would refuse to store credentials for anyone whose
-- mirror is down, which for this plugin is the common case, not the edge case.
do
    local API = PLUGIN .. "/zlibrary/api.lua"
    local env = { string = string, tostring = tostring, Api = {} }
    env.Api.CREDENTIALS_REJECTED_TEXT = "Credentials rejected or invalid response"

    local body = support.extract_block(API, "(\nfunction Api%.isCredentialRejection%(.-\n)end\n")
    local chunk = assert(loadstring("local Api = ...\n" .. body .. "end\nreturn Api",
                                    "=isCredentialRejection"))
    setfenv(chunk, env)
    local isRejection = chunk(env.Api).isCredentialRejection

    -- The server read them and said no.
    local rejections = {
        { "Login failed: Incorrect email or password", "the server's own wording" },
        { "Please login", "the other wording it uses" },
        { "Login failed: Credentials rejected or invalid response", "our fallback text" },
    }
    for _, case in ipairs(rejections) do
        r.check(string.format("%q is a rejection (%s)", case[1], case[2]),
                isRejection(case[1]) == true, "classified as no-answer, so the typo would be kept")
    end

    -- No answer arrived. Every one of these must keep the credentials, not blame the password.
    local transport = {
        { "Request timed out", "a timeout" },
        { "Could not find the server address", "a dead or misspelled mirror" },
        { "This Z-library server is refusing automated access", "a bot-challenge wall" },
        { "Login failed: Empty response from server", "nothing came back" },
        { "Login failed: Invalid response format", "what a challenge page decodes to" },
        { "Login failed: Invalid session data", "a malformed answer" },
        { "HTTP Error: 500", "the server broke" },
        { "HTTP Error: 429 Too Many Requests", "rate limited -- the password is fine" },
        { "Network connection error", "the radio dropped" },
    }
    for _, case in ipairs(transport) do
        r.check(string.format("%q is NOT a rejection (%s)", case[1], case[2]),
                isRejection(case[1]) == false,
                "an unreachable server would be reported as a wrong password, and the reader "
                .. "could never store credentials until their mirror came back")
    end

    r.check("a missing error is not a rejection", isRejection(nil) == false,
            "nil was treated as a wrong password")

    -- Matched by value, not by English literal: it is a T() string, so a literal match would
    -- hold in one locale out of fourteen.
    local api_src = read(PLUGIN .. "/zlibrary/api.lua")
    r.check("the fallback text is matched by value, not as an English literal",
            api_src:find("string.find(error_str, Api.CREDENTIALS_REJECTED_TEXT", 1, true) ~= nil,
            "a translated build would stop recognising its own rejection message")
    r.check("and isAuthenticationError was left alone",
            api_src:find("function Api.isAuthenticationError", 1, true) ~= nil
                and api_src:find("Incorrect email or password", 1, true) ~= nil,
            "the session re-login path was changed as a side effect")
end

-- ------------------------------------------------- the server refuses: the dialog stays put
--
-- This is the reported bug. Submitting a wrong password used to close the dialog, show a
-- five-second toast and leave the user with no way back except the menu -- the same dead end
-- this feature exists to remove, one step later.
do
    local rig = newRig()
    local results = {}
    rig.Z:_promptForCredentials(function(...) table.insert(results, { ... }) end)

    local closed_now = rig.submit("reader@example.com", "wrong")
    r.check("submitting checks the credentials before keeping them", #rig.checks == 1,
            "ran " .. #rig.checks .. " checks")
    r.check("and stores nothing while the answer is outstanding",
            rig.saved.zlibrary_password == nil, "stored a password before it was checked")
    r.check("and does not close on the spot", not closed_now,
            "the dialog closed synchronously, before any verdict")

    rig.checks[1].resolve("rejected", "Incorrect email or password")
    rig.drainTicks()

    r.check("a refused password is not stored",
            rig.saved.zlibrary_username == nil and rig.saved.zlibrary_password == nil,
            "a password the server refused replaced the stored one")
    r.check("the dialog stays open so the typo can be fixed in place", rig.closes == 0,
            "the dialog closed " .. rig.closes .. " times")
    r.check("the reason is shown exactly once", rig.errors_shown == 1,
            "showed " .. rig.errors_shown)
    r.check("and the waiting caller is left queued, not failed", #results == 0,
            "resolved " .. #results .. " times while the user is still trying")
    r.check("the progress message is taken down", rig.loading_closed == 1,
            "closed " .. rig.loading_closed .. " loading messages")

    -- Correct it and submit again: the same dialog, no second one.
    rig.submit("reader@example.com", "hunter2")
    r.check("a corrected password can be submitted from the same dialog", #rig.checks == 2,
            "ran " .. #rig.checks .. " checks")
    r.check("and no second dialog is opened", rig.dialogs_opened == 1,
            "opened " .. rig.dialogs_opened)
end

-- ---------------------------------------------------------- the server accepts: save and resume
do
    local rig = newRig()
    local results = {}
    rig.Z:_promptForCredentials(function(...) table.insert(results, { ... }) end)

    rig.submit("reader@example.com", "hunter2")
    rig.checks[1].resolve("ok", nil, { user_id = "42", user_key = "abc" })

    r.check("proven credentials are stored",
            rig.saved.zlibrary_username == "reader@example.com"
                and rig.saved.zlibrary_password == "hunter2",
            "stored " .. tostring(rig.saved.zlibrary_username))
    -- The check just minted a session for exactly these credentials. Clearing it would throw
    -- away the round trip the user already waited for.
    r.check("the session it just earned is kept", rig.session_saved == 1,
            "saved " .. rig.session_saved .. " sessions")
    r.check("and not cleared straight afterwards", rig.session_cleared == 0,
            "cleared the fresh session " .. rig.session_cleared .. " times")
    r.check("the dialog closes exactly once", rig.closes == 1, "closed " .. rig.closes)
    r.check("closing wraps the inherited teardown rather than replacing it",
            rig.inherited_calls == 1, "inherited teardown ran " .. rig.inherited_calls .. " times")
    r.check("the resume is deferred to the next tick, not run mid-close", #results == 0,
            "resolved inline from onCloseWidget")

    rig.drainTicks()
    r.check("the caller resolves exactly once", #results == 1, "results: " .. #results)
    r.check("as saved AND verified, so it need not sign in again",
            results[1] and results[1][1] == true and results[1][2] == true,
            "got " .. tostring(results[1] and results[1][1]) .. "/"
                   .. tostring(results[1] and results[1][2]))
end

-- ------------------------------------------- the server cannot be reached: keep them anyway
--
-- Storage must not be hostage to a server being up. A reader whose only mirror is walled still
-- has to be able to type their password in.
do
    local rig = newRig()
    local results = {}
    rig.Z:_promptForCredentials(function(...) table.insert(results, { ... }) end)

    rig.submit("reader@example.com", "hunter2")
    rig.checks[1].resolve("transport", "Request timed out")
    rig.drainTicks()

    r.check("credentials that could not be checked are still stored",
            rig.saved.zlibrary_username == "reader@example.com"
                and rig.saved.zlibrary_password == "hunter2",
            "a reader behind a dead mirror could not store a password")
    r.check("the session is cleared, since it may belong to someone else",
            rig.session_cleared == 1, "cleared " .. rig.session_cleared .. " times")
    r.check("no session is invented for an unchecked account", rig.session_saved == 0,
            "saved " .. rig.session_saved .. " sessions")
    r.check("the dialog closes exactly once", rig.closes == 1, "closed " .. rig.closes)
    r.check("and the user is told it could not be checked", rig.info_shown == 1,
            "showed " .. rig.info_shown .. " notices")
    r.check("the caller resolves as saved but NOT verified, so it signs in when needed",
            #results == 1 and results[1][1] == true and results[1][2] == false,
            "got " .. tostring(results[1] and results[1][1]) .. "/"
                   .. tostring(results[1] and results[1][2]))
end

-- ------------------------------------------------ the radio is off: try anyway, and let KOReader ask
--
-- Deliberately NOT special-cased. An earlier version skipped the check when the radio was off, to
-- avoid a Wi-Fi prompt appearing over the dialog. That was backwards: the prompt is the useful
-- thing here, because turning Wi-Fi on is what lets the credentials actually be checked. Declining
-- it lands in the transport branch, which stores them unchecked -- so both answers are already
-- right and there is nothing to special-case.
do
    local rig = newRig()
    rig.connected = false
    rig.Z:_promptForCredentials(function() end)
    rig.submit("reader@example.com", "hunter2")

    r.check("the check is attempted regardless of what the radio is doing", #rig.checks == 1,
            "ran " .. #rig.checks .. " checks -- a connectivity special case is back")

    local broker = support.extract_block(MAIN, BROKER_PATTERN)
    r.check("and the broker does not test connectivity itself",
            broker:find("isConnected", 1, true) == nil,
            "the broker special-cases the radio again, suppressing the prompt that would let "
            .. "the credentials be checked properly")
end

-- ---------------------------------------------------------------- one check at a time
do
    local rig = newRig()
    rig.Z:_promptForCredentials(function() end)

    rig.submit("reader@example.com", "hunter2")
    rig.submit("reader@example.com", "hunter2")
    r.check("tapping submit twice runs one check, not two", #rig.checks == 1,
            "ran " .. #rig.checks .. " checks")
    r.check("and shows one progress message", rig.loading_shown == 1,
            "showed " .. rig.loading_shown)

    -- Once a verdict lands the button works again.
    rig.checks[1].resolve("rejected", "Incorrect email or password")
    rig.submit("reader@example.com", "hunter3")
    r.check("after a verdict the button works again", #rig.checks == 2,
            "ran " .. #rig.checks .. " checks")
end

-- -------------------------------------------- a verdict that lands after the dialog is gone
do
    local rig = newRig()
    local results = {}
    rig.Z:_promptForCredentials(function(...) table.insert(results, { ... }) end)

    rig.submit("reader@example.com", "hunter2")
    -- The user gave up, pressed back, or download.lua closed everything on Wi-Fi loss.
    rig.last_dialog:onCloseWidget()
    rig.drainTicks()
    local closes_before = rig.closes

    rig.checks[1].resolve("ok", nil, { user_id = "42", user_key = "abc" })
    rig.drainTicks()

    -- A live session with nothing stored behind it is the state that makes every
    -- hasCredentials() gate prompt again, so the proven credentials must still be kept.
    r.check("proven credentials are kept even though the dialog went away",
            rig.saved.zlibrary_password == "hunter2", "the proven credentials were dropped")
    r.check("and the session with them", rig.session_saved == 1,
            "saved " .. rig.session_saved .. " sessions")
    r.check("but nothing is shown to a user who has moved on", rig.info_shown == 0,
            "showed " .. rig.info_shown .. " notices over whatever they are doing now")
    r.check("and a dead dialog is not closed again", rig.closes == closes_before,
            "closed a dialog that was already gone")
    r.check("the caller is still resolved exactly once", #results == 1,
            "resolved " .. #results .. " times")
end

-- ---------------------------------------------------------------- Cancel resolves as unsaved
do
    local rig = newRig()
    local results = {}
    rig.Z:_promptForCredentials(function(ok) table.insert(results, ok) end)

    -- No Set: the user cancelled, pressed back, or dialog_manager closed everything. All four
    -- routes reach the same teardown, which is why the broker hooks there and not on a button.
    rig.last_dialog.onCloseWidget()
    rig.drainTicks()
    r.check("cancelling resolves the caller exactly once, as unsaved",
            #results == 1 and results[1] == false,
            "results: " .. #results .. " first=" .. tostring(results[1]))

    rig.last_dialog.onCloseWidget()
    rig.drainTicks()
    r.check("a second teardown resolves nobody a second time", #results == 1,
            "resolved " .. #results .. " times")
end

-- ---------------------------------------------------------------- concurrent callers queue
do
    local rig = newRig()
    local a, b = {}, {}
    rig.Z:_promptForCredentials(function(ok) table.insert(a, ok) end)
    rig.Z:_promptForCredentials(function(ok) table.insert(b, ok) end)

    -- The plugin is instantiated per UI, so this is not hypothetical.
    r.check("a second caller does not open a second dialog", rig.dialogs_opened == 1,
            "opened " .. rig.dialogs_opened .. " dialogs")

    rig.submit("reader@example.com", "hunter2")
    rig.checks[1].resolve("ok", nil, { user_id = "42", user_key = "abc" })
    rig.drainTicks()
    r.check("both queued callers resolve exactly once each",
            #a == 1 and #b == 1, string.format("a=%d b=%d", #a, #b))
    r.check("both queued callers see the same outcome",
            a[1] == true and b[1] == true, string.format("a=%s b=%s", tostring(a[1]), tostring(b[1])))
end

-- ---------------------------------------------------------------- the slot is released first
do
    -- A waiter that immediately wants another prompt must get one. If the broker dispatched
    -- before clearing its slot, that waiter would queue behind a dialog that no longer exists
    -- and never hear back -- a wedge that lasts the rest of the session.
    local rig = newRig()
    local second = {}
    rig.Z:_promptForCredentials(function()
        rig.Z:_promptForCredentials(function(ok) table.insert(second, ok) end)
    end)
    rig.last_dialog.onCloseWidget()
    rig.drainTicks()

    r.check("a waiter that re-asks during dispatch gets a fresh dialog", rig.dialogs_opened == 2,
            "opened " .. rig.dialogs_opened .. " dialogs")
    r.check("and is not left unresolved", rig.state.waiters ~= nil or #second == 1,
            "the re-ask was dropped")
end

-- ---------------------------------------------------------------- stale state recovers
do
    local rig = newRig()
    local first = {}
    rig.Z:_promptForCredentials(function(ok) table.insert(first, ok) end)

    -- The dialog vanished without the close hook running. Rather than refuse to prompt for the
    -- rest of the session, the broker should release the stale waiters and start over.
    rig.widget_shown = false
    local second = {}
    rig.Z:_promptForCredentials(function(ok) table.insert(second, ok) end)

    r.check("a stale prompt state does not wedge the prompt", rig.dialogs_opened == 2,
            "opened " .. rig.dialogs_opened .. " dialogs")
    r.check("the stranded caller is released as unsaved",
            #first == 1 and first[1] == false,
            "first: " .. #first .. " " .. tostring(first[1]))
end

-- ---------------------------------------------------------------- a dialog that never opened
do
    local rig = newRig({ dialog_fails = true })
    local results = {}
    rig.Z:_promptForCredentials(function(ok) table.insert(results, ok) end)
    r.check("a dialog that could not be created still resolves its caller",
            #results == 1 and results[1] == false,
            "results: " .. #results)
    r.check("and leaves no state behind to block the next attempt",
            rig.state.waiters == nil and rig.state.dialog == nil,
            "prompt state was left populated")
end

-- --------------------------------------------------- the separate Verify button is gone
do
    local rig = newRig()
    rig.Z:_promptForCredentials(function() end)

    -- The action button verifies now, so a second button that only differed by not closing was
    -- redundant. It also committed the credentials on success, which meant Cancel afterwards did
    -- not mean "change nothing" -- with one button, what gets stored is always the pair just
    -- submitted.
    r.check("the broker passes no separate verify callback", rig.last_test_cb == nil,
            "a test_callback is still being wired up")

    local ui_src = read(PLUGIN .. "/zlibrary/ui.lua")
    local body = ("\n" .. ui_src):match("(\nfunction Ui%.showCredentialsDialog%(.-\n)end\n")
    r.check("the credentials dialog body can be located", body ~= nil)
    if body then
        local buttons = select(2, body:gsub('text = *T%("', ""))
        r.check("the dialog offers exactly two buttons", buttons == 2,
                "found " .. buttons .. " -- three truncate on an Oasis")
        r.check("and the action button says it verifies",
                body:find('T("Set and verify")', 1, true) ~= nil,
                "the action button does not say it checks anything")
        r.check("the old Verify credentials button is gone",
                body:find('T("Verify credentials")', 1, true) == nil,
                "the redundant button is still there")
    end
end

-- ---------------------------------------------------------------- and the login it hangs off
-- The broker above is the hazardous part, but the branch that decides whether to reach it at all
-- lives in Zlibrary:login. Greping main.lua for the literals in that branch is not coverage:
-- inverting `if not did_save then` leaves every literal intact, ships green, and silently
-- restores the dead end this whole change removes. So drive the real function.
local LOGIN_PATTERN = "(\nfunction Zlibrary:login%(.-\n)end\n"

local function newLoginRig(cfg)
    cfg = cfg or {}
    local rig = {
        prompts = 0,
        errors_shown = 0,
        logins_started = 0,
        prompt_done = nil,
        wifi_reruns = {},
        callbacks = {},
        recursed = {},
    }

    local env = {
        type = type, ipairs = ipairs, table = table, tostring = tostring,
        T = function(s) return s end,
    }

    env.Config = {
        SETTINGS_USERNAME_KEY = "zlibrary_username",
        SETTINGS_PASSWORD_KEY = "zlibrary_password",
        getSetting = function(k)
            if k == "zlibrary_username" then return cfg.email end
            return cfg.password
        end,
        saveUserSession = function() end,
    }
    env.Ui = {
        showErrorMessage = function() rig.errors_shown = rig.errors_shown + 1 end,
        showLoadingMessage = function() return {} end,
        closeMessage = function() end,
        showRetryErrorDialog = function() end,
    }
    -- Returning true means "not online yet, I will re-run your closure later".
    env.NetworkMgr = {
        willRerunWhenOnline = function(_, rerun)
            table.insert(rig.wifi_reruns, rerun)
            return cfg.offline == true
        end,
    }
    env.Api = { login = function() return {} end }
    -- Reaching here means the credential branch let the request through.
    env.AsyncHelper = { run = function() rig.logins_started = rig.logins_started + 1 end }
    env.logger = { warn = function() end, info = function() end, err = function() end }

    local body = support.extract_block(MAIN, LOGIN_PATTERN)
    local chunk = assert(loadstring("local Zlibrary = {}\n" .. body .. "end\nreturn Zlibrary",
                                    "=login"))
    setfenv(chunk, env)
    local Z = chunk()

    function Z:_promptForCredentials(on_done)
        rig.prompts = rig.prompts + 1
        rig.prompt_done = on_done
    end

    -- The real broker writes the credentials before it reports saved, so a faithful stub must
    -- too -- otherwise "saved" and "the settings write silently failed" are the same state and
    -- the resume looks broken when it is working.
    rig.resolvePrompt = function(saved, storage_failed)
        if saved and not storage_failed then
            cfg.email, cfg.password = "reader@example.com", "hunter2"
        end
        rig.prompt_done(saved)
    end

    -- Watch the self-recursion without losing the real implementation.
    local real_login = Z.login
    function Z:login(callback, opts)
        table.insert(rig.recursed, opts)
        return real_login(self, callback, opts)
    end
    rig.Z = Z
    rig.call = function(callback, opts)
        table.remove(rig.recursed) -- the outermost call is not a recursion
        return real_login(Z, callback, opts)
    end
    return rig
end

do
    local rig = newLoginRig({ email = nil, password = nil })
    local results = {}
    rig.call(function(ok) table.insert(results, ok) end)

    r.check("login with no credentials opens exactly one prompt", rig.prompts == 1,
            "opened " .. rig.prompts)
    r.check("and shows no dead-end error", rig.errors_shown == 0,
            "showed " .. rig.errors_shown)
    r.check("and does not sign in yet", rig.logins_started == 0, "started a sign-in")
    r.check("and does not resolve the caller yet", #results == 0, "resolved early")
end

do
    -- The feature, in one assertion: credentials entered, the interrupted action resumes.
    local rig = newLoginRig({ email = nil, password = nil })
    local results = {}
    rig.call(function(ok) table.insert(results, ok) end)
    rig.resolvePrompt(true)

    r.check("a saved prompt re-enters login exactly once", #rig.recursed == 1,
            "re-entered " .. #rig.recursed .. " times")
    r.check("and the re-entry is capped so it cannot prompt again",
            rig.recursed[1] and rig.recursed[1].prompted == true,
            "the retry did not carry prompted=true")
    r.check("and the interrupted action resumes into a real sign-in", rig.logins_started == 1,
            "started " .. rig.logins_started .. " sign-ins -- the resume is the whole feature")
    r.check("and the caller is not failed on the way", #results == 0,
            "callback(false) fired despite a successful save")
    r.check("and no second prompt appears", rig.prompts == 1, "opened " .. rig.prompts)
end

do
    -- The settings write silently failed -- read-only settings, a flush that did not land. The
    -- credentials are still missing on re-entry, and the cap is what stops this becoming an
    -- unbreakable modal cycle on a device.
    local rig = newLoginRig({ email = nil, password = nil })
    local results = {}
    rig.call(function(ok) table.insert(results, ok) end)
    rig.resolvePrompt(true, true)

    r.check("a save that did not stick degrades to the original message, once",
            rig.errors_shown == 1, "showed " .. rig.errors_shown)
    r.check("and does not prompt again", rig.prompts == 1,
            "opened " .. rig.prompts .. " prompts -- this is the loop the cap exists to stop")
    r.check("and resolves the caller as failed exactly once",
            #results == 1 and results[1] == false, "results: " .. #results)
end

do
    local rig = newLoginRig({ email = nil, password = nil })
    local results = {}
    rig.call(function(ok) table.insert(results, ok) end)
    rig.prompt_done(false)

    r.check("a cancelled prompt resolves the caller exactly once, as failed",
            #results == 1 and results[1] == false,
            "results: " .. #results .. " first=" .. tostring(results[1]))
    r.check("and does not re-enter login", #rig.recursed == 0,
            "re-entered " .. #rig.recursed .. " times")
    r.check("and does not show the error the user just declined to answer",
            rig.errors_shown == 0, "showed " .. rig.errors_shown)
end

for _, cap in ipairs({ "no_prompt", "prompted" }) do
    local rig = newLoginRig({ email = nil, password = nil })
    local results = {}
    rig.call(function(ok) table.insert(results, ok) end, { [cap] = true })

    r.check(cap .. " opens no prompt", rig.prompts == 0, "opened " .. rig.prompts)
    r.check(cap .. " falls back to the original message exactly once", rig.errors_shown == 1,
            "showed " .. rig.errors_shown)
    r.check(cap .. " resolves the caller as failed exactly once",
            #results == 1 and results[1] == false, "results: " .. #results)
end

do
    local rig = newLoginRig({ email = "reader@example.com", password = "hunter2" })
    rig.call(function() end)
    r.check("with credentials stored, login proceeds to sign in", rig.logins_started == 1,
            "started " .. rig.logins_started .. " sign-ins")
    r.check("and opens no prompt", rig.prompts == 0, "opened " .. rig.prompts)
    r.check("and consults the network gate", #rig.wifi_reruns == 1,
            "consulted the network gate " .. #rig.wifi_reruns .. " times")
end

do
    -- Ordering, behaviourally rather than by string index: with no credentials the network gate
    -- must not be reached at all, so a fresh install is never nagged for wifi purely to be told
    -- it has none.
    local rig = newLoginRig({ email = nil, password = nil, offline = true })
    rig.call(function() end)
    r.check("no credentials means the wifi gate is never reached", #rig.wifi_reruns == 0,
            "asked for wifi " .. #rig.wifi_reruns .. " time(s) before asking for credentials")
    r.check("the credentials prompt is what appears instead", rig.prompts == 1,
            "opened " .. rig.prompts)
end

do
    -- The caps must survive a wifi round trip: willRerunWhenOnline re-runs the closure later.
    local rig = newLoginRig({ email = "reader@example.com", password = "hunter2", offline = true })
    rig.call(function() end, { prompted = true })
    r.check("going offline defers the sign-in", rig.logins_started == 0, "signed in while offline")
    r.check("and the deferred re-run was registered", #rig.wifi_reruns == 1,
            "registered " .. #rig.wifi_reruns)

    rig.wifi_reruns[1]()
    r.check("the deferred re-run carries the original opts through",
            rig.recursed[1] and rig.recursed[1].prompted == true,
            "opts were dropped across the wifi round trip, uncapping the recursion")
end

-- ---------------------------------------------------------------- who has to sign in, and when
--
-- The search endpoint answers without credentials -- Api.search attaches the cookie only
-- `if user_id and user_key` -- so a fresh install can search, and never reaches Zlibrary:login
-- that way. This was originally assumed to be the trigger and is not. What genuinely needs an
-- account asks for one up front, instead of firing a request that cannot succeed and waiting for
-- the server to answer "Please login".
do
    local dispatcher = support.extract_block(MAIN,
        "(\nfunction Zlibrary:_requestDispatcher%(.-\n)end\n")

    local gate = dispatcher:find("options.requires_auth and not Config.hasCredentials()", 1, true)
    local wifi = dispatcher:find("NetworkMgr:willRerunWhenOnline", 1, true)
    r.check("an operation needing an account checks for one", gate ~= nil,
            "the dispatcher fires the request regardless and waits to be rejected")
    r.check("and asks before it asks for wifi", gate ~= nil and wifi ~= nil and gate < wifi,
            "the radio is brought up for a request that cannot succeed")

    -- Reactive handling must stay: a stored account whose session went stale is a different
    -- case, and there the server is the authority.
    r.check("a stale session is still recovered reactively",
            dispatcher:find("Api.isAuthenticationError", 1, true) ~= nil,
            "removing the reactive path breaks re-login for an expired session")

    r.check("a download asks for an account before starting",
            read(PLUGIN .. "/zlibrary/download.lua"):find("not Config.hasCredentials()", 1, true) ~= nil,
            "a download on a fresh install fails at the server instead of asking")
end

do
    -- Guard the deliberate exception. Making search require an account would be a regression:
    -- browsing before signing in works today and is worth keeping.
    local search = support.extract_block(MAIN, "(\nfunction Zlibrary:performSearch%(.-\n)end\n")
    r.check("search does not require an account",
            search:find("hasCredentials", 1, true) == nil,
            "search now demands credentials -- it works without them, and being able to browse "
            .. "before signing in is deliberate")

    local api_src = read(PLUGIN .. "/zlibrary/api.lua")
    local search_fn = ("\n" .. api_src):match("(\nfunction Api%.search%(.-\n)end\n")
    r.check("and sends credentials only when there are some",
            search_fn ~= nil and search_fn:find("if user_id and user_key then", 1, true) ~= nil,
            "Api.search no longer treats the cookie as optional")
end

-- ---------------------------------------------------------------- clearing the account
do
    -- Clearing only the session was the old behaviour and it is not a sign-out: the credentials
    -- stay, and the plugin signs straight back in on the next request.
    local deleted = {}
    local env = {
        Config = {
            SETTINGS_USERNAME_KEY = "zlibrary_username",
            SETTINGS_PASSWORD_KEY = "zlibrary_password",
            SETTINGS_USER_ID_KEY = "zlibrary_user_id",
            SETTINGS_USER_KEY_KEY = "zlibrary_user_key",
            deleteSetting = function(k) deleted[k] = true end,
        },
    }
    env.Config.clearUserSession = function()
        env.Config.deleteSetting(env.Config.SETTINGS_USER_ID_KEY)
        env.Config.deleteSetting(env.Config.SETTINGS_USER_KEY_KEY)
    end

    local caches_cleared = 0
    env.Config.clearPersonalCaches = function() caches_cleared = caches_cleared + 1 end

    local body = support.extract_block(PLUGIN .. "/zlibrary/config.lua",
                                       "(\nfunction Config%.clearCredentials%(%).-\n)end\n")
    local chunk = assert(loadstring("local Config = ...\n" .. body .. "end\nreturn Config",
                                    "=clearCredentials"))
    setfenv(chunk, env)
    chunk(env.Config).clearCredentials()

    for _, key in ipairs({ "zlibrary_username", "zlibrary_password",
                           "zlibrary_user_id", "zlibrary_user_key" }) do
        r.check("clearing the account forgets " .. key, deleted[key] == true,
                key .. " survived -- the plugin would sign back in with it")
    end
    -- Signing out while the previous reader's lists survive shows them to the next person.
    r.check("clearing the account also drops the data cached for it", caches_cleared == 1,
            "clearPersonalCaches ran " .. caches_cleared .. " times")
end

do
    -- Which caches belong to the reader, and which belong to everybody.
    local removed = { runtime = {}, multi_search = {} }
    local env = { ipairs = ipairs, Config = {} }
    env.Config.getConfigRuntimeCache = function()
        return { remove = function(_, k) removed.runtime[k] = true end }
    end
    env.Cache = {
        new = function(_, opts)
            local bucket = removed[opts.name] or {}
            removed[opts.name] = bucket
            return { remove = function(_, k) bucket[k] = true end }
        end,
    }

    local body = support.extract_block(PLUGIN .. "/zlibrary/config.lua",
                                       "(\nfunction Config%.clearPersonalCaches%(%).-\n)end\n")
    local chunk = assert(loadstring("local Config = ...\n" .. body .. "end\nreturn Config",
                                    "=clearPersonalCaches"))
    setfenv(chunk, env)
    chunk(env.Config).clearPersonalCaches()

    for _, key in ipairs({ "download_quota_status", "favorite_book_ids" }) do
        r.check("signing out drops the cached " .. key, removed.runtime[key] == true,
                key .. " survived the sign-out")
    end
    for _, key in ipairs({ "recommended", "favorites", "downloaded" }) do
        r.check("signing out drops the cached " .. key .. " list",
                removed.multi_search[key] == true,
                key .. " survived -- the next reader would see the previous one's books")
    end

    -- Popular is fetched with requires_auth = false, so it is the same list for every reader.
    -- Dropping it would just cost a refetch of public data.
    r.check("but keeps popular, which is the same for everyone",
            removed.multi_search["popular"] == nil,
            "popular was cleared needlessly")
end

do
    -- Nothing may be cleared until the user has confirmed, and the message must not claim a
    -- clearing that the credentials file is about to undo.
    local CALLBACK = "(Ui%.confirmClearCredentials%(function%(%).-\n%s+end%))"
    local body = support.extract_block(MAIN, CALLBACK)

    local function runClear(confirm, from_file)
        local seen = { cleared = 0, messages = {} }
        local env = {
            string = string,
            T = function(s) return s end,
            Config = {
                CREDENTIALS_FILENAME = "zlibrary_credentials.lua",
                clearCredentials = function() seen.cleared = seen.cleared + 1 end,
                credentialsComeFromFile = function() return from_file end,
            },
            Ui = {
                confirmClearCredentials = function(ok) if confirm then ok() end end,
                showInfoMessage = function(m) table.insert(seen.messages, m) end,
            },
        }
        local chunk = assert(loadstring("return function()\n" .. body .. "\nend", "=clearMenu"))
        setfenv(chunk, env)
        chunk()()
        return seen
    end

    -- The rig only sees inside the confirmation callback, so a second call placed outside it
    -- would clear on Cancel and stay invisible here. Count the call sites in the whole file.
    local call_sites = select(2, main_src:gsub("Config%.clearCredentials%(%)", ""))
    r.check("the account is cleared from exactly one place", call_sites == 1,
            "found " .. call_sites .. " calls to Config.clearCredentials() -- one outside the "
            .. "confirmation would clear on Cancel")

    local cancelled = runClear(false, false)
    r.check("declining the confirmation clears nothing", cancelled.cleared == 0,
            "cleared " .. cancelled.cleared .. " times without consent")
    r.check("and says nothing", #cancelled.messages == 0,
            "reported " .. #cancelled.messages .. " message(s)")

    local confirmed = runClear(true, false)
    r.check("confirming clears exactly once", confirmed.cleared == 1,
            "cleared " .. confirmed.cleared .. " times")
    r.check("and reports it exactly once", #confirmed.messages == 1,
            "reported " .. #confirmed.messages .. " message(s)")

    local from_file = runClear(true, true)
    r.check("a credentials file still clears the settings and session", from_file.cleared == 1,
            "cleared " .. from_file.cleared .. " times")
    r.check("but the message names the file that will put them back",
            from_file.messages[1] and from_file.messages[1]:find("zlibrary_credentials.lua", 1, true) ~= nil,
            "reported: " .. tostring(from_file.messages[1]))
    r.check("and does not claim a plain success",
            from_file.messages[1] ~= confirmed.messages[1],
            "the same message is shown whether or not the file will undo the clearing")
end

-- ---------------------------------------------------------------- wiring, checked by count
do
    local verify_entries = select(2, main_src:gsub('text = T%("Verify credentials"%)', ""))
    r.check("the redundant Verify credentials menu entry is gone", verify_entries == 0,
            "found " .. verify_entries .. " -- verification belongs to the credentials dialog now")

    -- Verification did not disappear with the menu entry and then with the second button; it
    -- moved into the action button, which is the only way credentials get stored now.
    r.check("submitting is what verifies",
            main_src:find("self:_verifyCredentials(email, password", 1, true) ~= nil,
            "nothing checks the credentials on submit, so a typo is stored silently again")

    local advanced = select(2, main_src:gsub('text = T%("Advanced"%)', ""))
    r.check("Developer options is now Advanced", advanced == 1, "found " .. advanced)
    r.check("and nothing still calls it Developer options",
            main_src:find("Developer options", 1, true) == nil,
            "the old label is still present")
end

r.check("the prompt state is a file-local, not an instance field",
        main_src:match("\nlocal credential_prompt%s*=") ~= nil,
        "credential_prompt is not declared at file scope -- two plugin instances could each "
        .. "hold their own and stack two dialogs")

do
    -- Ordering matters: asking for credentials needs no radio. Checking after the network gate
    -- means a fresh install with wifi off is nagged to connect purely to be told it has no
    -- credentials, and the modal then arrives from a detached network event.
    local login = main_src:match("(\nfunction Zlibrary:login%(.-\n)end\n")
    local cred_at = login and login:find("SETTINGS_USERNAME_KEY", 1, true)
    local wifi_at = login and login:find("willRerunWhenOnline", 1, true)
    r.check("login checks for credentials before it asks for wifi",
            cred_at ~= nil and wifi_at ~= nil and cred_at < wifi_at,
            string.format("credentials at %s, wifi gate at %s", tostring(cred_at), tostring(wifi_at)))
end

r.check("the retry after saving cannot prompt again",
        main_src:find("self:login(callback, { prompted = true })", 1, true) ~= nil,
        "the post-save retry does not carry prompted=true, so a settings write that silently "
        .. "failed would loop the dialog")

r.check("an already-prompted login falls back to the original message",
        main_src:match("opts%.no_prompt or opts%.prompted") ~= nil,
        "the recursion is not capped by a flag")

do
    -- One credentials dialog in the plugin. The old Settings entry called showCredentialsDialog
    -- inline with a test_callback that took no parameters, so it verified whatever was already
    -- stored and discarded what the user had just typed.
    --
    -- Counts calls, not mentions: the trailing "(" is what keeps the explanatory comment beside
    -- the call from being counted as a second call site.
    local calls = select(2, main_src:gsub("Ui%.showCredentialsDialog%(", ""))
    r.check("main.lua opens the credentials dialog from exactly one place", calls == 1,
            "found " .. calls .. " call sites")

    local broker = support.extract_block(MAIN, BROKER_PATTERN)
    r.check("and that place is the broker",
            broker:find("Ui.showCredentialsDialog(", 1, true) ~= nil,
            "the only call site is outside _promptForCredentials")
end

do
    -- Scoped to the credentials dialog: the same toast is used by unrelated settings dialogs
    -- elsewhere in ui.lua, which have no reason to be quiet.
    local ui_src = "\n" .. read(PLUGIN .. "/zlibrary/ui.lua")
    local body = ui_src:match("(\nfunction Ui%.showCredentialsDialog%(.-\n)end\n")
    r.check("the credentials dialog body can be located", body ~= nil)
    if body then
        local toasts = select(2, body:gsub("Ui%.showInfoMessage%(T%(\"Setting saved successfully!", ""))
        local guards = select(2, body:gsub("if not opts%.quiet_save then", ""))
        r.check("every save toast in the credentials dialog respects quiet_save",
                toasts > 0 and guards == toasts,
                string.format("%d toast(s) but %d guard(s)", toasts, guards))
        r.check("the dialog accepts an opts table", body:find("opts = opts or {}", 1, true) ~= nil,
                "opts is not defaulted, so a two-argument caller would index a nil")
    end
end

-- Background cache warming must never reach the plugin's login: it would throw a modal at a
-- reader who is reading. Counted, because a comment alone does not fail a build.
for _, mod in ipairs({ "preloader", "discovery" }) do
    local src = read(PLUGIN .. "/zlibrary/" .. mod .. ".lua")
    -- Zlibrary:login is reached as `:login(`; Api.login is a different, dialog-free call.
    local hits = select(2, src:gsub(":login%(", ""))
    r.check(mod .. ".lua never routes through the plugin's login", hits == 0,
            mod .. ".lua calls :login( " .. hits .. " time(s) -- background work would now "
            .. "raise a credentials dialog")
end

r.finish()
