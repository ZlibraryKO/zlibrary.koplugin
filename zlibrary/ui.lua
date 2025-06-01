local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local TextViewer = require("ui/widget/textviewer")
local T = require("zlibrary.gettext")
local DownloadMgr = require("ui/downloadmgr")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local Config = require("zlibrary.config")
local util = require("util")
local logger = require("logger")

local Ui = {}

local function _colon_concat(a, b)
    return a .. ": " .. b
end

function Ui.showInfoMessage(text)
    UIManager:show(InfoMessage:new{ text = text })
end

function Ui.showErrorMessage(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 5 })
end

function Ui.showLoadingMessage(text)
    local message = InfoMessage:new{ text = text, timeout = 0 }
    UIManager:show(message)
    return message
end

function Ui.closeMessage(message_widget)
    if message_widget then
        UIManager:close(message_widget)
    end
end

function Ui.showFullTextDialog(title, full_text)
    UIManager:show(TextViewer:new{
        title = title,
        text = full_text,
    })
end

function Ui.showSimpleMessageDialog(title, text)
    UIManager:show(ConfirmBox:new{
        title = title,
        text = text, 
        cancel_text = T("Close"),
        no_ok_button = true,
    })
end

function Ui.showDownloadDirectoryDialog()
    local current_dir = G_reader_settings:readSetting(Config.SETTINGS_DOWNLOAD_DIR_KEY)
    DownloadMgr:new{
        title = T("Select Z-library Download Directory"),
        onConfirm = function(path)
            if path then
                G_reader_settings:saveSetting(Config.SETTINGS_DOWNLOAD_DIR_KEY, path)
                Ui.showInfoMessage(string.format(T("Download directory set to: %s"), path))
            else
                Ui.showErrorMessage(T("No directory selected."))
            end
        end,
    }:chooseDir(current_dir)
end

local function _showMultiSelectionDialog(parent_ui, title, setting_key, options_list)
    local selected_values_table = G_reader_settings:readSetting(setting_key) or {}
    local selected_values_set = {}
    for _, value in ipairs(selected_values_table) do
        selected_values_set[value] = true
    end

    local current_selection_state = {}
    for _, option_info in ipairs(options_list) do
        current_selection_state[option_info.value] = selected_values_set[option_info.value] or false
    end

    local menu_items = {}
    local selection_menu

    for i, option_info in ipairs(options_list) do
        local option_value = option_info.value
        menu_items[i] = {
            text = option_info.name,
            mandatory_func = function()
                return current_selection_state[option_value] and "[X]" or "[ ]"
            end,
            callback = function()
                current_selection_state[option_value] = not current_selection_state[option_value]
                selection_menu:updateItems(nil, true)
            end,
            keep_menu_open = true,
        }
    end

    selection_menu = Menu:new{
        title = title,
        item_table = menu_items,
        parent = parent_ui,
        show_captions = true,
        onClose = function()
            local ok, err = pcall(function()
                local new_selected_values = {}
                for value, is_selected in pairs(current_selection_state) do
                    if is_selected then table.insert(new_selected_values, value) end
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
                    G_reader_settings:saveSetting(setting_key, new_selected_values)
                    Ui.showInfoMessage(string.format(T("%d items selected for %s."), #new_selected_values, title))
                else
                    G_reader_settings:delSetting(setting_key)
                    Ui.showInfoMessage(string.format(T("Filter cleared for %s."), title))
                end
            end)
            if not ok then
                logger.err("Zlibrary:Ui._showMultiSelectionDialog - Error during onClose for %s: %s", title, tostring(err))
            end
            UIManager:close(selection_menu)
        end,
    }
    UIManager:show(selection_menu)
end

function Ui.showLanguageSelectionDialog(parent_ui)
    _showMultiSelectionDialog(parent_ui, T("Select search languages"), Config.SETTINGS_SEARCH_LANGUAGES_KEY, Config.SUPPORTED_LANGUAGES)
end

function Ui.showExtensionSelectionDialog(parent_ui)
    _showMultiSelectionDialog(parent_ui, T("Select search formats"), Config.SETTINGS_SEARCH_EXTENSIONS_KEY, Config.SUPPORTED_EXTENSIONS)
end

function Ui.showGenericInputDialog(title, setting_key, current_value_or_default, is_password, validate_and_save_callback)
    local dialog

    dialog = InputDialog:new{
        title = title,
        input = current_value_or_default or "",
        text_type = is_password and "password" or nil,
        buttons = {{
            {
                text = T("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
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
                        UIManager:close(dialog)
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Ui.showSearchDialog(parent_zlibrary, def_input)
    local dialog
    -- save last search input
    if Ui._last_search_input and not def_input then
        def_input = Ui._last_search_input
    end
    dialog = InputDialog:new{
        title = T("Search Z-library"),
        input = def_input,
        buttons = {{
            {
                text = T("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = T("Search"),
                callback = function()
                    local query = dialog:getInputText()
                    UIManager:close(dialog)

                    if not query or not query:match("%S") then
                        Ui.showErrorMessage(T("Please enter a search term."))
                        return
                    end
                    Ui._last_search_input = query

                    local login_ok = parent_zlibrary:login()

                    if not login_ok then
                        return
                    end

                    local trimmed_query = util.trim(query)
                    parent_zlibrary:performSearch(trimmed_query)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Ui.createBookMenuItem(book_data, parent_zlibrary_instance)
    local year_str = (book_data.year and book_data.year ~= "N/A" and tostring(book_data.year) ~= "0") and (" (" .. book_data.year .. ")") or ""
    local title_for_html = (type(book_data.title) == "string" and book_data.title) or T("Unknown Title")
    local title = util.htmlEntitiesToUtf8(title_for_html)
    local author_for_html = (type(book_data.author) == "string" and book_data.author) or T("Unknown Author")
    local author = util.htmlEntitiesToUtf8(author_for_html)
    local combined_text = string.format("%s by %s%s", title, author, year_str)

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
            Ui.showBookDetails(parent_zlibrary_instance, book_data)
        end,
        keep_menu_open = true,
        original_book_data_ref = book_data,
    }
end

function Ui.createSearchResultsMenu(parent_ui_ref, query_string, initial_menu_items, on_goto_page_handler)
    local menu = Menu:new{
        title = _colon_concat(T("Search Results"), query_string),
        item_table = initial_menu_items,
        parent = parent_ui_ref,
        items_per_page = 10,
        show_captions = true,
        onGotoPage = on_goto_page_handler,
        is_popout = false,
        is_borderless = true,
        title_bar_fm_style = true,
        multilines_show_more_text = true
    }
    UIManager:show(menu)
    return menu
end

function Ui.appendSearchResultsToMenu(menu_instance, new_menu_items)
    if not menu_instance or not menu_instance.item_table then return end
    for _, item_data in ipairs(new_menu_items) do
        table.insert(menu_instance.item_table, item_data)
    end
    menu_instance:switchItemTable(menu_instance.title, menu_instance.item_table, -1, nil, menu_instance.subtitle)
end

function Ui.showBookDetails(parent_zlibrary, book)
    local details_menu_items = {}
    local details_menu

    local title_text_for_html = (type(book.title) == "string" and book.title) or ""
    local full_title = util.htmlEntitiesToUtf8(title_text_for_html)
    table.insert(details_menu_items, {
        text = _colon_concat(T("Title"), full_title),
        enabled = true,
        callback = function()
            Ui.showSimpleMessageDialog(T("Full Title"), full_title)
        end,
        keep_menu_open = true,
    })

    local author_text_for_html = (type(book.author) == "string" and book.author) or ""
    local full_author = util.htmlEntitiesToUtf8(author_text_for_html)
    table.insert(details_menu_items, {
        text = _colon_concat(T("Author"), full_author),
        enabled = true,
        callback = function()
            Ui.showSimpleMessageDialog(T("Full Author"), full_author)
        end,
        keep_menu_open = true,
    })

    if book.year and book.year ~= "N/A" and tostring(book.year) ~= "0" then table.insert(details_menu_items, { text = _colon_concat(T("Year"), book.year), enabled = false }) end
    if book.lang and book.lang ~= "N/A" then table.insert(details_menu_items, { text = _colon_concat(T("Language"), book.lang), enabled = false }) end

    if book.format and book.format ~= "N/A" then
        if book.download then
            table.insert(details_menu_items, {
                text = string.format(T("Format: %s (tap to download)"), book.format),
                callback = function()
                    parent_zlibrary:downloadBook(book)
                end,
                keep_menu_open = true,
            })
        else
            table.insert(details_menu_items, { text = string.format(T("Format: %s (Download not available)"), book.format), enabled = false })
        end
    elseif book.download then
        table.insert(details_menu_items, {
            text = T("Download Book (Unknown Format)"),
            callback = function()
                parent_zlibrary:downloadBook(book)
            end,
            keep_menu_open = true,
        })
    end

    if book.size and book.size ~= "N/A" then table.insert(details_menu_items, { text = _colon_concat(T("Size"), book.size), enabled = false }) end
    if book.rating and book.rating ~= "N/A" then table.insert(details_menu_items, { text = _colon_concat(T("Rating"), book.rating), enabled = false }) end
    if book.publisher and book.publisher ~= "" then
        local publisher_for_html = (type(book.publisher) == "string" and book.publisher) or ""
        table.insert(details_menu_items, { text = _colon_concat(T("Publisher"), util.htmlEntitiesToUtf8(publisher_for_html)), enabled = false })
    end
    if book.series and book.series ~= "" then
        local series_for_html = (type(book.series) == "string" and book.series) or ""
        table.insert(details_menu_items, { text = _colon_concat(T("Series"), util.htmlEntitiesToUtf8(series_for_html)), enabled = false })
    end
    if book.pages and book.pages ~= 0 then table.insert(details_menu_items, { text = _colon_concat(T("Pages"), book.pages), enabled = false }) end

    if book.description and book.description ~= "" then
        table.insert(details_menu_items, {
            text = T("Description (tap to view)"),
            enabled = true,
            callback = function()
                local desc_for_html = (type(book.description) == "string" and book.description) or ""
                local full_description = util.htmlEntitiesToUtf8(util.trim(desc_for_html))
                full_description = string.gsub(full_description, "<[Bb][Rr]%s*/?>", "\n")
                full_description = string.gsub(full_description, "</[Pp]>", "\n\n")
                full_description = string.gsub(full_description, "<[^>]+>", "")     
                full_description = string.gsub(full_description, "(\n\r?%s*){2,}", "\n\n")
                Ui.showFullTextDialog(T("Description"), full_description)
            end,
            keep_menu_open = true,
        })
    end

    table.insert(details_menu_items, { text = "---" })

    table.insert(details_menu_items, {
        text = T("Back"),
        callback = function()
            if details_menu then UIManager:close(details_menu) end
        end,
    })

    details_menu = Menu:new{
        title = T("Book Details"),
        item_table = details_menu_items,
        parent = parent_zlibrary.ui,
        show_captions = true,
    }
    UIManager:show(details_menu)
end

function Ui.confirmDownload(filename, ok_callback)
    UIManager:show(ConfirmBox:new{
        text = string.format(T("Download \"%s\"?"), filename),
        ok_text = T("Download"),
        ok_callback = ok_callback,
        cancel_text = T("Cancel")
    })
end

function Ui.confirmOpenBook(filename, ok_open_callback)
    UIManager:show(ConfirmBox:new{
        text = string.format(T("\"%s\" downloaded successfully. Open it now?"), filename),
        ok_text = T("Open book"),
        ok_callback = ok_open_callback,
        cancel_text = T("Close")
    })
end

function Ui.showRecommendedBooksMenu(ui_self, books, plugin_self)
    local menu_items = {}
    for _, book in ipairs(books) do
        local title = book.title or T("Untitled")
        local author = book.author or T("Unknown Author")
        local menu_text = string.format("%s - %s", title, author)
        table.insert(menu_items, {
            text = menu_text,
            callback = function()
                plugin_self:onSelectRecommendedBook(book)
            end,
        })
    end

    if #menu_items == 0 then
        Ui.showInfoMessage(T("No recommended books found, please try again. Sometimes this requires a couple of retries."))
        return
    end

    local menu = Menu:new({
        title = T("Z-library Recommended Books"),
        item_table = menu_items,
        items_per_page = 10,
        show_captions = true,
        parent = ui_self.document_menu_parent_holder,
        is_popout = false,
        is_borderless = true,
        title_bar_fm_style = true,
        multilines_show_more_text = true
    })
    UIManager:show(menu)
end

function Ui.showMostPopularBooksMenu(ui_self, books, plugin_self)
    local menu_items = {}
    for _, book in ipairs(books) do
        local title = book.title or T("Untitled")
        local author = book.author or T("Unknown Author")
        local menu_text = string.format("%s - %s", title, author)
        table.insert(menu_items, {
            text = menu_text,
            callback = function()
                plugin_self:onSelectRecommendedBook(book)
            end,
        })
    end

    if #menu_items == 0 then
        Ui.showInfoMessage(T("No most popular books found. The list was empty, please try again."))
        return
    end

    local menu = Menu:new({
        title = T("Z-library Most Popular Books"),
        item_table = menu_items,
        items_per_page = 10,
        show_captions = true,
        parent = ui_self.document_menu_parent_holder,
        is_popout = false,
        is_borderless = true,
        title_bar_fm_style = true,
        multilines_show_more_text = true
    })
    UIManager:show(menu)
end

function Ui.confirmShowRecommendedBooks(ok_callback)
    UIManager:show(ConfirmBox:new{
        text = T("Fetch most recommended book from Z-library?"),
        ok_text = T("OK"),
        cancel_text = T("Cancel"),
        ok_callback = ok_callback,
    })
end

function Ui.confirmShowMostPopularBooks(ok_callback)
    UIManager:show(ConfirmBox:new{
        text = T("Fetch most popular books from Z-library?"),
        ok_text = T("OK"),
        cancel_text = T("Cancel"),
        ok_callback = ok_callback,
    })
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
    UIManager:show(menu)
    return menu
end

return Ui
