local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local TextViewer = require("ui/widget/textviewer")
local T = require("zlibrary.gettext")
local DownloadMgr = require("ui/downloadmgr")
local InputDialog = require("ui/widget/inputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local Menu = require("zlibrary.menu")
local Device = require("device")
local util = require("util")
local logger = require("logger")
local Config = require("zlibrary.config")
local Api = require("zlibrary.api")
local AsyncHelper = require("zlibrary.async_helper")

local Ui = {}

local _plugin_instance = nil

function Ui.setPluginInstance(plugin_instance)
    _plugin_instance = plugin_instance
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

-- Close a dialog this module opened, from outside it. The credentials dialog needs this: it stays
-- on screen while its contents are checked against the server, so whoever is doing the checking
-- has to close it once a verdict arrives. Goes through the same untracking path as every other
-- close, or the widget stays in DialogManager._open_dialogs and closeAllDialogs re-closes a dead
-- one.
function Ui.closeDialog(dialog)
    _closeAndUntrackDialog(dialog)
end

local function _colon_concat(a, b)
    return a .. ": " .. b
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
    local message = InfoMessage:new{
        text = string.format("\u{23f3}  %s", text),
        dismissable = false,
        show_icon = false,
        force_one_line = true,
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

function Ui.showCoverDialog(title, img_path)
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
                return current_selection_state[option_value] and "[X]" or "[ ]"
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

function Ui.showLanguageSelectionDialog(parent_ui)
    _showMultiSelectionDialog(parent_ui, T("Select search languages"), Config.SETTINGS_SEARCH_LANGUAGES_KEY, Config.SUPPORTED_LANGUAGES)
end

function Ui.showExtensionSelectionDialog(parent_ui)
    _showMultiSelectionDialog(parent_ui, T("Select search formats"), Config.SETTINGS_SEARCH_EXTENSIONS_KEY, Config.SUPPORTED_EXTENSIONS)
end

function Ui.showOrdersSelectionDialog(parent_ui, ok_callback)
    _showRadioSelectionDialog(parent_ui, T("Select search order"), Config.SETTINGS_SEARCH_ORDERS_KEY, Config.SUPPORTED_ORDERS, ok_callback)
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

-- Download categories management ----------------------------------------------------------------
-- Categories are names that become folders under the download dir (see Config); this is where the
-- user creates, renames and removes them. Folders are derived from the names, so there is no folder
-- picker -- only text entry. Menus rebuild after each change: a sub-category edit refreshes the open
-- submenu in place, while adding, renaming or removing a category (a change to the list itself) is
-- reflected when control returns to the list, through TouchMenu's backToUpperMenu/needs_refresh hook.

local function _categoryError(reason)
    if reason == "empty" then return T("Please enter a name.") end
    if reason == "exists" then return T("A category with that name already exists.") end
    -- "not_found" / "no_parent": it was removed under us (e.g. acting on a menu left open).
    return T("That category no longer exists.")
end

local function _findCategory(name)
    for _, cat in ipairs(Config.getCategories()) do
        if cat.name == name then return cat end
    end
    return nil
end

-- Alphabetical, case-insensitive, on a shallow copy: the display order, never the stored order (the
-- stored list is what the mutation helpers read back and rewrite). One for the category tables, one
-- for the child name strings.
local function _sortedCategories(list)
    local copy = {}
    for _, cat in ipairs(list) do copy[#copy + 1] = cat end
    table.sort(copy, function(a, b) return (a.name or ""):lower() < (b.name or ""):lower() end)
    return copy
end

local function _sortedNames(list)
    local copy = {}
    for _, name in ipairs(list) do copy[#copy + 1] = name end
    table.sort(copy, function(a, b) return a:lower() < b:lower() end)
    return copy
end

-- A small name-entry dialog for a category or sub-category. on_accept(text) does the work and
-- returns true to accept (the dialog closes) or false to keep it open with what was typed, so a
-- rejected name (empty, duplicate) can be corrected without retyping.
function Ui.showCategoryNameDialog(title, initial, on_accept)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = initial or "",
        buttons = {{
            {
                text = T("Cancel"),
                id = "close",
                callback = function() _closeAndUntrackDialog(dialog) end,
            },
            {
                text = T("Save"),
                is_enter_default = true,
                callback = function()
                    if on_accept(dialog:getInputText() or "") then
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

-- Rename/Remove for a single sub-category. refresh() rebuilds the open submenu so the change shows
-- at once.
local function _showSubcategoryActions(parent_name, sub_name, refresh)
    local dialog
    dialog = ButtonDialog:new{
        title = parent_name .. " › " .. sub_name,
        title_align = "center",
        buttons = {
            {{
                text = T("Rename"),
                callback = function()
                    _closeAndUntrackDialog(dialog)
                    Ui.showCategoryNameDialog(T("Rename sub-category"), sub_name, function(text)
                        local ok, reason = Config.renameSubcategory(parent_name, sub_name, text)
                        if not ok then Ui.showInfoMessage(_categoryError(reason)) return false end
                        refresh()
                        return true
                    end)
                end,
            }},
            {{
                text = T("Remove"),
                callback = function()
                    _closeAndUntrackDialog(dialog)
                    _showAndTrackDialog(ConfirmBox:new{
                        text = string.format(
                            T("Remove the sub-category \"%s\"? Books already filed there stay where they are."),
                            sub_name),
                        ok_text = T("Remove"),
                        ok_callback = function()
                            Config.removeSubcategory(parent_name, sub_name)
                            refresh()
                        end,
                    })
                end,
            }},
        },
    }
    _showAndTrackDialog(dialog)
end

-- The submenu for one category: its actions first (Add sub-category, Rename category, Remove
-- category), then a separator, then its sub-categories (tap each for Rename/Remove). Actions on top so
-- they stay on the first page however many sub-categories there are. Sub-category edits refresh this
-- submenu in place; renaming or removing the category itself changes the list a level up, so those
-- return there.
function Ui.buildOneCategoryMenuItems(cat_name)
    local cat = _findCategory(cat_name)
    local children = (cat and cat.children) or {}
    local items = {}

    table.insert(items, {
        text = T("Add sub-category…"),
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            Ui.showCategoryNameDialog(T("New sub-category"), "", function(text)
                local ok, reason = Config.addSubcategory(cat_name, text)
                if not ok then Ui.showInfoMessage(_categoryError(reason)) return false end
                if touchmenu_instance then
                    touchmenu_instance.item_table = Ui.buildOneCategoryMenuItems(cat_name)
                    touchmenu_instance:updateItems()
                end
                return true
            end)
        end,
    })

    table.insert(items, {
        text = T("Rename category…"),
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            Ui.showCategoryNameDialog(T("Rename category"), cat_name, function(text)
                local ok, reason = Config.renameCategory(cat_name, text)
                if not ok then Ui.showInfoMessage(_categoryError(reason)) return false end
                if touchmenu_instance then touchmenu_instance:backToUpperMenu() end
                return true
            end)
        end,
    })

    table.insert(items, {
        text = T("Remove category"),
        separator = true,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            _showAndTrackDialog(ConfirmBox:new{
                text = string.format(
                    T("Remove the category \"%s\" and its sub-categories? Books already filed there stay where they are."),
                    cat_name),
                ok_text = T("Remove"),
                ok_callback = function()
                    Config.removeCategory(cat_name)
                    if touchmenu_instance then touchmenu_instance:backToUpperMenu() end
                end,
            })
        end,
    })

    for _, child in ipairs(_sortedNames(children)) do
        local child_name = child
        table.insert(items, {
            text = child_name,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                _showSubcategoryActions(cat_name, child_name, function()
                    if touchmenu_instance then
                        touchmenu_instance.item_table = Ui.buildOneCategoryMenuItems(cat_name)
                        touchmenu_instance:updateItems()
                    end
                end)
            end,
        })
    end

    return items
end

-- The top-level "Download categories" list: "Add category…" first, then one row per category (tap to
-- open its submenu). Add stays on the first page however many categories there are, rather than being
-- paged off the bottom. needs_refresh/refresh_func let TouchMenu rebuild the list when returning from
-- a submenu, so a rename or removal made in there shows up on the way back.
function Ui.buildCategoriesMenuItems()
    local categories = Config.getCategories()
    local items = {}

    table.insert(items, {
        text = T("Add category…"),
        separator = true,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            Ui.showCategoryNameDialog(T("New category"), "", function(text)
                local ok, reason = Config.addCategory(text)
                if not ok then Ui.showInfoMessage(_categoryError(reason)) return false end
                if touchmenu_instance then
                    touchmenu_instance.item_table = Ui.buildCategoriesMenuItems()
                    touchmenu_instance:updateItems()
                end
                return true
            end)
        end,
    })

    for _, cat in ipairs(_sortedCategories(categories)) do
        local cat_name = cat.name
        local child_count = (cat.children and #cat.children) or 0
        table.insert(items, {
            text = cat_name,
            mandatory = child_count > 0 and tostring(child_count) or nil,
            keep_menu_open = true,
            sub_item_table_func = function()
                return Ui.buildOneCategoryMenuItems(cat_name)
            end,
        })
    end

    items.needs_refresh = true
    items.refresh_func = function() return Ui.buildCategoriesMenuItems() end

    return items
end

function Ui.showSearchDialog(parent_zlibrary, def_input)
    -- save last search input
    if not def_input then
        def_input = Ui._last_search_input
        if not def_input and Device:hasClipboard() then
            local clip_text = Device.input.getClipboardText()
            if type(clip_text) == "string" and #clip_text < 80 then
                def_input = clip_text
            end
        end
    end
  
    local dialog
    local search_order_name = Config.getSearchOrderName()
    
    local selected_languages = Config.getSearchLanguages()
    local selected_extensions = Config.getSearchExtensions()
    
    local lang_text = T("Set languages")
    if #selected_languages > 0 then
        if #selected_languages == 1 then
            lang_text = string.format(T("Language: %s"), selected_languages[1])
        else
            lang_text = string.format(T("Languages (%d)"), #selected_languages)
        end
    end
    
    local format_text = T("Set formats")
    if #selected_extensions > 0 then
        if #selected_extensions == 1 then
            for _, ext_info in ipairs(Config.SUPPORTED_EXTENSIONS) do
                if ext_info.value == selected_extensions[1] then
                    format_text = string.format(T("Format: %s"), ext_info.name)
                    break
                end
            end
        else
            format_text = string.format(T("Formats (%d)"), #selected_extensions)
        end
    end

    dialog = InputDialog:new{
        title = T("Search Z-library"),
        input = def_input,
        buttons = {{{
        text = T("Search"),
        callback = function()
            local query = dialog:getInputText()
            _closeAndUntrackDialog(dialog)

            if not query or not query:match("%S") then
                Ui._last_search_input = nil
                Ui.showErrorMessage(T("Please enter a search term."))
                return
            end
            Ui._last_search_input = query

            local trimmed_query = util.trim(query)
            parent_zlibrary:performSearch(trimmed_query)
        end,
        }},{{
            text = string.format("%s: %s \u{25BC}", T("Sort by"), search_order_name),
            callback = function()
                -- Carry over what the user has typed so far; def_input is the value captured
                -- when this dialog was built and would silently discard it.
                local typed_input = dialog:getInputText()
                _closeAndUntrackDialog(dialog)
                Ui.showOrdersSelectionDialog(parent_zlibrary, function(count)
                    Ui.showSearchDialog(parent_zlibrary, typed_input)
                end)
            end
        }},{{
            text = lang_text,
            callback = function()
                local typed_input = dialog:getInputText()
                _closeAndUntrackDialog(dialog)
                _showMultiSelectionDialog(parent_zlibrary, T("Select search languages"), Config.SETTINGS_SEARCH_LANGUAGES_KEY, Config.SUPPORTED_LANGUAGES, function(count)
                    Ui.showSearchDialog(parent_zlibrary, typed_input)
                end)
            end
        },{
            text = format_text,
            callback = function()
                local typed_input = dialog:getInputText()
                _closeAndUntrackDialog(dialog)
                _showMultiSelectionDialog(parent_zlibrary, T("Select search formats"), Config.SETTINGS_SEARCH_EXTENSIONS_KEY, Config.SUPPORTED_EXTENSIONS, function(count)
                    Ui.showSearchDialog(parent_zlibrary, typed_input)
                end)
            end
        }},{{
            text = T("Cancel"),
            id = "close",
            callback = function() _closeAndUntrackDialog(dialog) end,
        }}}
    }
    _showAndTrackDialog(dialog)
    dialog:onShowKeyboard()
end

function Ui.createBookMenuItem(book_data, parent_zlibrary_instance, is_show_cover)
    local year_str = (book_data.year and book_data.year ~= "N/A" and tostring(book_data.year) ~= "0") and (" (" .. book_data.year .. ")") or ""
    local title_for_html = (type(book_data.title) == "string" and book_data.title) or T("Unknown Title")
    local title = util.htmlEntitiesToUtf8(title_for_html)
    local author_for_html = (type(book_data.author) == "string" and book_data.author) or T("Unknown Author")
    local author = util.htmlEntitiesToUtf8(author_for_html)
    local combined_text = string.format("\u{FFF1}\u{FFF2}%s\u{FFF3} by %s%s", title, author, year_str)

    local additional_info_parts = {}
    local selected_extensions = Config.getSearchExtensions()

    if book_data.format and book_data.format ~= "N/A" then
        if #selected_extensions ~= 1 then
            table.insert(additional_info_parts, book_data.format)
        end
    end
    if book_data.size and book_data.size ~= "N/A" then table.insert(additional_info_parts, book_data.size) end
    if book_data.rating and book_data.rating ~= "N/A" then table.insert(additional_info_parts, _colon_concat(T("Rating"), book_data.rating)) end

    if #additional_info_parts > 0 then
        combined_text = combined_text .. " | " .. table.concat(additional_info_parts, " | ")
    end

    return {
        text = combined_text,
        callback = function()
            if book_data.needs_detail_fetch then
                parent_zlibrary_instance:onSelectSearchBook(book_data)
            else
                Ui.showBookDetails(parent_zlibrary_instance, book_data)
            end
        end,
        keep_menu_open = true,
        -- Carried so a hold on this row can act on the book without re-deriving it. Costs
        -- nothing: the tap callback above already closes over the same table.
        book_data = book_data,
        book_id = book_data.id,
        hash = book_data.hash,
        cover = is_show_cover and book_data.cover or nil,
    }
end

-- on_new_search, when given, puts a magnifying glass in the title bar that reopens the search
-- input. The results page had no way back to the search box: you closed it, found the menu and
-- started again. The multi-search screen has had this button all along, so this is parity rather
-- than a new idea, and it is the only route available -- TitleBar exposes callbacks for its
-- icons and not for the title text, so tapping the "Search Results: x" caption is not an option.
function Ui.createSearchResultsMenu(parent_ui_ref, query_string, initial_menu_items, on_goto_page_handler, opts, on_new_search, on_hold_book)
    local search_order_name = Config.getSearchOrderName()
    local menu = Menu:new{
        title = _colon_concat(T("Search Results"), query_string),
        subtitle = string.format("%s: %s", T("Sort by"), search_order_name),
        title_bar_left_icon = on_new_search and "appbar.search" or nil,
        item_table = initial_menu_items,
        parent = parent_ui_ref,
        items_per_page = 10,
        show_captions = true,
        onGotoPage = on_goto_page_handler,
        is_popout = false,
        is_borderless = true,
        title_bar_fm_style = true,
        multilines_show_more_text = true,
        list_per_page =opts and opts.search_per_page,
        show_cover = opts and opts.show_cover_search ~= false,
    }
    if on_new_search then
        -- Menu calls this as a method, so the menu itself arrives as the first argument.
        menu.onLeftButtonTap = function() on_new_search() end
    end
    if on_hold_book then
        -- Menu calls this as a method too, hence the discarded first argument. Returning true
        -- marks the hold handled so the list does not also act on it.
        menu.onMenuHold = function(_, item)
            if item and item.book_data then
                on_hold_book(item.book_data)
            end
            return true
        end
    end
    _showAndTrackDialog(menu)
    return menu
end

function Ui.appendSearchResultsToMenu(menu_instance, new_menu_items)
    if not menu_instance or not menu_instance.item_table then return end
    for _, item_data in ipairs(new_menu_items) do
        table.insert(menu_instance.item_table, item_data)
    end
    menu_instance:switchItemTable(menu_instance.title, menu_instance.item_table, -1, nil, menu_instance.subtitle)
end

function Ui.showBookDetails(parent_zlibrary, book, clear_cache_callback)
    local ZlibBookDialog = require("zlibrary.bookdetails_dialog")
    return ZlibBookDialog.showBookDetails(Ui, parent_zlibrary, book, clear_cache_callback)
end

function Ui.confirmRemoveDownloaded(title, ok_callback)
    local text = string.format(T("Remove \"%s\" from your downloaded books?"), title or T("Unknown Title"))
    if _plugin_instance and _plugin_instance.dialog_manager then
        _plugin_instance.dialog_manager:showConfirmDialog({
            text = text,
            ok_text = T("Remove"),
            ok_callback = ok_callback,
            cancel_text = T("Cancel")
        })
    else
        UIManager:show(ConfirmBox:new{
            text = text,
            ok_text = T("Remove"),
            ok_callback = ok_callback,
            cancel_text = T("Cancel")
        })
    end
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

function Ui.confirmDownload(filename, ok_callback)
    if _plugin_instance and _plugin_instance.dialog_manager then
        _plugin_instance.dialog_manager:showConfirmDialog({
            text = string.format(T("Download \"%s\"?"), filename),
            ok_text = T("Download"),
            ok_callback = ok_callback,
            cancel_text = T("Cancel")
        })
    else
        local dialog = ConfirmBox:new{
            text = string.format(T("Download \"%s\"?"), filename),
            ok_text = T("Download"),
            ok_callback = ok_callback,
            cancel_text = T("Cancel")
        }
        UIManager:show(dialog)
    end
end

-- Create a category (and optionally a sub-category under it) from a pair of typed names, returning
-- the move target { name = parent, sub = <child or nil> } on success or nil + a message. An existing
-- name is reused, not an error: typing a name that already exists just files into it.
local function _createCategoryTarget(parent_raw, sub_raw)
    local parent = Config.sanitizeCategoryName(parent_raw)
    if parent == "" then return nil, T("Please enter a category name.") end
    local ok, reason = Config.addCategory(parent)
    if not ok and reason ~= "exists" then return nil, _categoryError(reason) end
    local sub = Config.sanitizeCategoryName(sub_raw)
    if sub ~= "" then
        local sok, sreason = Config.addSubcategory(parent, sub)
        if not sok and sreason ~= "exists" then return nil, _categoryError(sreason) end
        return { name = parent, sub = sub }
    end
    return { name = parent }
end

-- Create a category on the spot from the move menu: one dialog with a required category field and an
-- optional sub-category field. on_created(target) receives the move target so the caller can select
-- it straight away.
function Ui._showCreateCategoryDialog(on_created)
    local dialog
    dialog = require("ui/widget/multiinputdialog"):new{
        title = T("New category"),
        fields = {
            { description = T("Category"), hint = T("Category name") },
            { description = T("Sub-category (optional)"), hint = T("Sub-category name") },
        },
        buttons = {{
            {
                text = T("Cancel"),
                id = "close",
                callback = function() _closeAndUntrackDialog(dialog) end,
            },
            {
                text = T("Create"),
                is_enter_default = true,
                callback = function()
                    local fields = dialog:getFields()
                    local target, err = _createCategoryTarget(fields[1], fields[2])
                    if not target then
                        Ui.showInfoMessage(err)
                        return
                    end
                    _closeAndUntrackDialog(dialog)
                    on_created(target)
                end,
            },
        }},
    }
    _showAndTrackDialog(dialog)
    dialog:onShowKeyboard()
end

-- The post-download "Move to" picker, as a scrollable menu. Rows: Keep in download folder, New
-- category… (opens the create dialog), a separator, then every filing target A-Z -- each top-level
-- category, and each sub-category shown indented as "Parent › Child". Picking one hands a descriptor
-- ({ name = <top>, sub = <child or nil> } or nil) to on_pick; leaving the menu (Back / tap-outside)
-- calls on_cancel so the download dialog it came from reopens unchanged. The current choice is ticked.
function Ui._showCategoryChooser(categories, current, on_pick, on_cancel)
    local menu
    -- One close path for both outcomes; the guard stops a stray second call (e.g. a tap racing the
    -- Back gesture) from firing a callback twice.
    local done = false
    local function finish(cancelled, target)
        if done then return end
        done = true
        _closeAndUntrackDialog(menu)
        if cancelled then
            if on_cancel then on_cancel() end
        else
            on_pick(target)
        end
    end

    local function is_current(target)
        if current == nil or target == nil then return current == target end
        return current.name == target.name and current.sub == target.sub
    end
    local function mark(target) return is_current(target) and "✓" or nil end

    local function build_items()
        local items = {}

        items[#items + 1] = {
            text = T("Keep in download folder"),
            mandatory = mark(nil),
            keep_menu_open = true,
            callback = function() finish(false, nil) end,
        }
        items[#items + 1] = {
            text = T("New category…"),
            keep_menu_open = true,
            callback = function()
                Ui._showCreateCategoryDialog(function(target) finish(false, target) end)
            end,
        }
        items[#items].separator = true

        for _, cat in ipairs(_sortedCategories(categories)) do
            if type(cat) == "table" and cat.name then
                items[#items + 1] = {
                    text = cat.name,
                    mandatory = mark({ name = cat.name }),
                    keep_menu_open = true,
                    callback = function() finish(false, { name = cat.name }) end,
                }
                for _, child in ipairs(_sortedNames(cat.children or {})) do
                    items[#items + 1] = {
                        text = "    " .. cat.name .. " › " .. child,
                        mandatory = mark({ name = cat.name, sub = child }),
                        keep_menu_open = true,
                        callback = function() finish(false, { name = cat.name, sub = child }) end,
                    }
                end
            end
        end

        return items
    end

    menu = Menu:new{
        title = T("Move to"),
        item_table = build_items(),
        is_popout = false,
        title_bar_fm_style = true,
        -- Back key / title-bar close / tap-outside all route here; a deliberate pick closes via
        -- finish() first, so by the time this could run `done` is already set and it is a no-op.
        onClose = function() finish(true) end,
    }
    _showAndTrackDialog(menu)
end

function Ui.confirmOpenBook(filename, has_wifi_toggle, default_turn_off_wifi, ok_open_callback, cancel_callback, categories)
    local turn_off_wifi = default_turn_off_wifi
    -- nil = leave the book in the download folder; otherwise { name = <top>, sub = <child or nil> }.
    local chosen_target = nil

    -- Downloading several books in a row means answering this dialog several times, which a user
    -- asked to be able to switch off.
    --
    -- Skipping it leaves Wi-Fi alone, whatever the stored preference says. That preference is
    -- "Turn off Wi-Fi after closing this dialog" -- there is no dialog here and nothing being
    -- closed, so there is nothing for it to be after. It also lives only on this dialog, so
    -- honouring it here would keep a background action running that the user can no longer see
    -- or change. Anyone wanting Wi-Fi managed for them still has the prompt.
    --
    -- The notice matters as much as the skipping. This dialog is the only sign most people get
    -- that a download worked; replacing one that demands an answer with one that dismisses
    -- itself is the point, and replacing it with silence would be a different, worse feature.
    if Config.getSkipOpenBookPrompt() then
        Ui.showInfoMessage(string.format(T("\"%s\" downloaded."), filename))
        -- No dialog, so no filing choice was made: the second argument stays nil and the book is
        -- left in the download folder.
        if cancel_callback then cancel_callback(false) end
        return
    end

    -- Only offer the "Move to" row when categories actually exist; with none configured the
    -- dialog is byte-identical to what it was before this feature.
    local has_categories = type(categories) == "table" and #categories > 0

    local function targetLabel(target)
        -- The default when nothing is picked: the book stays in the download folder. Naming it (rather
        -- than an empty "Move to…") tells the user where the book goes if they leave this alone.
        if target == nil then return T("Download folder") end
        if target.sub then return target.name .. " › " .. target.sub end
        return target.name
    end

    local function showDialog()
        -- No filename. It is built as "<title> - <author>.<format>", which for anything with a
        -- long title runs to a paragraph, and this dialog already carries two buttons and the
        -- Wi-Fi toggle's own long label. The user tapped download on a specific book moments
        -- ago, so naming it back to them buys little for the height it costs.
        local full_text = T("Book downloaded successfully. Open it now?")

        local dialog
        local other_buttons = {}

        if has_wifi_toggle then
            table.insert(other_buttons, {
                {
                    text = turn_off_wifi and ("☑ " .. T("Turn off Wi-Fi after closing this dialog")) or ("☐ " .. T("Turn off Wi-Fi after closing this dialog")),
                    callback = function()
                        turn_off_wifi = not turn_off_wifi
                        Config.setTurnOffWifiAfterDownload(turn_off_wifi)
                        _closeAndUntrackDialog(dialog)
                        showDialog()
                    end,
                },
            })
        end

        if has_categories then
            table.insert(other_buttons, {
                {
                    -- No checkbox: this is not a toggle, it opens a chooser. Always name the
                    -- destination -- the download folder by default -- so where the book goes is
                    -- never hidden behind an empty "Move to…".
                    text = string.format(T("Move to: %s"), targetLabel(chosen_target)),
                    callback = function()
                        -- Close this dialog, choose a target, then re-render it -- the same
                        -- close-and-reopen the Wi-Fi toggle above uses. Dismissing the chooser
                        -- reopens this dialog with the choice untouched.
                        _closeAndUntrackDialog(dialog)
                        Ui._showCategoryChooser(categories, chosen_target,
                            function(new_target)
                                chosen_target = new_target
                                showDialog()
                            end,
                            function()
                                showDialog()
                            end)
                    end,
                },
            })
        end

        -- Keep other_buttons nil when empty so ConfirmBox renders exactly as it did before.
        if #other_buttons == 0 then other_buttons = nil end

        dialog = ConfirmBox:new{
            text = full_text,
            ok_text = T("Open book"),
            ok_callback = function()
                ok_open_callback(turn_off_wifi, chosen_target)
            end,
            cancel_text = T("Close"),
            cancel_callback = function()
                cancel_callback(turn_off_wifi, chosen_target)
            end,
            other_buttons = other_buttons,
            other_buttons_first = true,
        }

        _showAndTrackDialog(dialog)
    end

    showDialog()
end

function Ui.showSimilarBooksMenu(ui_self, books, plugin_self, source_title)
    local opts = Config.getViewSettings()
    local show_cover = opts.show_cover_search ~= false
    books = books or {}

    local menu_items = {}
    local menu_item
    for _, book in ipairs(books) do
        menu_item = Ui.createBookMenuItem(book, plugin_self, show_cover)
        menu_item.callback = function()
                plugin_self:onSelectRecommendedBook(book)
        end
        table.insert(menu_items, menu_item)
    end

    if #menu_items == 0 then
       Ui.showInfoMessage(string.format(T("No %s found, please try again. Sometimes this requires a couple of retries."), "similar books"))
        return
    end
    
    local menu = Menu:new({
        title = T("Z-library Similar Books"),
        subtitle = source_title,
        item_table = menu_items,
        show_captions = true,
        parent = ui_self.document_menu_parent_holder,
        is_popout = false,
        is_borderless = true,
        title_bar_fm_style = true,
        multilines_show_more_text = true,
        list_per_page =opts and opts.search_per_page,
        show_cover = show_cover,
    })
    _showAndTrackDialog(menu)
end

function Ui.createSingleBookMenu(ui_self, title, menu_items)
    local menu = Menu:new{
        title = title or T("Book Details"),
        show_parent_menu = true,
        parent_menu_text = T("Back"),
        item_table = menu_items,
        parent = ui_self.view,
        items_per_page = 10,
        show_captions = true,
    }
    _showAndTrackDialog(menu)
    return menu
end

function Ui.showSearchErrorDialog(err_msg, query, user_session, selected_languages, selected_extensions, selected_order, current_page, loading_msg_to_close, original_on_success, original_on_error)
    local retry_callback = function()
        local new_loading_msg = Ui.showCancellableLoadingMessage(string.format(T("Retrying search for \"%s\"..."), query))
        local retry_task = function()
            return Api.search(query, user_session.user_id, user_session.user_key, selected_languages, selected_extensions, selected_order, current_page)
        end
        AsyncHelper.runCancellable(retry_task, original_on_success, function(new_err_msg)
            Ui.showSearchErrorDialog(new_err_msg, query, user_session, selected_languages, selected_extensions, selected_order, current_page, new_loading_msg, original_on_success, original_on_error)
        end, new_loading_msg)
    end
    
    local cancel_callback = function(err)
        original_on_error(err)
    end
    
    -- "Book search", not "Search": this names an operation in the retry dialog and the timeout
    -- menu, so it has to be a noun. KOReader's "Search" is a button imperative, and the shim
    -- would hand us that instead of ours -- see the msgid comment in showRetryErrorDialog.
    Ui.showRetryErrorDialog(err_msg, T("Book search"), retry_callback, cancel_callback, loading_msg_to_close, "search")
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
    

    local is_http_400 = string.match(error_string, "HTTP Error: 400")
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