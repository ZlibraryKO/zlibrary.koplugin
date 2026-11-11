-- The Ui table every ui part fills, and its everyday pieces: the plugin instance, transient messages
-- and loading indicators, the full-text, about, donation, update, cover and simple dialogs, and the
-- retry dialog with its timeout hints.
--
-- zlibrary.ui used to be one 1,950-line module. It is now a facade (ui.lua) over this core and the
-- parts ui_settings, ui_categories, ui_search and ui_books, which all fill this one table; private
-- helpers live in ui_shared and ui_pickers, deliberately not on Ui. Parts require this module, never
-- the facade, so there is no cycle; callers keep requiring zlibrary.ui. The code was moved, not
-- rewritten: diff with --color-moved against the commit before the split to see where it came from.

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local TextViewer = require("ui/widget/textviewer")
local T = require("zlibrary.gettext")
local Device = require("device")
local util = require("util")
local logger = require("logger")
local Config = require("zlibrary.config")
local Api = require("zlibrary.api")

local Ui = {}
local Shared = require("zlibrary.ui_shared")
local _showAndTrackDialog = Shared._showAndTrackDialog
local _closeAndUntrackDialog = Shared._closeAndUntrackDialog
local _colon_concat = Shared._colon_concat

local _plugin_instance = nil
Shared.track_plugin_instance(function(instance) _plugin_instance = instance end)

function Ui.setPluginInstance(plugin_instance)
    Shared.set_plugin_instance(plugin_instance)
end

-- Close a dialog this module opened, from outside it. The credentials dialog needs this: it stays
-- on screen while its contents are checked against the server, so whoever is doing the checking
-- has to close it once a verdict arrives. Goes through the same untracking path as every other
-- close, or the widget stays in DialogManager._open_dialogs and closeAllDialogs re-closes a dead
-- one.
function Ui.closeDialog(dialog)
    _closeAndUntrackDialog(dialog)
end

function Ui.colonConcat(a, b)
    return _colon_concat(a, b)
end

function Ui.showInfoMessage(text)
    if _plugin_instance and _plugin_instance.dialog_manager then
        _plugin_instance.dialog_manager:showInfoMessage(text)
    else
        UIManager:show(InfoMessage:new{ text = text })
    end
end

function Ui.showErrorMessage(text)
    if _plugin_instance and _plugin_instance.dialog_manager then
        _plugin_instance.dialog_manager:showErrorMessage(text)
    else
        UIManager:show(InfoMessage:new{ text = text, icon = "notice-warning", timeout = 5 })
    end
end

function Ui.showLoadingMessage(text)
    -- No force_one_line. To fit one line, InfoMessage shrinks its font and re-runs init(); a
    -- plugin that patches InfoMessage.init to impose its own font (appearance.koplugin does)
    -- resets that font on every re-run, so the loop never ends and KOReader dies with a stack
    -- overflow. Wrapping onto a second line needs no re-run.
    local message = InfoMessage:new{
        text = string.format("\u{23f3}  %s", text),
        dismissable = false,
        show_icon = false,
    }
    UIManager:show(message)
    return message
end

-- A loading message for a request the user can cancel with a tap (see
-- AsyncHelper.runCancellable). The widget itself stays non-dismissable: the tap is caught by the
-- invisible trap widget the cancellable run puts over it.
function Ui.showCancellableLoadingMessage(text)
    return Ui.showLoadingMessage(string.format(T("%s (tap to cancel)"), text))
end

function Ui.showBookDownloadProgress(book, custom_title)
    local title = custom_title or T("Downloading… (tap to cancel)")
    if not (type(book) == "table" and book.filesize) then
        return Ui.showLoadingMessage(title)
    end

    -- KOReader 2025.08 or later required
    local ok, ProgressbarDialog = pcall(require, "ui/widget/progressbardialog")
    if ok and ProgressbarDialog then
        local progressbar_dialog = ProgressbarDialog:new{
            title = title,
            subtitle = string.format("%s %s", book.title, book.size),
            progress_max = book.filesize,
            refresh_time_seconds = 1
        }
        -- fix progress bar fill color on Koreader 2025.08
        if progressbar_dialog.progress_bar then  
            progressbar_dialog.progress_bar.fillcolor = require("ffi/blitbuffer").COLOR_BLACK
        end

        local report_callback = function(progress)
            progressbar_dialog:reportProgress(progress)
        end
        
        progressbar_dialog:show()
        return progressbar_dialog, report_callback
    else
        
        return Ui.showLoadingMessage(title)
    end
end

function Ui.closeMessage(message_widget)
    if message_widget then
        if type(message_widget.close) == "function" then
            message_widget:close()
            -- Ensure complete screen refresh after closing the progress dialog
            -- Use setDirty with "full" to completely redraw the screen area
            UIManager:setDirty("all", "full")
        else
            UIManager:close(message_widget)
        end
    end
end

function Ui.showFullTextDialog(title, full_text)
    local dialog = TextViewer:new{
        title = title,
        text = full_text,
    }
    _showAndTrackDialog(dialog)
end

-- Where the plugin's donation asks point. Kept next to the dialogs that show it so the printed
-- address and the QR code can never drift apart -- the harness pins both to this one constant.
--
-- Ko-fi rather than Buy Me a Coffee: a QR encodes exactly one address, and of the two Ko-fi is
-- the one that takes no cut of a one-off tip. Both are listed in .github/FUNDING.yml and in the
-- README, where there is room for more than one.
local DONATION_URL = "https://ko-fi.com/zlibraryko"

-- A URL is unfollowable on an e-reader: there is no browser to open it in, and copying it off the
-- screen by hand is the sort of thing nobody does. The QR code is the actual path from the device
-- to the page -- scan it with a phone -- and KOReader ships QRMessage for exactly this (its own
-- reader shows web links the same way).
function Ui.showDonationQrCode()
    local QRMessage = require("ui/widget/qrmessage")
    local screen = Device.screen
    local side = math.floor(math.min(screen:getWidth(), screen:getHeight()) * 0.8)
    local dialog = QRMessage:new{
        text = DONATION_URL,
        width = side,
        height = side,
    }
    -- QRMessage closes itself on a tap or a key, and fires dismiss_callback when it does, so it
    -- untracks the same way an InfoMessage does rather than staying in the open-dialog list.
    if _plugin_instance and _plugin_instance.dialog_manager then
        _plugin_instance.dialog_manager:untrackOnClose(dialog)
    end
    _showAndTrackDialog(dialog)
end

-- The only place in the plugin that mentions donations, and deliberately the quietest one: a menu
-- entry nobody has to dismiss, rather than a prompt after a download. Anyone who wants to give
-- currently has to find the README on GitHub, which is not where they are when the plugin has just
-- been useful to them.
function Ui.showAboutDialog(version)
    local text = table.concat({
        string.format("%s %s", T("Z-library plugin"), version or T("(version unknown)")),
        "",
        T("This plugin is maintained in my spare time. Z-library changes without warning -- the sign-in it uses has had to be replaced twice this year -- so keeping search, sign-in and downloads working is ongoing work."),
        "",
        T("If you like the plugin and want it to keep working, the price of a coffee helps:"),
        DONATION_URL,
    }, "\n")

    if _plugin_instance and _plugin_instance.dialog_manager then
        _plugin_instance.dialog_manager:showConfirmDialog({
            title = T("About"),
            text = text,
            ok_text = T("Show QR code"),
            ok_callback = function() Ui.showDonationQrCode() end,
            cancel_text = T("Close"),
        })
    else
        UIManager:show(ConfirmBox:new{
            title = T("About"),
            text = text,
            ok_text = T("Show QR code"),
            ok_callback = function() Ui.showDonationQrCode() end,
            cancel_text = T("Close"),
        })
    end
end

-- Shown once an update has installed. This is the one moment the plugin has earned a word: the
-- reader chose to update, it worked, and they are already being told to restart -- so the ask
-- costs them nothing extra and needs no "shown once" bookkeeping, since a given version installs
-- once. The restart instruction stays first and Close stays the obvious way out; the QR sits on a
-- row above it for anyone who wants it.
--
-- The restart sentence is the exact string the plain message used, so its sixteen translations
-- carry over untouched.
function Ui.showUpdateInstalledDialog()
    local text = table.concat({
        T([[Update installed successfully. Please restart KOReader for changes to take effect.]]),
        "",
        T("If you like the plugin and want it to keep working, the price of a coffee helps:"),
        DONATION_URL,
    }, "\n")

    local qr_row = { { {
        text = T("Show QR code"),
        callback = function() Ui.showDonationQrCode() end,
    } } }

    if _plugin_instance and _plugin_instance.dialog_manager then
        _plugin_instance.dialog_manager:showConfirmDialog({
            title = T("Update installed"),
            text = text,
            no_ok_button = true,
            cancel_text = T("Close"),
            other_buttons = qr_row,
            other_buttons_first = true,
        })
    else
        UIManager:show(ConfirmBox:new{
            title = T("Update installed"),
            text = text,
            no_ok_button = true,
            cancel_text = T("Close"),
            other_buttons = qr_row,
            other_buttons_first = true,
        })
    end
end

function Ui.showCoverDialog(title, img_path)
    -- The emptiness check comes first because util.fileExists cannot do it: it calls io.open,
    -- which raises on a nil path rather than answering false. The path really can be nil by the
    -- time this runs -- the cover the caller was told about may have been evicted from the cache
    -- since, or never landed in it -- and a tap on a cover must not take the UI down.
    if type(img_path) ~= "string" or img_path == "" then
        logger.warn("Ui.showCoverDialog - no cover file to show")
        return
    end
    if not util.fileExists(img_path) then return end
    local ImageViewer = require("ui/widget/imageviewer")
    local dialog = ImageViewer:new{
        file = img_path,
        modal = true,
        with_title_bar = false,
        buttons_visible = false,
        scale_factor = 0
    }
    _showAndTrackDialog(dialog)
end

function Ui.showSimpleMessageDialog(title, text)
    if _plugin_instance and _plugin_instance.dialog_manager then
        _plugin_instance.dialog_manager:showConfirmDialog({
            title = title,
            text = text,
            cancel_text = T("Close"),
            no_ok_button = true,
        })
    else
        local dialog = ConfirmBox:new{
            title = title,
            text = text,
            cancel_text = T("Close"),
            no_ok_button = true,
        }
        UIManager:show(dialog)
    end
end

-- Operations carry a stable, untranslated key. The timeout hint used to be picked by
-- matching English literals ("search", "login") against operation_name, which is already
-- translated -- so outside English nothing ever matched and the hint silently vanished.
local TIMEOUT_GETTERS = {
    search       = Config.getSearchTimeout,
    login        = Config.getLoginTimeout,
    recommended  = Config.getRecommendedTimeout,
    popular      = Config.getPopularTimeout,
    cover        = Config.getCoverTimeout,
    download     = Config.getDownloadTimeout,
    book_details = Config.getBookDetailsTimeout,
    comments     = Config.getBookCommentsTimeout,
}

function Ui.showRetryErrorDialog(err_msg, operation_name, retry_callback, cancel_callback, loading_msg_to_close, operation_key)
    local error_string = tostring(err_msg)
    

    -- The API gives intermittent 400s, so a 400 is worth a retry. Match the text the api layer
    -- actually builds -- T("HTTP Error") .. ": " .. status -- not the English literal: every locale
    -- translates "HTTP Error", and matching "HTTP Error: 400" kept Retry from everyone but English.
    local is_http_400 = string.find(error_string, T("HTTP Error") .. ": 400", 1, true)
    -- The translated needles must be searched as plain text: a locale containing pattern
    -- magic (%, (, -) would throw "malformed pattern" on this error-handling path.
    local is_timeout = string.find(error_string, T("Request timed out"), 1, true) or
                      string.find(error_string, "timeout") or
                      string.find(error_string, "timed out") or
                      string.find(error_string, "sink timeout")
    local is_network_error = string.find(error_string, T("Network connection error"), 1, true) or
                            string.find(error_string, T("Network request failed"), 1, true)
    -- A dead or misspelled base URL never resolves, so retrying alone can only fail again.
    -- Offer auto-discovery alongside Retry, the same way a timeout does.
    local is_dns_error = string.find(error_string, Api.DNS_ERROR_TEXT, 1, true) ~= nil
    -- A mirror behind a bot check will answer the same way however often it is asked, so Retry
    -- alone is useless here. Another server is the only fix, so surface that button.
    local is_blocked = string.find(error_string, Api.BLOCKED_TEXT, 1, true) ~= nil
    local offer_discover = (is_timeout or is_dns_error or is_blocked) and true or nil

    if is_http_400 or is_timeout or is_network_error or is_dns_error or is_blocked then
        local retry_message
        if is_timeout then
            local timeout_info = ""
            local timeout_getter = operation_key and TIMEOUT_GETTERS[operation_key]
            if timeout_getter then
                timeout_info = " (" .. Config.formatSeconds(timeout_getter()[1]) .. ")"
            end
            -- Impersonal on purpose. These used to read "%s failed …", putting the operation
            -- name in subject position, where the predicate has to agree with it. Half the
            -- names are plural ("Comments", "Book details", "Popular books"), so ten of the
            -- fourteen locales disagreed: "Kommentare ist fehlgeschlagen", "Commentaires a
            -- échoué", "Komentarze nie powiodło się". No noun can fix that -- the frame has
            -- to stop making the name a subject.
            retry_message = string.format(T("Could not complete \"%s\" due to a timeout%s. Would you like to retry?"), operation_name, timeout_info)
        elseif is_dns_error then
            retry_message = string.format(T("Could not complete \"%s\" because the server address could not be found. Would you like to retry?"), operation_name)
        elseif is_network_error then
            retry_message = string.format(T("Could not complete \"%s\" due to a network error. Would you like to retry?"), operation_name)
        elseif is_blocked then
            -- Use the error as it stands. It already names the host and says what to do, and it
            -- is not about the operation at all -- the server is walled, so which call hit the
            -- wall is beside the point. Falling through to the generic branch below was worse
            -- than unhelpful: it replaced this with "due to a temporary issue", and this is the
            -- one failure here that is not temporary.
            retry_message = error_string
        else
            retry_message = string.format(T("Could not complete \"%s\" due to a temporary issue. Would you like to retry?"), operation_name)
        end
        
        if _plugin_instance and _plugin_instance.dialog_manager then
            _plugin_instance.dialog_manager:showConfirmDialog({
                text = retry_message,
                ok_text = T("Retry"),
                cancel_text = T("Cancel"),
                ok_callback = function()
                    if loading_msg_to_close then
                        Ui.closeMessage(loading_msg_to_close)
                    end
                    retry_callback()
                end,
                cancel_callback = function()
                    if loading_msg_to_close then
                        Ui.closeMessage(loading_msg_to_close)
                    end
                    cancel_callback(err_msg)
                end,
                other_buttons_first = offer_discover,
                other_buttons = offer_discover and {{{
                    text = string.format("%s&%s",T("Auto-discover base URL"), T("Retry")), 
                    callback = function()  
                        if loading_msg_to_close then  
                            Ui.closeMessage(loading_msg_to_close)  
                        end  
                        _plugin_instance:autoDiscoverAndSetBaseUrl(nil, retry_callback)
                    end  
                }}} or nil,  
            })
        else
            if loading_msg_to_close then
                Ui.closeMessage(loading_msg_to_close)
            end
            Ui.showErrorMessage(error_string)
            cancel_callback(err_msg)
        end
    else
        if loading_msg_to_close then
            Ui.closeMessage(loading_msg_to_close)
        end
        Ui.showErrorMessage(error_string)
        cancel_callback(err_msg)
    end
end

return Ui
