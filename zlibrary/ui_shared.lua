-- Helpers the Ui parts share, kept off the public Ui table: showing and closing a dialog through the
-- plugin's DialogManager (so closeAllDialogs can find it), the "a: b" join, and the plugin instance.
--
-- The plugin instance is the one piece of mutable state the parts share. Ui.setPluginInstance sets
-- it once, from the plugin's init, and code all over the parts reads it as `_plugin_instance`. Each
-- part keeps its own local of that name and registers a setter here, so every read stays exactly as
-- it was written in the single ui.lua -- and a harness that hands an extracted block its own
-- `_plugin_instance` still can. set_plugin_instance updates every registered local at once.

local UIManager = require("ui/uimanager")

local Shared = {}

local _plugin_instance = nil
local _instance_setters = {}

-- A part's `local _plugin_instance`, kept current from now on (and set to the current value now).
function Shared.track_plugin_instance(set)
    _instance_setters[#_instance_setters + 1] = set
    set(_plugin_instance)
end

-- Called by Ui.setPluginInstance: every part's local, and this module's own, see the new instance.
function Shared.set_plugin_instance(instance)
    _plugin_instance = instance
    for _, set in ipairs(_instance_setters) do set(instance) end
end

local function _showAndTrackDialog(dialog)
    if _plugin_instance and _plugin_instance.dialog_manager then
        return _plugin_instance.dialog_manager:showAndTrackDialog(dialog)
    else
        UIManager:show(dialog)
        return dialog
    end
end

local function _closeAndUntrackDialog(dialog)
    if _plugin_instance and _plugin_instance.dialog_manager then
        _plugin_instance.dialog_manager:closeAndUntrackDialog(dialog)
    else
        if dialog then
            UIManager:close(dialog)
        end
    end
end

local function _colon_concat(a, b)
    return a .. ": " .. b
end

Shared._showAndTrackDialog = _showAndTrackDialog
Shared._closeAndUntrackDialog = _closeAndUntrackDialog
Shared._colon_concat = _colon_concat

return Shared
