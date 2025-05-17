--[[--
@module koplugin.Zlibrary
--]]--

local Dispatcher = require("dispatcher")  -- luacheck:ignore
local lfs = require("libs/libkoreader-lfs")
local meta = require("_meta")
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local util = require("frontend/util")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local T = require("gettext")
local Config = require("config")
local Api = require("api")
local Ui = require("ui")
local ReaderUI = require("apps/reader/readerui")
local AsyncHelper = require("async_helper")
local logger = require("logger")

local Zlibrary = WidgetContainer:extend{
    name = meta.fullname,
    is_doc_only = false,
}

function Zlibrary:onDispatcherRegisterActions()
    Dispatcher:registerAction("zlibrary_search", { category="none", event="ZlibrarySearch", title=T("Z-library search"), general=true,})
end

function Zlibrary:init()
    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    else
        logger.warn("self.ui or self.ui.menu not initialized in Zlibrary:init")
    end
end

function Zlibrary:addToMainMenu(menu_items)
    if not self.ui.view then
        menu_items.find_book_in_zlibrary = {
            sorting_hint = "search",
            text = T("Z-library search"),
            callback = function()
                Ui.showSearchDialog(self)
            end,
            separator = true,
        }
        menu_items.configure_zlibrary_plugin = {
            sorting_hint = "search",
            text = T("Z-library settings"),
            sub_item_table = {
                {
                    text = T("Set base URL"),
                    keep_menu_open = true,
                    callback = function()
                        Ui.showGenericInputDialog(
                            T("Set Z-library base URL"),
                            Config.SETTINGS_BASE_URL_KEY,
                            Config.getBaseUrl(),
                            false,
                            function(input_value)
                                local success, err_msg = Config.setAndValidateBaseUrl(input_value)
                                if not success then
                                    Ui.showErrorMessage(err_msg or T("Invalid Base URL."))
                                    return false
                                end
                                return true
                            end
                        )
                    end,
                    separator = true,
                },
                {
                    text = T("Set username"),
                    keep_menu_open = true,
                    callback = function()
                        Ui.showGenericInputDialog(
                            T("Set Z-library username"),
                            Config.SETTINGS_USERNAME_KEY,
                            Config.getSetting(Config.SETTINGS_USERNAME_KEY),
                            false
                        )
                    end,
                },
                {
                    text = T("Set password"),
                    keep_menu_open = true,
                    callback = function()
                        Ui.showGenericInputDialog(
                            T("Set Z-library password"),
                            Config.SETTINGS_PASSWORD_KEY,
                            Config.getSetting(Config.SETTINGS_PASSWORD_KEY),
                            true
                        )
                    end,
                },
                {
                    text = T("Verify credentials"),
                    keep_menu_open = true,
                    callback = function()
                        local success = self:login()
                        if (success) then
                            Ui.showInfoMessage(T("Login successful!"))
                        end
                    end,
                    separator = true,
                },
                {
                    text = T("Set download directory"),
                    keep_menu_open = true,
                    callback = function()
                        Ui.showDownloadDirectoryDialog()
                    end,
                },
                {
                    text = T("Select search languages"),
                    keep_menu_open = true,
                    callback = function()
                        Ui.showLanguageSelectionDialog(self.ui)
                    end,
                },
                {
                    text = T("Select search formats"),
                    keep_menu_open = true,
                    callback = function()
                        Ui.showExtensionSelectionDialog(self.ui)
                    end,
                },
            }
        }
    end
end

function Zlibrary:login()
    if not NetworkMgr:isOnline() then
        Ui.showErrorMessage(T("No internet connection detected."))
        return false
    end

    local email = Config.getSetting(Config.SETTINGS_USERNAME_KEY)
    local password = Config.getSetting(Config.SETTINGS_PASSWORD_KEY)

    if not email or not password then
        Ui.showErrorMessage(T("Please set both username and password first."))
        return false
    end

    local loading_msg = Ui.showLoadingMessage(T("Logging in..."))

    local result = Api.login(email, password)

    Ui.closeMessage(loading_msg)

    if result.error then
        Ui.showErrorMessage(result.error)
        return false
    end

    Config.saveUserSession(result.user_id, result.user_key)
    return true
end

function Zlibrary:performSearch(query)
    if not NetworkMgr:isOnline() then
        Ui.showErrorMessage(T("No internet connection detected."))
        return
    end

    local loading_msg = Ui.showLoadingMessage(T("Searching for \"") .. query .. "\"...")

    local function task()
        local user_session = Config.getUserSession()
        local selected_languages = Config.getSearchLanguages()
        local selected_extensions = Config.getSearchExtensions()
        return Api.search(query, user_session.user_id, user_session.user_key, selected_languages, selected_extensions, 1)
    end

    local function on_success(api_result)
        if not api_result or not api_result.results or #api_result.results == 0 then
            Ui.showInfoMessage(T("No results found for \"") .. query .. "\".")
            return
        end

        logger.info(string.format("Zlibrary:performSearch - Fetch successful. Results: %d", #api_result.results))
        self.current_search_query = query
        self.current_search_api_page_loaded = 1
        self.all_search_results_data = api_result.results
        self.has_more_api_results = true

        UIManager:nextTick(function()
            self:displaySearchResults(self.all_search_results_data, self.current_search_query)
        end)
    end

    local function on_error(err_msg)
        Ui.showErrorMessage(T("Search failed: ") .. tostring(err_msg))
    end

    AsyncHelper.run(task, on_success, on_error, loading_msg)
end

function Zlibrary:displaySearchResults(initial_book_data_list, query_string)
    if not initial_book_data_list or #initial_book_data_list == 0 then
        logger.info("Zlibrary:displaySearchResults - No initial results to display.")
        return
    end

    local menu_items = {}
    logger.info(string.format("Zlibrary:displaySearchResults - Preparing menu items from %d initial results.", #initial_book_data_list))

    for i = 1, #initial_book_data_list do
        local book_menu_item_data = initial_book_data_list[i]
        menu_items[i] = Ui.createBookMenuItem(book_menu_item_data, self)
    end

    if self.active_results_menu then
        UIManager:close(self.active_results_menu)
        self.active_results_menu = nil
    end

    local function on_goto_page_handler(menu_instance, new_page_number)
        menu_instance.prev_focused_path = nil
        menu_instance.page = new_page_number

        local is_last_page_of_current_items = (new_page_number == menu_instance.page_num)

        if is_last_page_of_current_items and self.has_more_api_results then
            logger.info(string.format("Zlibrary: Reached page %d (last page of current items). Attempting to load more from API.", new_page_number))

            local next_api_page_to_fetch = self.current_search_api_page_loaded + 1
            local loading_msg = Ui.showLoadingMessage(T("Loading more results (Page ") .. next_api_page_to_fetch .. T(")..."))

            local function task_load_more()
                local user_session = Config.getUserSession()
                local selected_languages = Config.getSearchLanguages()
                local selected_extensions = Config.getSearchExtensions()
                return Api.search(self.current_search_query, user_session.user_id, user_session.user_key, selected_languages, selected_extensions, next_api_page_to_fetch)
            end

            local function on_success_load_more(api_result)
                local new_book_objects = api_result and api_result.results
                if new_book_objects and #new_book_objects > 0 then
                    logger.info(string.format("Zlibrary: Adding %d new book objects from API.", #new_book_objects))
                    self.current_search_api_page_loaded = next_api_page_to_fetch

                    local new_menu_items_to_add = {}
                    for _, book_api_data_transformed in ipairs(new_book_objects) do
                        table.insert(self.all_search_results_data, book_api_data_transformed)
                        table.insert(new_menu_items_to_add, Ui.createBookMenuItem(book_api_data_transformed, self))
                    end
                    Ui.appendSearchResultsToMenu(menu_instance, new_menu_items_to_add)
                else
                    logger.info("Zlibrary: No more results from API or API returned empty.")
                    self.has_more_api_results = false
                    Ui.showInfoMessage(T("No more results found."))
                    menu_instance:updateItems(1, true)
                end
            end

            local function on_error_load_more(err_msg)
                Ui.showErrorMessage(T("Failed to load more results: ") .. tostring(err_msg))
                self.has_more_api_results = false
                menu_instance:updateItems(1, true)
            end

            AsyncHelper.run(task_load_more, on_success_load_more, on_error_load_more, loading_msg)
        else
            if is_last_page_of_current_items and not self.has_more_api_results then
                logger.info("Zlibrary: Reached last page, and no more API results to load.")
            end
            menu_instance:updateItems(1, true)
        end
        return true
    end

    self.active_results_menu = Ui.createSearchResultsMenu(self.ui, query_string, menu_items, on_goto_page_handler)
end

function Zlibrary:downloadBook(book)
    if not NetworkMgr:isOnline() then
        Ui.showErrorMessage(T("No internet connection detected."))
        return
    end

    if not book.download then
        Ui.showErrorMessage(T("No download link available for this book."))
        return
    end

    local download_url = Config.getDownloadUrl(book.download)
    logger.info(string.format("Zlibrary:downloadBook - Download URL: %s", download_url))

    local safe_title = util.trim(book.title or "Unknown Title"):gsub("[/\\?%*:|\"<>%c]", "_")
    local safe_author = util.trim(book.author or "Unknown Author"):gsub("[/\\?%*:|\"<>%c]", "_")
    local filename = string.format("%s - %s.%s", safe_title, safe_author, book.format or "unknown")
    logger.info(string.format("Zlibrary:downloadBook - Proposed filename: %s", filename))

    local target_dir = Config.getDownloadDir()

    if not target_dir then
        target_dir = Config.DEFAULT_DOWNLOAD_DIR_FALLBACK
        logger.warn(string.format("Zlibrary:downloadBook - Download directory setting not found, using fallback: %s", target_dir))
    else
        logger.info(string.format("Zlibrary:downloadBook - Using configured download directory: %s", target_dir))
    end

    if lfs.attributes(target_dir, "mode") ~= "directory" then
        local ok, err_mkdir = lfs.mkdir(target_dir)
        if not ok then
            Ui.showErrorMessage(string.format(T("Cannot create downloads directory: %s"), err_mkdir or "Unknown error"))
            return
        end
        logger.info(string.format("Zlibrary:downloadBook - Created downloads directory: %s", target_dir))
    end

    local target_filepath = target_dir .. "/" .. filename
    logger.info(string.format("Zlibrary:downloadBook - Target filepath: %s", target_filepath))

    local user_session = Config.getUserSession()
    local referer_url = book.href and Config.getBookUrl(book.href) or nil

    Ui.confirmDownload(filename, function()
        local loading_msg = Ui.showLoadingMessage(T("Downloading..."))

        local function task_download()
            return Api.downloadBook(download_url, target_filepath, user_session.user_id, user_session.user_key, referer_url)
        end

        local function on_success_download(api_result)
            if api_result and api_result.success then
                Ui.confirmOpenBook(filename, function()
                    if ReaderUI then
                        ReaderUI:showReader(target_filepath)
                    else
                        Ui.showErrorMessage(T("Could not open reader UI."))
                        logger.warn("Zlibrary:downloadBook - ReaderUI not available.")
                    end
                end)
            else
                local fail_msg = (api_result and api_result.message) or T("Download failed: Unknown error")
                if api_result and api_result.error and string.find(api_result.error, "Download limit reached or file is an HTML page", 1, true) then
                    fail_msg = T("Download limit reached. Please try again later or check your account.")
                elseif api_result and api_result.error then
                    fail_msg = api_result.error
                end
                Ui.showErrorMessage(fail_msg)
                pcall(os.remove, target_filepath)
            end
        end

        local function on_error_download(err_msg)
            local error_string = tostring(err_msg)
            if string.find(error_string, "Download limit reached or file is an HTML page", 1, true) then
                Ui.showErrorMessage(T("Download limit reached. Please try again later or check your account."))
            else
                Ui.showErrorMessage(error_string)
            end
            pcall(os.remove, target_filepath)
        end

        AsyncHelper.run(task_download, on_success_download, on_error_download, loading_msg)
    end)
end

return Zlibrary
