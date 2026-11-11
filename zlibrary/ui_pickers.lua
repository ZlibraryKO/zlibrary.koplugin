-- The selection list behind the search-language, format and order pickers: a multi-select (or,
-- for the order, a radio) list over a setting, with a filter for the long language list. Used by
-- the settings pickers and by the search box's own language and format buttons, so it is shared
-- here rather than kept in either -- private to the ui parts, not on Ui.
--
-- Part of the Ui facade (ui.lua); see ui_core.lua. Moved from ui.lua unchanged: diff with
-- --color-moved against the commit before the split to see where it came from.

local UIManager = require("ui/uimanager")
local T = require("zlibrary.gettext")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("zlibrary.menu")
local util = require("util")
local logger = require("logger")
local Config = require("zlibrary.config")
local Ui = require("zlibrary.ui_core")
local Shared = require("zlibrary.ui_shared")
local _showAndTrackDialog = Shared._showAndTrackDialog
local _closeAndUntrackDialog = Shared._closeAndUntrackDialog

local function _showMultiSelectionDialog(parent_ui, title, setting_key, options_list, ok_callback, is_single)
    local selected_values_table = Config.getSetting(setting_key, {})
    local selected_values_set = {}
    for _, value in ipairs(selected_values_table) do
        selected_values_set[value] = true
    end

    local current_selection_state = {}
    for _, option_info in ipairs(options_list) do
        current_selection_state[option_info.value] = selected_values_set[option_info.value] or false
    end
    -- An option standing for "no setting saved", so a radio list always shows what is in effect.
    local default_option
    for _, option_info in ipairs(options_list) do
        if option_info.is_default then default_option = option_info end
    end
    if default_option and next(selected_values_set) == nil then
        current_selection_state[default_option.value] = true
    end
    -- The value the user's last tap switched on; a radio cleanup keeps this one when the stored
    -- setting carried stale extras.
    local last_toggled_value

    local selection_menu
    -- nil while unfiltered; a lowercased query string while the user is filtering the list.
    local filter_query
    -- A long list (the ~190 languages) earns a title-bar search that filters by substring; the
    -- short ones (formats, order) do not, so their title bar stays uncluttered.
    local searchable = #options_list > 30

    local function _matches(option_info)
        if not filter_query then return true end
        -- Match the API value as well as the display name, so a native-script name (日本語) is
        -- found by typing its English key ("japanese"), and any substring ("ish" -> Irish) hits --
        -- KOReader's own type-jump only matches a prefix of the shown text and stops at the first.
        return option_info.name:lower():find(filter_query, 1, true) ~= nil
            or option_info.value:lower():find(filter_query, 1, true) ~= nil
    end

    local function _buildItem(option_info)
        local option_value = option_info.value
        return {
            text = option_info.name,
            mandatory_func = function()
                return current_selection_state[option_value] and "\u{2714}" or ""
            end,
            callback = function()
                current_selection_state[option_value] = not current_selection_state[option_value]
                if current_selection_state[option_value] then
                    last_toggled_value = option_value
                end
                selection_menu:updateItems(nil, true)
                -- single select
                if is_single then
                    selection_menu:onClose()
                end
            end,
            keep_menu_open = true,
        }
    end

    -- The rows to show for the current filter. For a multi-select the selected entries are hoisted
    -- to the top, so a handful of choices are not lost among ~190 rows; a radio list keeps its
    -- given order so the options can be compared in place. This runs on open and on a filter
    -- change, never on a toggle, so an entry never jumps out from under the finger that tapped it.
    local function _buildItems()
        local items = {}
        if not is_single then
            for _, option_info in ipairs(options_list) do
                if current_selection_state[option_info.value] and _matches(option_info) then
                    items[#items + 1] = _buildItem(option_info)
                end
            end
        end
        for _, option_info in ipairs(options_list) do
            if (is_single or not current_selection_state[option_info.value]) and _matches(option_info) then
                items[#items + 1] = _buildItem(option_info)
            end
        end
        return items
    end

    selection_menu = Menu:new{
        title = title,
        item_table = _buildItems(),
        parent = parent_ui,
        show_captions = true,
        is_popout = false,
        title_bar_fm_style = true,
        title_bar_left_icon = searchable and "appbar.search" or nil,
        onClose = function()
            local ok, err = pcall(function()
                local new_selected_values = {}
                for value, is_selected in pairs(current_selection_state) do
                    if is_selected then table.insert(new_selected_values, value) end
                end
                if is_single and #new_selected_values > 1 then
                    -- A radio setting keeps at most one value: the one just tapped. The old
                    -- cleanup removed only the first stored value, so a stored setting that
                    -- already held several values re-saved the rest of them. When nothing was
                    -- tapped (opened and backed out), fall back to the first stored value.
                    local value_to_keep = last_toggled_value or selected_values_table[1]
                    for i = #new_selected_values, 1, -1 do
                        if new_selected_values[i] ~= value_to_keep then
                            table.remove(new_selected_values, i)
                        end
                    end
                end

                if default_option then
                    for i = #new_selected_values, 1, -1 do
                        if new_selected_values[i] == default_option.value then
                            table.remove(new_selected_values, i)
                        end
                    end
                end

                table.sort(new_selected_values, function(a, b)
                    local name_a, name_b
                    for _, info in ipairs(options_list) do
                        if info.value == a then name_a = info.name end
                        if info.value == b then name_b = info.name end
                    end
                    return (name_a or "") < (name_b or "")
                end)

                if #new_selected_values > 0 then
                    Config.saveSetting(setting_key, new_selected_values)
                    return #new_selected_values
                else
                    Config.deleteSetting(setting_key)
                    -- Return the count rather than falling off the end: selecting nothing is a
                    -- normal outcome, and the callers below need a number.
                    return 0
                end
            end)

            UIManager:close(selection_menu)
            if ok then
                local selected_count = err or 0
                if type(ok_callback) == "function" then
                    ok_callback(selected_count)
                elseif selected_count > 0 then
                    Ui.showInfoMessage(string.format(T("%d items selected for %s."), selected_count, title))
                else
                    Ui.showInfoMessage(string.format(T("Filter cleared for %s."), title))
                end
            else
                logger.err("Zlibrary:Ui._editConfigOptionsDialog - Error during onClose for %s: %s", title, tostring(err))
                Ui.showInfoMessage(string.format(T("Filter cleared for %s."), title))
            end
        end,
    }

    if searchable then
        -- Menu invokes this as a method, so the menu arrives as the first argument (unused).
        selection_menu.onLeftButtonTap = function()
            local input
            input = InputDialog:new{
                title = T("Filter"),
                input = filter_query or "",
                buttons = { {
                    {
                        text = T("Cancel"),
                        id = "close",
                        callback = function() _closeAndUntrackDialog(input) end,
                    },
                    {
                        -- Reset to the full list. Selections survive: they live in
                        -- current_selection_state, not in which rows are shown.
                        text = T("Show all"),
                        callback = function()
                            filter_query = nil
                            _closeAndUntrackDialog(input)
                            selection_menu:switchItemTable(title, _buildItems())
                        end,
                    },
                    {
                        text = T("Filter"),
                        is_enter_default = true,
                        callback = function()
                            local typed = util.trim(input:getInputText() or "")
                            filter_query = typed ~= "" and typed:lower() or nil
                            _closeAndUntrackDialog(input)
                            -- Show the active filter in the title, so a short filtered list does
                            -- not look like the whole set.
                            selection_menu:switchItemTable(
                                filter_query and (title .. " (" .. typed .. ")") or title,
                                _buildItems())
                        end,
                    },
                } },
            }
            _showAndTrackDialog(input)
            input:onShowKeyboard()
        end
    end
    _showAndTrackDialog(selection_menu)
end

local function  _showRadioSelectionDialog(parent_ui, title, setting_key, options_list, ok_callback)
    _showMultiSelectionDialog(parent_ui, title, setting_key, options_list, ok_callback, true)
end

return {
    _showMultiSelectionDialog = _showMultiSelectionDialog,
    _showRadioSelectionDialog = _showRadioSelectionDialog,
}
