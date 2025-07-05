--[[--
@module zlibrary.dialog_manager

Dialog tracking and cleanup manager for the Z-library plugin.
Handles automatic tracking of open dialogs and ensures proper cleanup
when transitioning between UI states or on plugin exit.
--]]--

local UIManager = require("ui/uimanager")
local logger = require("logger")

local DialogManager = {}

function DialogManager:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o._open_dialogs = {}
    return o
end

function DialogManager:_isDialogValid(dialog)
    if not dialog then
        return false
    end
    if type(dialog) ~= "table" then
        return false
    end

    if dialog.is_destroyed or dialog.is_closed then
        return false
    end

    local success, has_common_properties = pcall(function()
        return dialog.dimen ~= nil or dialog.show_parent ~= nil or dialog.modal ~= nil
    end)

    if not success then
        return false
    end

    return has_common_properties
end

function DialogManager:closeAllDialogs()
    local closed_count = 0
    local error_count = 0
    local cleaned_invalid_count = 0

    for i = #self._open_dialogs, 1, -1 do
        local dialog = self._open_dialogs[i]
        if dialog then
            if self:_isDialogValid(dialog) then
                local success, err = pcall(function()
                    UIManager:close(dialog)
                    closed_count = closed_count + 1
                    logger.dbg("DialogManager: Successfully closed valid dialog", i)
                end)

                if not success then
                    error_count = error_count + 1
                    logger.warn("DialogManager: Failed to close valid dialog", i, "Error:", err)
                end
            else
                cleaned_invalid_count = cleaned_invalid_count + 1
                logger.dbg("DialogManager: Cleaned up invalid/closed dialog", i)
            end
        else
            logger.dbg("DialogManager: Dialog", i, "is nil or already cleaned up")
        end

        self._open_dialogs[i] = nil
    end

    if closed_count > 0 or error_count > 0 or cleaned_invalid_count > 0 then
        logger.info(string.format("DialogManager: Dialog cleanup complete - Closed: %d, Errors: %d, Cleaned invalid: %d",
                                closed_count, error_count, cleaned_invalid_count))
    end
end

function DialogManager:getDialogCount()
    return #self._open_dialogs
end

function DialogManager:showAndTrackDialog(dialog)
    if not dialog then
        logger.warn("DialogManager: Attempted to show nil dialog")
        return nil
    end

    UIManager:show(dialog)
    self:trackDialog(dialog)
    return dialog
end

function DialogManager:closeAndUntrackDialog(dialog)
    if not dialog then
        return
    end

    local success, err = pcall(function()
        UIManager:close(dialog)
    end)

    if not success then
        logger.warn("DialogManager: Failed to close dialog:", err)
    end

    self:untrackDialog(dialog)
end

function DialogManager:showConfirmDialog(options)
    local ConfirmBox = require("ui/widget/confirmbox")

    local dialog = ConfirmBox:new{
        text = options.text or "",
        title = options.title,
        ok_text = options.ok_text or "OK",
        ok_callback = options.ok_callback,
        cancel_text = options.cancel_text or "Cancel",
        cancel_callback = options.cancel_callback,
        other_buttons = options.other_buttons,
        other_buttons_first = options.other_buttons_first,
        no_ok_button = options.no_ok_button,
    }

    return self:showAndTrackDialog(dialog)
end

function DialogManager:showInfoMessage(text, timeout)
    local InfoMessage = require("ui/widget/infomessage")

    local dialog = InfoMessage:new{
        text = text,
        timeout = timeout or 3
    }

    return self:showAndTrackDialog(dialog)
end


function DialogManager:showErrorMessage(text, timeout)
    local InfoMessage = require("ui/widget/infomessage")

    local dialog = InfoMessage:new{
        text = text,
        timeout = timeout or 5
    }

    return self:showAndTrackDialog(dialog)
end


function DialogManager:trackDialog(dialog)
    table.insert(self._open_dialogs, dialog)
    return dialog
end

function DialogManager:untrackDialog(dialog)
    for i, tracked_dialog in ipairs(self._open_dialogs) do
        if tracked_dialog == dialog then
            table.remove(self._open_dialogs, i)
            logger.dbg("DialogManager: Untracked dialog", i)
            break
        end
    end
end

return DialogManager
