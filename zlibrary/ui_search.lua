-- Searching: recent searches, the search box, a result row, the results list and loading more into
-- it, and the search error dialog.
--
-- Part of the Ui facade (ui.lua); see ui_core.lua. Moved from ui.lua unchanged: diff with
-- --color-moved against the commit before the split to see where it came from.

local UIManager = require("ui/uimanager")
local ConfirmBox = require("ui/widget/confirmbox")
local T = require("zlibrary.gettext")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("zlibrary.menu")
local BookRow = require("zlibrary.book_row")
local Device = require("device")
local util = require("util")
local Config = require("zlibrary.config")
local Api = require("zlibrary.api")
local AsyncHelper = require("zlibrary.async_helper")
local Ui = require("zlibrary.ui_core")
local Shared = require("zlibrary.ui_shared")
local Pickers = require("zlibrary.ui_pickers")
local _showAndTrackDialog = Shared._showAndTrackDialog
local _closeAndUntrackDialog = Shared._closeAndUntrackDialog
local _colon_concat = Shared._colon_concat
local _showMultiSelectionDialog = Pickers._showMultiSelectionDialog

-- Tapping a search runs it, holding removes it. Going back returns to the search box with whatever
-- had been typed there.
function Ui.showSearchHistoryDialog(parent_zlibrary, typed_input)
    local title = T("Recent searches")
    local subtitle = T("Hold a search to remove it")
    local menu

    local function back_to_search()
        UIManager:close(menu)
        Ui.showSearchDialog(parent_zlibrary, typed_input)
    end

    local function build_items()
        local items = {}
        for _, query in ipairs(Config.getSearchHistory()) do
            items[#items + 1] = {
                text = query,
                query = query,
                keep_menu_open = true,
                callback = function()
                    UIManager:close(menu)
                    Ui._last_search_input = query
                    parent_zlibrary:performSearch(query)
                end,
            }
        end
        items[#items + 1] = {
            text = T("Clear search history"),
            keep_menu_open = true,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = T("Clear your search history?"),
                    ok_text = T("Clear"),
                    cancel_text = T("Cancel"),
                    ok_callback = function()
                        Config.clearSearchHistory()
                        back_to_search()
                    end,
                })
            end,
        }
        return items
    end

    menu = Menu:new{
        title = title,
        subtitle = subtitle,
        item_table = build_items(),
        parent = parent_zlibrary,
        show_captions = true,
        is_popout = false,
        title_bar_fm_style = true,
        onClose = back_to_search,
    }
    -- Menu calls this as a method, so the menu itself arrives as the first argument.
    menu.onMenuHold = function(_, item)
        if item and item.query then
            Config.removeSearchHistory(item.query)
            if #Config.getSearchHistory() == 0 then
                back_to_search()
            else
                menu:switchItemTable(title, build_items(), -1, nil, subtitle)
            end
        end
        return true
    end
    _showAndTrackDialog(menu)
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
            local language_name = selected_languages[1]
            for _, language_info in ipairs(Config.SUPPORTED_LANGUAGES) do
                if language_info.value == selected_languages[1] then
                    language_name = language_info.name
                    break
                end
            end
            lang_text = string.format(T("Language: %s"), language_name)
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

    local search_button = {
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
    }
    local search_row = { search_button }
    if #Config.getSearchHistory() > 0 then
        search_row = { {
            text = T("Recent searches"),
            callback = function()
                local typed_input = dialog:getInputText()
                _closeAndUntrackDialog(dialog)
                Ui.showSearchHistoryDialog(parent_zlibrary, typed_input)
            end,
        }, search_button }
    end

    dialog = InputDialog:new{
        title = T("Search Z-library"),
        input = def_input,
        buttons = { search_row, {{
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
    local title_for_html = (type(book_data.title) == "string" and book_data.title) or T("Unknown Title")
    local title = util.htmlEntitiesToUtf8(title_for_html)
    local author_for_html = (type(book_data.author) == "string" and book_data.author) or T("Unknown Author")
    local author = util.htmlEntitiesToUtf8(author_for_html)
    -- When only one format is being searched, every row would repeat it.
    local book_row = BookRow.new(title, author, book_data, #Config.getSearchExtensions() == 1)

    return {
        text = BookRow.text(book_row),
        book_row = book_row,
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
        multilines_forced = true,
        multilines_show_more_text = false,
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

return Ui
