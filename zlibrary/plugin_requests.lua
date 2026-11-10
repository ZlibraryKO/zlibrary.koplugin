-- The request dispatcher every account call and browse list goes through: the account gate, the
-- network gate, the loading message, the one-shot sign-in retry, and the retry dialog.
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

function Zlibrary:_requestDispatcher(options, ...)
    if type(options.resolve_result) ~= "function" then
        logger.err("Zlibrary:%s - Fetch resolve_result undefined", options.log_context)
        return
    end

    -- hasValidApiResult is optional; when set, a result it rejects shows its error message
    -- and resolve_result is not called.
    local has_valid_api_result = type(options.hasValidApiResult) == "function"

    local api_extra_params = {...}

    -- Before the network gate: an operation that needs an account, on a device that has none,
    -- cannot succeed. Asking here rather than waiting for the server to answer "Please login"
    -- saves a doomed round trip, works with the radio off, and does not depend on the server
    -- phrasing its rejection the way Api.isAuthenticationError expects.
    --
    -- Only when there is no account at all. A stored account whose session has gone stale is
    -- still handled reactively below, where the server is the authority on whether it is valid.
    if options.requires_auth and not Config.hasCredentials() then
        self:login(function(login_ok)
            if login_ok then
                self:_requestDispatcher(options, table.unpack(api_extra_params))
            end
        end)
        return
    end

    if NetworkMgr:willRerunWhenOnline(function()
        self:_requestDispatcher(options, table.unpack(api_extra_params))
    end) then
        return
    end

    local function attemptFetch(retry_on_auth_error)
        retry_on_auth_error = retry_on_auth_error == nil and true or retry_on_auth_error

        local user_session = Config.getUserSession()
        -- options.cancellable marks a foreground read the user is staring at (browse lists,
        -- details, comments): it gets a tap-to-cancel loading message and a cancellable run.
        -- Mutations and background work keep the plain blocking run.
        local loading_msg = options.cancellable
            and Ui.showCancellableLoadingMessage(options.loading_text_key)
            or Ui.showLoadingMessage(options.loading_text_key)


        local task = function()
            return options.api_method(user_session and user_session.user_id, user_session and user_session.user_key, table.unpack(api_extra_params))
        end

        local on_success = function(api_result)

            if has_valid_api_result then
                local ok, error_msg = options.hasValidApiResult(api_result)
                if not ok then
                    Ui.closeMessage(loading_msg)
                    Ui.showInfoMessage(error_msg)
                    return
                end
            end
            
            if api_result and api_result.error then
                if retry_on_auth_error and Api.isAuthenticationError(api_result.error) and options.requires_auth then
                    Ui.closeMessage(loading_msg)
                    self:login(function(login_ok)
                        if login_ok then
                            attemptFetch(false)
                        end
                    end)
                    return
                end
                
                Ui.closeMessage(loading_msg)
                Ui.showErrorMessage(Ui.colonConcat(options.error_prefix_key, tostring(api_result.error)))
                return
            end

            Ui.closeMessage(loading_msg)
            logger.info(string.format("Zlibrary:%s - Fetch successful.", options.log_context))
            UIManager:nextTick(function()
                options.resolve_result(self.ui, api_result, self)
            end)
        end

        local on_error_handler = function(err_msg)
            if retry_on_auth_error and Api.isAuthenticationError(err_msg) and options.requires_auth then
                Ui.closeMessage(loading_msg)
                self:login(function(login_ok)
                    if login_ok then
                        attemptFetch(false)
                    end
                end)
                return
            end
            
            -- Use retry dialog for timeout and network errors
            Ui.showRetryErrorDialog(err_msg, options.operation_name or T("Operation"), function()
                -- Retry callback
                attemptFetch(false)
            end, function(final_err_msg)
                -- Cancel callback - user already knows about the error
            end, loading_msg, options.operation_key)
        end

        if options.cancellable then
            AsyncHelper.runCancellable(task, on_success, on_error_handler, loading_msg)
        else
            AsyncHelper.run(task, on_success, on_error_handler, loading_msg)
        end
    end

    attemptFetch()
end

function Zlibrary:_fetchBookList(options, ...)
    options.hasValidApiResult = function(api_result)
        local ok = type(api_result) == "table" and type(api_result.books) == "table" and #api_result.books > 0
        if not ok and type(api_result) == "table" and api_result.filtered then
            return false, T("No books match the selected search languages and formats")
        end
        return ok, not ok and T("No books found, please try again")
    end
    options.resolve_result = function(ui_self, api_result, plugin_self)
        
        self[options.results_member_name] = api_result.books
        options.display_menu_func(ui_self, self[options.results_member_name], plugin_self, api_result)
    end
    self:_requestDispatcher(options, ...)
end  

return Zlibrary
