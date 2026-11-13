-- Settings dialogs: the download folder, the search-filter pickers, a generic text input, timeouts,
-- items per page, the base-URL list, and the credentials dialog with its clear confirmation.
--
-- Part of the Ui facade (ui.lua); see ui_core.lua. Moved from ui.lua unchanged: diff with
-- --color-moved against the commit before the split to see where it came from.

local UIManager = require("ui/uimanager")
local ConfirmBox = require("ui/widget/confirmbox")
local T = require("zlibrary.gettext")
local DownloadMgr = require("ui/downloadmgr")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("zlibrary.menu")
local util = require("util")
local Config = require("zlibrary.config")
local Ui = require("zlibrary.ui_core")
local Shared = require("zlibrary.ui_shared")
local Pickers = require("zlibrary.ui_pickers")
local _showAndTrackDialog = Shared._showAndTrackDialog
local _closeAndUntrackDialog = Shared._closeAndUntrackDialog
local _showMultiSelectionDialog = Pickers._showMultiSelectionDialog
local _showRadioSelectionDialog = Pickers._showRadioSelectionDialog

local _plugin_instance = nil
Shared.track_plugin_instance(function(instance) _plugin_instance = instance end)

function Ui.showDownloadDirectoryDialog()
    local current_dir = Config.getSetting(Config.SETTINGS_DOWNLOAD_DIR_KEY)
    DownloadMgr:new{
        title = T("Select Z-library Download Directory"),
        onConfirm = function(path)
            if path then
                Config.saveSetting(Config.SETTINGS_DOWNLOAD_DIR_KEY, path)
                Ui.showInfoMessage(string.format(T("Download directory set to: %s"), path))
            else
                Ui.showErrorMessage(T("No directory selected."))
            end
        end,
    }:chooseDir(current_dir)
end

function Ui.showLanguageSelectionDialog(parent_ui)
    _showMultiSelectionDialog(parent_ui, T("Select search languages"), Config.SETTINGS_SEARCH_LANGUAGES_KEY, Config.SUPPORTED_LANGUAGES)
end

function Ui.showExtensionSelectionDialog(parent_ui)
    _showMultiSelectionDialog(parent_ui, T("Select search formats"), Config.SETTINGS_SEARCH_EXTENSIONS_KEY, Config.SUPPORTED_EXTENSIONS)
end

function Ui.showOrdersSelectionDialog(parent_ui, ok_callback)
    local options = { { name = T("Default"), value = "default", is_default = true } }
    for _, option_info in ipairs(Config.SUPPORTED_ORDERS) do
        options[#options + 1] = option_info
    end
    _showRadioSelectionDialog(parent_ui, T("Select search order"), Config.SETTINGS_SEARCH_ORDERS_KEY, options, ok_callback)
end

function Ui.showGenericInputDialog(title, setting_key, current_value_or_default, is_password, validate_and_save_callback, description)
    local dialog

    dialog = InputDialog:new{
        title = title,
        description = description,
        input = current_value_or_default or "",
        text_type = is_password and "password" or nil,
        buttons = {{
            {
                text = T("Cancel"),
                id = "close",
                callback = function() _closeAndUntrackDialog(dialog) end,
            },
            {
                text = T("Set"),
                callback = function()
                    local raw_input = dialog:getInputText() or ""
                    local close_dialog_after_action = false

                    if validate_and_save_callback then
                        if validate_and_save_callback(raw_input, setting_key) then
                            Ui.showInfoMessage(T("Setting saved successfully!"))
                            close_dialog_after_action = true
                        end
                    else
                        local trimmed_input = util.trim(raw_input)
                        if trimmed_input ~= "" then
                            Config.saveSetting(setting_key, trimmed_input)
                            Ui.showInfoMessage(T("Setting saved successfully!"))
                        else
                            Config.deleteSetting(setting_key)
                            Ui.showInfoMessage(T("Setting cleared."))
                        end
                        close_dialog_after_action = true
                    end

                    if close_dialog_after_action then
                        _closeAndUntrackDialog(dialog)
                    end
                end,
            },
        }},
    }
    _showAndTrackDialog(dialog)
    dialog:onShowKeyboard()
    return dialog
end

function Ui.confirmClearCredentials(ok_callback)
    local text = T("Clear your stored username and password?")
    if _plugin_instance and _plugin_instance.dialog_manager then
        _plugin_instance.dialog_manager:showConfirmDialog({
            text = text,
            ok_text = T("Clear"),
            ok_callback = ok_callback,
            cancel_text = T("Cancel")
        })
    else
        UIManager:show(ConfirmBox:new{
            text = text,
            ok_text = T("Clear"),
            ok_callback = ok_callback,
            cancel_text = T("Cancel")
        })
    end
end

function Ui.showTimeoutConfigDialog(parent_ui, timeout_name, timeout_key, getter_func, setter_func, refresh_parent_callback)
    local current_timeout = getter_func()
    local block_timeout = current_timeout[1]
    local total_timeout = current_timeout[2]
    
    local dialog_items = {}
    local dialog_menu
    
    local function refreshDialog()
        local updated_timeout = getter_func()
        block_timeout = updated_timeout[1]
        total_timeout = updated_timeout[2]
        
        dialog_items[1].text = string.format(T("Block timeout: %s"), Config.formatSeconds(block_timeout))
        dialog_items[2].text = string.format(T("Total timeout: %s"), total_timeout == -1 and T("infinite") or Config.formatSeconds(total_timeout))
        
        if dialog_menu then
            dialog_menu.subtitle = Config.formatTimeoutForDisplay(updated_timeout)
            dialog_menu:switchItemTable(dialog_menu.title, dialog_items, -1, nil, dialog_menu.subtitle)
        end
    end
    
    table.insert(dialog_items, {
        text = string.format(T("Block timeout: %s"), Config.formatSeconds(block_timeout)),
        mandatory = "\u{25B7}",
        callback = function()
            Ui.showGenericInputDialog(
                string.format(T("Set %s block timeout (seconds)"), timeout_name),
                nil,
                tostring(block_timeout),
                false,
                function(input_text)
                    local new_block_timeout = tonumber(input_text)
                    if new_block_timeout and new_block_timeout >= 1 then
                        setter_func(new_block_timeout, total_timeout)
                        refreshDialog()
                        return true
                    else
                        Ui.showErrorMessage(T("Please enter a valid number (minimum 1 second)"))
                        return false
                    end
                end
            )
        end
    })
    
    table.insert(dialog_items, {
        text = string.format(T("Total timeout: %s"), total_timeout == -1 and T("infinite") or Config.formatSeconds(total_timeout)),
        mandatory = "\u{25B7}",
        callback = function()
            Ui.showGenericInputDialog(
                string.format(T("Set %s total timeout (seconds, -1 for infinite)"), timeout_name),
                nil,
                tostring(total_timeout),
                false,
                function(input_text)
                    local new_total_timeout = tonumber(input_text)
                    if new_total_timeout and (new_total_timeout >= 1 or new_total_timeout == -1) then
                        setter_func(block_timeout, new_total_timeout)
                        refreshDialog()
                        return true
                    else
                        Ui.showErrorMessage(T("Please enter a valid number (minimum 1 second or -1 for infinite)"))
                        return false
                    end
                end
            )
        end
    })
    
    table.insert(dialog_items, {
        text = "---"
    })
    
    table.insert(dialog_items, {
        text = T("Reset to defaults"),
        -- U+1F5D8 is in no font KOReader bundles; F021 is the refresh glyph used elsewhere.
        mandatory = "\u{F021}",
        callback = function()
            local text = string.format(T("Reset %s timeouts to default values?"), timeout_name)
            local ok_callback = function()
                Config.deleteSetting(timeout_key)
                refreshDialog()
                Ui.showInfoMessage(T("Timeout settings reset to defaults"))
            end
            if _plugin_instance and _plugin_instance.dialog_manager then
                _plugin_instance.dialog_manager:showConfirmDialog({
                    text = text,
                    ok_text = T("Reset"),
                    cancel_text = T("Cancel"),
                    ok_callback = ok_callback
                })
            else
                UIManager:show(ConfirmBox:new{
                    text = text,
                    ok_text = T("Reset"),
                    cancel_text = T("Cancel"),
                    ok_callback = ok_callback
                })
            end
        end
    })
    
    dialog_menu = Menu:new{
        title = string.format(T("%s Timeout Settings"), timeout_name),
        subtitle = Config.formatTimeoutForDisplay(current_timeout),
        item_table = dialog_items,
        parent = parent_ui,
        show_captions = true,
        is_popout = false,
    }
    
    local original_onClose = dialog_menu.onClose
    dialog_menu.onClose = function(self)
        if original_onClose then
            original_onClose(self)
        end
        _closeAndUntrackDialog(self)
        if refresh_parent_callback then
            refresh_parent_callback()
        end
    end
    
    _showAndTrackDialog(dialog_menu)
end

function Ui.showAllTimeoutConfigDialog(parent_ui)
    local timeout_items = {}
    local main_menu
    
    local function refreshMainDialog()
        if main_menu then
            main_menu:updateItems(nil, true)
        end
    end
    
    timeout_items = {
        {
            text = T("Login timeouts"),
            mandatory_func = function()
                return Config.formatTimeoutForDisplay(Config.getLoginTimeout())
            end,
            callback = function()
                Ui.showTimeoutConfigDialog(parent_ui, T("Sign-in"), Config.SETTINGS_TIMEOUT_LOGIN_KEY, 
                    Config.getLoginTimeout, Config.setLoginTimeout, refreshMainDialog)
            end
        },
        {
            text = T("Search timeouts"),
            mandatory_func = function()
                return Config.formatTimeoutForDisplay(Config.getSearchTimeout())
            end,
            callback = function()
                Ui.showTimeoutConfigDialog(parent_ui, T("Book search"), Config.SETTINGS_TIMEOUT_SEARCH_KEY,
                    Config.getSearchTimeout, Config.setSearchTimeout, refreshMainDialog)
            end
        },
        {
            text = T("Book details timeouts"),
            mandatory_func = function()
                return Config.formatTimeoutForDisplay(Config.getBookDetailsTimeout())
            end,
            callback = function()
                Ui.showTimeoutConfigDialog(parent_ui, T("Book details"), Config.SETTINGS_TIMEOUT_BOOK_DETAILS_KEY,
                    Config.getBookDetailsTimeout, Config.setBookDetailsTimeout, refreshMainDialog)
            end
        },
        {
            text = T("Recommended books timeouts"),
            mandatory_func = function()
                return Config.formatTimeoutForDisplay(Config.getRecommendedTimeout())
            end,
            callback = function()
                Ui.showTimeoutConfigDialog(parent_ui, T("Recommended books"), Config.SETTINGS_TIMEOUT_RECOMMENDED_KEY,
                    Config.getRecommendedTimeout, Config.setRecommendedTimeout, refreshMainDialog)
            end
        },
        {
            text = T("Popular books timeouts"),
            mandatory_func = function()
                return Config.formatTimeoutForDisplay(Config.getPopularTimeout())
            end,
            callback = function()
                Ui.showTimeoutConfigDialog(parent_ui, T("Popular books"), Config.SETTINGS_TIMEOUT_POPULAR_KEY,
                    Config.getPopularTimeout, Config.setPopularTimeout, refreshMainDialog)
            end
        },
        {
            text = T("Download timeouts"),
            mandatory_func = function()
                return Config.formatTimeoutForDisplay(Config.getDownloadTimeout())
            end,
            callback = function()
                Ui.showTimeoutConfigDialog(parent_ui, T("Book download"), Config.SETTINGS_TIMEOUT_DOWNLOAD_KEY,
                    Config.getDownloadTimeout, Config.setDownloadTimeout, refreshMainDialog)
            end
        },
        {
            text = T("Cover download timeouts"),
            mandatory_func = function()
                return Config.formatTimeoutForDisplay(Config.getCoverTimeout())
            end,
            callback = function()
                Ui.showTimeoutConfigDialog(parent_ui, T("Cover download"), Config.SETTINGS_TIMEOUT_COVER_KEY,
                    Config.getCoverTimeout, Config.setCoverTimeout, refreshMainDialog)
            end
        },
         {
            text = T("Comments"),
            mandatory_func = function()
                return Config.formatTimeoutForDisplay(Config.getBookCommentsTimeout())
            end,
            callback = function()
                Ui.showTimeoutConfigDialog(parent_ui, T("Comments"), Config.SETTINGS_TIMEOUT_BOOK_COMMENTS_KEY,
                    Config.getBookCommentsTimeout, Config.setBookCommentsTimeout, refreshMainDialog)
            end
        },
        {
            text = "---"
        },
        {
            text = T("Reset all timeouts to defaults"),
            mandatory = "\u{25B7}",
            callback = function()
                local text = T("Reset all timeout settings to default values?")
                local ok_callback = function()
                    Config.deleteSetting(Config.SETTINGS_TIMEOUT_LOGIN_KEY)
                    Config.deleteSetting(Config.SETTINGS_TIMEOUT_SEARCH_KEY)
                    Config.deleteSetting(Config.SETTINGS_TIMEOUT_BOOK_DETAILS_KEY)
                    Config.deleteSetting(Config.SETTINGS_TIMEOUT_RECOMMENDED_KEY)
                    Config.deleteSetting(Config.SETTINGS_TIMEOUT_POPULAR_KEY)
                    Config.deleteSetting(Config.SETTINGS_TIMEOUT_DOWNLOAD_KEY)
                    Config.deleteSetting(Config.SETTINGS_TIMEOUT_COVER_KEY)
                    Config.deleteSetting(Config.SETTINGS_TIMEOUT_BOOK_COMMENTS_KEY)
                    Ui.showInfoMessage(T("All timeout settings reset to defaults"))
                    refreshMainDialog()
                end
                if _plugin_instance and _plugin_instance.dialog_manager then
                    _plugin_instance.dialog_manager:showConfirmDialog({
                        text = text,
                        ok_text = T("Reset All"),
                        cancel_text = T("Cancel"),
                        ok_callback = ok_callback
                    })
                else
                    UIManager:show(ConfirmBox:new{
                        text = text,
                        ok_text = T("Reset All"),
                        cancel_text = T("Cancel"),
                        ok_callback = ok_callback
                    })
                end
            end
        }
    }
    
    main_menu = Menu:new{
        title = T("Timeout Settings"),
        item_table = timeout_items,
        parent = parent_ui,
        show_captions = true,
        is_popout = false,
        title_bar_fm_style = true,
    }
    _showAndTrackDialog(main_menu)
end

function Ui.showUrlCheckProgress(parent_zlibrary, menu_items, close_callback)
    if type(menu_items) ~= "table" then menu_items = {} end
    local menu = Menu:new{
        title = T("Set base URL"),
        item_table = menu_items,
        show_parent = parent_zlibrary.ui,
        is_popout = false,
        is_borderless = true,
        show_captions = true,
        title_bar_fm_style = true,
        single_line = true,
    }
    function menu:onCloseWidget()
        if type(close_callback) == "function" then close_callback() end
        Menu.onCloseWidget(self)
    end
    _showAndTrackDialog(menu)
    return menu
end

function Ui.createPerPageSettingCallback(title_text, setting_key)
    return function()
        local opts = Config.getViewSettings()
        local SpinWidget = require("ui/widget/spinwidget")
        local widget = SpinWidget:new{
            title_text = title_text or "",
            value = opts[setting_key] or 6,
            value_min = 4,
            value_max = 16,
            default_value = 6,
            keep_shown_on_apply = true,
            callback = function(spin)
                opts[setting_key] = tonumber(spin.value)
                Config.setViewSettings(opts)
                Ui.showInfoMessage(T("Setting saved successfully!"))
            end,
        }
        UIManager:show(widget)
    end
end

-- The credentials dialog. One action button: it checks what was typed against the server before
-- keeping it.
--
-- CONTRACT for validate_and_save_callback(email, password):
--   truthy -> done, close the dialog now
--   falsy  -> NOT done, leave the dialog exactly as it is
-- Falsy covers two cases, and the caller knows which: the server refused these credentials and
-- the user should correct them in place, or a check is still in flight and its owner will call
-- Ui.closeDialog when a verdict arrives. Closing on falsy is the bug this contract exists to
-- prevent -- it strands the user with no dialog and no way back except the menu.
--
-- test_callback is unused and kept only so the argument positions do not shift; the separate
-- "Verify credentials" button was removed once the action button started verifying. It differed
-- only in not closing on success, truncated badly as a third button on an Oasis, and committed
-- the credentials on success anyway -- so Cancel after it did not mean "change nothing".
--
-- opts.quiet_save suppresses the "Setting saved successfully!" toast, for callers that paint
-- their own message over the same region straight after.
function Ui.showCredentialsDialog(validate_and_save_callback, test_callback, opts)
    opts = opts or {}
    local current_email = Config.getSetting(Config.SETTINGS_USERNAME_KEY) or ""
    local current_password = Config.getSetting(Config.SETTINGS_PASSWORD_KEY) or ""
    local dialog
    dialog = require("ui/widget/multiinputdialog"):new{
        title = T("Set credentials"),
        fields = {{
                description = T("Email Address"), 
                text = current_email,
                hint = "example@email.com", 
            }, {
                description = T("Password"), 
                text = current_password,
                hint = T("Enter password"), 
                text_type = "password",
            },},
        buttons = { {{
                    text = T("Cancel"),
                    id = "close",
                    callback = function() 
                        _closeAndUntrackDialog(dialog) 
                    end,
                }, {
                    text =  T("Set and verify"),
                    callback = function()
                        local fields = dialog:getFields()
                        local trimmed_email = util.trim(fields[1] or "")
                        local trimmed_password = util.trim(fields[2] or "")
                        if trimmed_email == "" or trimmed_password == "" then
                            Ui.showInfoMessage(T("Please fill in all fields"))
                            return 
                        end
                        local close_dialog_after_action = false
                        if validate_and_save_callback then
                            if validate_and_save_callback(trimmed_email, trimmed_password) then
                                if not opts.quiet_save then
                                    Ui.showInfoMessage(T("Setting saved successfully!"))
                                end
                                close_dialog_after_action = true
                            end
                        else
                            Config.saveSetting(Config.SETTINGS_USERNAME_KEY, trimmed_email)
                            Config.saveSetting(Config.SETTINGS_PASSWORD_KEY, trimmed_password)
                            if not opts.quiet_save then
                                Ui.showInfoMessage(T("Setting saved successfully!"))
                            end
                            close_dialog_after_action = true
                        end
                        if close_dialog_after_action then
                            _closeAndUntrackDialog(dialog)
                        end
                    end,
                },
            },
        },
    }
    _showAndTrackDialog(dialog)
    --dialog:onShowKeyboard()
    return dialog
end

return Ui
