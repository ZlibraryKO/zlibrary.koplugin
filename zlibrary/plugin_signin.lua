-- Signing in: the one credentials prompt every caller shares, checking typed credentials against the
-- server, and signing in with the stored ones.
--
-- Part of the plugin class. main.lua used to hold all of it in one 1,579-line file; it now copies
-- the methods each part returns onto the class at load (see the end of main.lua). The methods are
-- written exactly as they were there -- `function Zlibrary:name(...)` on this local table -- so
-- `self` is the plugin instance as before. Diff with --color-moved against the commit before the
-- split to see where the code came from.

local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local T = require("zlibrary.gettext")
local Config = require("zlibrary.config")
local Api = require("zlibrary.api")
local Ui = require("zlibrary.ui")
local AsyncHelper = require("zlibrary.async_helper")
local logger = require("logger")

local Zlibrary = {}

-- The first-run credentials prompt, shared by every caller that needs a sign-in.
--
-- File-local rather than an instance field on purpose: main.lua is required once, but KOReader
-- instantiates the plugin per UI (FileManager and ReaderUI). An instance-scoped guard would let
-- the two instances stack two dialogs on top of each other.
--
-- waiters is non-nil exactly while a prompt is on screen; callers arriving during that window
-- queue behind it instead of opening a second one.
local credential_prompt = { waiters = nil, dialog = nil }

-- Check one pair of credentials against the server. Calls on_result(status, message, session)
-- exactly once, with status one of:
--   "ok"        the server accepted them; session carries the user_id/user_key it minted
--   "rejected"  the server read them and said no
--   "transport" no usable answer -- radio off, dead mirror, bot challenge, timeout, rate limit
--
-- Deliberately not routed through Zlibrary:login. On a classified error login reports back only
-- via Ui.showRetryErrorDialog's cancel_callback, and dialog_manager:closeAllDialogs() -- which
-- download.lua fires on Wi-Fi loss -- closes that ConfirmBox straight through UIManager:close
-- without ever running it. A callback dropped there would leave the dialog's button dead for
-- good. AsyncHelper.run, by contrast, always reaches exactly one of its two callbacks.
--
-- It also raises no UI of its own: this runs with the credentials dialog on screen, and a retry
-- ConfirmBox or a Wi-Fi prompt stacked over that dialog is exactly what we are avoiding.
function Zlibrary:_verifyCredentials(email, password, on_result)
    AsyncHelper.run(
        function() return Api.login(email, password) end,
        function(result)
            on_result("ok", nil, { user_id = result.user_id, user_key = result.user_key })
        end,
        function(err_msg)
            if Api.isCredentialRejection(err_msg) then
                on_result("rejected", tostring(err_msg))
            else
                on_result("transport", tostring(err_msg))
            end
        end)
end

-- Ask for credentials, then hand every queued caller the answer.
--
-- on_done(saved) reports whether the config now holds non-empty credentials -- not whether the
-- user pressed Set. That way a Verify-then-Cancel still resumes whatever the user was doing.
function Zlibrary:_promptForCredentials(on_done)
    if credential_prompt.waiters then
        if credential_prompt.dialog and UIManager:isWidgetShown(credential_prompt.dialog) then
            table.insert(credential_prompt.waiters, on_done)
            return
        end
        -- The dialog went away without our close hook running. Rather than wedge the prompt for
        -- the rest of the session, release the stale waiters and start again.
        logger.warn("Zlibrary:_promptForCredentials - stale prompt state; recovering")
        local stale = credential_prompt.waiters
        credential_prompt.waiters, credential_prompt.dialog = nil, nil
        for _, fn in ipairs(stale) do fn(false) end
    end
    credential_prompt.waiters = { on_done }

    local saved, verified, settled = false, false, false
    -- Set synchronously in the close hook, not in settle: a verdict landing between the close and
    -- the tick that runs settle must already know the dialog is gone.
    local closed = false
    local checking = false
    local dialog

    -- my_waiters is captured when the settle is scheduled, not read from the slot at run time:
    -- in the one-tick window after UIManager:close, a new caller can already have passed through
    -- the stale-recovery branch above, which drained these waiters and installed a fresh
    -- prompt's list. A slot that no longer holds our list belongs to that prompt, and draining
    -- it would resolve its callers with this prompt's answer.
    local function settle(my_waiters)
        if settled then return end
        settled = true
        if credential_prompt.waiters ~= my_waiters then return end
        local waiters = my_waiters or {}
        -- Release the slot before dispatching, so a waiter that wants a fresh prompt gets one
        -- instead of queueing behind the prompt that just closed.
        credential_prompt.waiters, credential_prompt.dialog = nil, nil
        for _, fn in ipairs(waiters) do fn(saved, verified) end
    end

    local function store(email, password)
        -- Signing in as a different account must drop the previous one's caches: the
        -- multi_search lists and favourite state are served from cache before any fetch, so
        -- otherwise the new account keeps seeing the old reader's books until the TTLs lapse.
        -- Same reasoning as Config.clearCredentials calling Config.clearPersonalCaches.
        local previous = Config.getSetting(Config.SETTINGS_USERNAME_KEY)
        if previous and previous ~= "" and previous ~= email then
            Config.clearPersonalCaches()
        end
        Config.saveSetting(Config.SETTINGS_USERNAME_KEY, email)
        Config.saveSetting(Config.SETTINGS_PASSWORD_KEY, password)
        saved = true
    end

    -- Keep credentials we could not check, rather than making storage hostage to a server being
    -- reachable. A reader whose only mirror is walled must still be able to type their password
    -- in. The session goes, because it may belong to whoever was signed in before.
    local function storeUnchecked(email, password, notice)
        store(email, password)
        Config.clearUserSession()
        if not closed then
            Ui.closeDialog(dialog)
            if notice then Ui.showInfoMessage(notice) end
        end
    end

    local function submit(email, password)
        -- Ui.showCredentialsDialog has already trimmed these and rejected empty fields.
        if checking then return false end

        -- No connectivity special case on purpose. An earlier version skipped the check when the
        -- radio was off, to avoid a Wi-Fi prompt over the dialog -- but that prompt is the best
        -- thing that can happen here: turning Wi-Fi on is exactly what lets the credentials be
        -- checked, and declining it falls through to the transport branch below, which saves them
        -- unchecked. Both outcomes are already right, so there is nothing to special-case.
        checking = true
        local checking_msg = Ui.showLoadingMessage(T("Logging in..."))

        self:_verifyCredentials(email, password, function(status, message, session)
            checking = false
            Ui.closeMessage(checking_msg)

            if status == "ok" then
                store(email, password)
                -- Keep the session just minted for exactly these credentials; clearing it here
                -- would throw away the sign-in the user has already paid a round trip for.
                Config.saveUserSession(session.user_id, session.user_key)
                verified = true
                -- A verdict can arrive after Cancel, the back key, or closeAllDialogs. The
                -- credentials are proven, so keep them -- a live session with nothing stored
                -- behind it is exactly the state that makes every hasCredentials() gate prompt
                -- again -- but say nothing, because the user has moved on.
                if not closed then
                    Ui.closeDialog(dialog)
                    Ui.showInfoMessage(T("Login successful!"))
                end
                return
            end

            if status == "rejected" then
                -- Store nothing: a password the server refused must not replace one that works.
                -- The dialog stays exactly as it is, with the typo a character from fixed.
                if not closed then Ui.showErrorMessage(message) end
                return
            end

            -- transport. Unlike the ok branch, nothing has proven these credentials, so a
            -- verdict landing after Cancel must change nothing: the stored password and the
            -- session stay exactly as they are, and Cancel keeps meaning "change nothing".
            if closed then return end
            storeUnchecked(email, password, T("Credentials saved, but they could not be checked right now."))
        end)

        -- Never close from here. Either the dialog stays up for a correction, or the callback
        -- above closes it once there is a verdict.
        return false
    end

    dialog = Ui.showCredentialsDialog(submit, nil, { quiet_save = true })

    if not dialog then settle(credential_prompt.waiters) return end
    credential_prompt.dialog = dialog

    -- Resolve on teardown rather than on a button: Cancel, a successful check, the hardware back
    -- key and dialog_manager:closeAllDialogs() all reach UIManager:close, and only this hook sees
    -- all four. Wrap the inherited method, never replace it -- InputDialog:onCloseWidget frees
    -- the input widgets and the virtual keyboard.
    local inherited = dialog.onCloseWidget
    function dialog:onCloseWidget()
        closed = true
        -- Next tick, so a resumed action paints its loading widget after UIManager has finished
        -- tearing this dialog down rather than during it. Capture our waiter list now: by the
        -- time the tick runs, the slot may already belong to a fresh prompt (see settle).
        local my_waiters = credential_prompt.waiters
        UIManager:nextTick(function() settle(my_waiters) end)
        if inherited then return inherited(self) end
    end
end

function Zlibrary:login(callback, opts)
    opts = opts or {}

    -- opts.credentials lets a caller test values the user has typed but not yet stored, so a
    -- failed check cannot overwrite credentials that work.
    local email = opts.credentials and opts.credentials.email
            or Config.getSetting(Config.SETTINGS_USERNAME_KEY)
    local password = opts.credentials and opts.credentials.password
            or Config.getSetting(Config.SETTINGS_PASSWORD_KEY)

    -- Checked before the network gate deliberately. Asking for credentials needs no radio, so a
    -- fresh install is asked for them first rather than being nagged for wifi only to be told it
    -- has no credentials. It also guarantees the willRerunWhenOnline re-entry below always finds
    -- credentials present, so it can never raise a dialog from a detached network event.
    if not email or email == "" or not password or password == "" then
        -- prompted: we have already been round once and they are still missing, so stop rather
        -- than loop. no_prompt: the caller is itself the credentials dialog.
        if opts.no_prompt or opts.prompted then
            Ui.showErrorMessage(T("Please set both username and password first."))
            if callback then callback(false) end
            return
        end
        self:_promptForCredentials(function(did_save, did_verify)
            if not did_save then
                if callback then callback(false) end
                return
            end
            -- Already signed in during the prompt, with a live session for these very
            -- credentials. Repeating the round trip would only cost the user another wait.
            if did_verify then
                if callback then callback(true) end
                return
            end
            self:login(callback, { prompted = true })
        end)
        return
    end

    if NetworkMgr:willRerunWhenOnline(function()
        self:login(callback, opts)
    end) then
        return
    end

    local loading_msg = Ui.showLoadingMessage(T("Logging in..."))

    local task = function()
        return Api.login(email, password)
    end

    local on_success = function(result)
        Ui.closeMessage(loading_msg)

        if result.error then
            Ui.showErrorMessage(result.error)
            if callback then callback(false) end
            return
        end

        Config.saveUserSession(result.user_id, result.user_key)
        if callback then callback(true) end
    end

    local on_error_handler = function(err_msg)
        Ui.showRetryErrorDialog(err_msg, T("Sign-in"), function()
            self:login(callback, opts)
        end, function(final_err_msg)
            if callback then callback(false) end
        end, loading_msg, "login")
    end

    AsyncHelper.run(task, on_success, on_error_handler, loading_msg)
end

return Zlibrary
