--[[--
@module koplugin.Zlibrary
--]]--

local Dispatcher = require("dispatcher")  -- luacheck:ignore
local lfs = require("libs/libkoreader-lfs")
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local util = require("util")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local T = require("zlibrary.gettext")
local Config = require("zlibrary.config")
local Api = require("zlibrary.api")
local Discovery = require("zlibrary.discovery")
local Download = require("zlibrary.download")
local Ui = require("zlibrary.ui")
local ReaderUI = require("apps/reader/readerui")
local AsyncHelper = require("zlibrary.async_helper")
local logger = require("logger")
local Ota = require("zlibrary.ota")
local Cache = require("zlibrary.cache")
local Device = require("device")
local MultiSearchDialog = require("zlibrary.multisearch_dialog")
local DialogManager = require("zlibrary.dialog_manager")
local Trapper = require("ui/trapper")

local Zlibrary = WidgetContainer:extend{
    name = T("Z-library"),
    is_doc_only = false,
    plugin_path = nil,
    dialog_manager = nil,
}

function Zlibrary:onDispatcherRegisterActions()
    Dispatcher:registerAction("zlibrary_search", { category="none", event="ZlibrarySearch", title=T("Z-library search"), general=true,})
    Dispatcher:registerAction("zlibrary_mybook", { category="none", event="ZlibrarySearch", title=string.format("%s %s", T("Z-library"), T("My books")), arg="mybooks",general=true,})
end

function Zlibrary:init()
    local full_source_path = debug.getinfo(1, "S").source
    if full_source_path:sub(1,1) == "@" then
        full_source_path = full_source_path:sub(2)
    end
    self.plugin_path, _ = util.splitFilePathName(full_source_path):gsub("/+", "/")

    Config.loadCredentialsFromFile(self.plugin_path)

    self.dialog_manager = DialogManager:new()
    Ui.setPluginInstance(self)

    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    else
        logger.warn("self.ui or self.ui.menu not initialized in Zlibrary:init")
    end
    self.preLoader = require("zlibrary.preloader").Preloader
end

function Zlibrary:onZlibrarySearch(act_page)
    if act_page == "mybooks" then
        local mybooks_tab_downloaded = 1
        self:showMyBooksDialog(mybooks_tab_downloaded)
    else
        local def_search_input
        if self.ui and self.ui.doc_settings and self.ui.doc_settings.data.doc_props then
            local doc_props = self.ui.doc_settings.data.doc_props
            def_search_input = doc_props.authors or doc_props.title
        end
        self:showMultiSearchDialog(nil, def_search_input)
    end
    return true
end

-- Delegates to zlibrary/discovery.lua. Kept as a method because the body recurses through it
-- and Ui calls it on the plugin instance when it offers auto-discovery after a failure.
function Zlibrary:autoDiscoverAndSetBaseUrl(is_interactive, retry_callback)
    return Discovery.run(self, is_interactive, retry_callback)
end

function Zlibrary:addToMainMenu(menu_items)
    if not self.ui.view then
        menu_items.zlibrary_main = {
            sorting_hint = "search",
            text = T("Z-library"),
            sub_item_table = {
                {
                    text = T("Settings"),
                    keep_menu_open = true,
                    separator = true,
                    sub_item_table = {
                        {
                            text = T("Set base URL"),
                            keep_menu_open = true,
                            callback = function()
                                UIManager:nextTick(function() self:autoDiscoverAndSetBaseUrl(true) end)
                            end,
                        },
                        {
                            text = T("Set credentials"),
                            keep_menu_open = true,
                            callback = function()
                                Ui.showCredentialsDialog(nil, function()
                                    self:login(function(success)
                                        if success then Ui.showInfoMessage(T("Login successful!")) end
                                    end)
                                 end)
                            end 
                    }, {
                            text = T("Verify credentials"),
                            keep_menu_open = true,
                            callback = function()
                                self:login(function(success)
                                    if success then
                                        Ui.showInfoMessage(T("Login successful!"))
                                    end
                                end)
                            end,
                            separator = true,
                        }, {
                            text = T("Set download directory"),
                            keep_menu_open = true,
                            callback = function()
                                Ui.showDownloadDirectoryDialog()
                            end,
                        }, {
                            -- Sits beside the download directory rather than under View Settings:
                            -- it changes what happens after a download, not how a list looks.
                            text = T("Ask to open after download"),
                            keep_menu_open = true,
                            checked_func = function()
                                return not Config.getSkipOpenBookPrompt()
                            end,
                            callback = function()
                                Config.setSkipOpenBookPrompt(not Config.getSkipOpenBookPrompt())
                            end,
                        }, {
                                text = T("View Settings"),
                                keep_menu_open = true,
                                sub_item_table = { {
                                    text = T("Search Covers"),
                                    keep_menu_open = true,
                                    checked_func = function()
                                        return Config.getViewSettings().show_cover_search ~= false
                                    end,
                                    callback = function() 
                                        local opts = Config.getViewSettings()
                                        opts.show_cover_search = not opts.show_cover_search
                                        Config.setViewSettings(opts)
                                    end, 
                                },  {
                                    text = T("Search Items/Page"),
                                    keep_menu_open = true,
                                    separator = true,
                                    callback = Ui.createPerPageSettingCallback(T("Search Items/Page"), "search_per_page"),
                                }, {
                                    text = T("Browse Covers"),
                                    keep_menu_open = true,
                                    checked_func = function()
                                        return Config.getViewSettings().show_cover_browse ~= false
                                    end,
                                    callback = function()
                                        local opts = Config.getViewSettings()
                                        opts.show_cover_browse = not opts.show_cover_browse
                                        Config.setViewSettings(opts)
                                    end,
                                }, {
                                    text = T("Browse Items/Page"),
                                    keep_menu_open = true,
                                    callback = Ui.createPerPageSettingCallback(T("Browse Items/Page"), "browse_per_page"),
                                }},
                        }, {
                            text = T("Search options"),
                            keep_menu_open = true,
                            separator = true,
                            sub_item_table = {{
                                text = T("Select search languages"),
                                keep_menu_open = true,
                                callback = function()
                                    Ui.showLanguageSelectionDialog(self.ui)
                                end
                            }, {
                                text = T("Select search formats"),
                                keep_menu_open = true,
                                callback = function()
                                    Ui.showExtensionSelectionDialog(self.ui)
                                end
                            }, {
                                text = T("Select search order"),
                                keep_menu_open = true,
                                callback = function()
                                    Ui.showOrdersSelectionDialog(self.ui)
                                end
                            }}
                        }, {
                            text = T("Timeout settings"),
                            keep_menu_open = true,
                            separator = true,
                            callback = function()
                                Ui.showAllTimeoutConfigDialog(self.ui)
                            end,
                        },
                        {
                            text = T("Check for updates"),
                            keep_menu_open = false,
                            separator = true,
                            callback = function()
                                if self.plugin_path then
                                    Ota.startUpdateProcess(self.plugin_path)
                                else
                                    logger.err("ZLibrary: Plugin path not available for OTA update.")
                                    Ui.showErrorMessage(T("Error: Plugin path not found. Cannot check for updates."))
                                end
                            end,
                        },
                        {
                            text = T("Developer options"),
                            keep_menu_open = true,
                            separator = true,
                            sub_item_table_func = function()
                                return {
                                    {
                                        text = T("Clear user session"),
                                        keep_menu_open = true,
                                        callback = function()
                                            Config.clearUserSession()
                                            Ui.showInfoMessage(T("Session cleared. You will need to login again."))
                                        end,
                                    }, {
                                        text = T("Clear runtime cache"),
                                        keep_menu_open = true,
                                        callback = function()
                                            Config.getConfigRuntimeCache():clear()
                                            Cache:new{ name = "_domains_cache" }:clear()
                                            Ui.showInfoMessage(T("Runtime cache cleared."))
                                        end,
                                    },
                                }
                            end
                        },
                    }
                },
                {
                    text = T("Search"),
                    callback = function()
                        Ui.showSearchDialog(self)
                    end,
                },
                {
                    text = T("Recommended"),
                    callback = function()
                        local search_tab_recommended = 2
                        self:showMultiSearchDialog(search_tab_recommended)
                    end,
                },
                {
                    text = T("Most popular"),
                    callback = function()
                        local search_tab_most_popular = 1
                        self:showMultiSearchDialog(search_tab_most_popular)
                    end,
                },{
                    text = T("My books"),
                    callback = function()
                        self:onZlibrarySearch("mybooks")
                    end,
                },
            }
        }
    end
end

function Zlibrary:_requestDispatcher(options, ...)
    if type(options.resolve_result) ~= "function" then
        logger.err("Zlibrary:%s - Fetch resolve_result undefined", options.log_context)
        return
    end

    -- If hasValidApiResult is undefined, resolve_result will be called globally
    local has_valid_api_result = type(options.hasValidApiResult) == "function"
    local on_finally = not has_valid_api_result and function(error_false)
        UIManager:nextTick(function()
            options.resolve_result(self.ui, error_false, self)
        end)
    end

    local api_extra_params = {...}

    if NetworkMgr:willRerunWhenOnline(function()
        self:_requestDispatcher(options, table.unpack(api_extra_params))
    end) then
        return on_finally and on_finally(false)
    end

    local function attemptFetch(retry_on_auth_error)
        retry_on_auth_error = retry_on_auth_error == nil and true or retry_on_auth_error
        
        local user_session = Config.getUserSession()
        local loading_msg = Ui.showLoadingMessage(options.loading_text_key)


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
                return on_finally and on_finally(false)
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
                return on_finally and on_finally(false)
            end, loading_msg, options.operation_key)
        end

        AsyncHelper.run(task, on_success, on_error_handler, loading_msg)
    end

    attemptFetch()
end

function Zlibrary:_fetchBookList(options, ...)
    options.hasValidApiResult = function(api_result)
        local ok = type(api_result) == "table" and type(api_result.books) == "table" and #api_result.books > 0
        return ok, not ok and T("No books found, please try again")
    end
    options.resolve_result = function(ui_self, api_result, plugin_self)
        
        self[options.results_member_name] = api_result.books
        options.display_menu_func(ui_self, self[options.results_member_name], plugin_self)
    end
    self:_requestDispatcher(options, ...)
end  

function Zlibrary:showMultiSearchDialog(def_position, def_search_input)
    local search_dialog
    local opts = Config.getViewSettings()
    search_dialog = MultiSearchDialog:new{
        title = T("Z-library search"),
        def_position = def_position,
        show_cover = opts.show_cover_browse ~= false,
        list_per_page = opts.browse_per_page,
        def_search_input = def_search_input,
        on_select_book_callback = function(book)
            self:onSelectRecommendedBook(book)
        end,
        on_search_callback = function(def_input)
            Ui.showSearchDialog(self, def_input)
        end,
        on_similar_books_callback = function(book)
            self:searchSimilarBooks(book)
        end,
        on_download_book_callback = function(book)
            self:downloadBook(book)
        end,
        toggle_items = {{
            text = T("Most popular"),
            cache_key = "popular",
            cache_expiry = 180000,
            callback = function(widget, page, is_refresh)
                self:_fetchBookList({
                    api_method = Api.getMostPopularBooks,
                    loading_text_key = T("Fetching most popular books..."),
                    error_prefix_key = T("Failed to fetch most popular books"),
                    operation_name = T("Most popular books"),
                    operation_key = "popular",
                    log_context = "onShowMostPopularBooks",
                    results_member_name = "current_most_popular_books",
                    display_menu_func = function(ui_self, books, plugin_self)
                        widget:reloadFromBookData(books)
                    end,
                    requires_auth = false,
                })
            end}, {
                text = T("Recommended"),
                cache_key = "recommended",
                cache_expiry = 180000,
                callback = function(widget, page, is_refresh)
                    self:_fetchBookList({
                        api_method = Api.getRecommendedBooks,
                        loading_text_key = T("Fetching recommended books..."),
                        error_prefix_key = T("Failed to fetch recommended books"),
                        operation_name = T("Recommended books"),
                        operation_key = "recommended",
                        log_context = "onShowRecommendedBooks",
                        results_member_name = "current_recommended_books",
                        display_menu_func = function(ui_self, books, plugin_self)
                            widget:reloadFromBookData(books)
                        end,
                        requires_auth = true,
                    })
            end},
        }
    }

    self.dialog_manager:trackDialog(search_dialog)
    search_dialog:fetchAndShow()
end

-- Reset when a book is successfully downloaded or when refreshing the menu
function Zlibrary:resetDownloadQuotaCache()
    Config.getConfigRuntimeCache():remove("download_quota_status")
end

function Zlibrary:getDownloadQuotaCache()
    return Config.getConfigRuntimeCache():get("download_quota_status", 10800)
end

function Zlibrary:isBookInFavorites(book_stub)
    local cached_ids = Config.getConfigRuntimeCache():get("favorite_book_ids", 1800)
    if not (book_stub and book_stub.id) then return type(cached_ids) == "table" end
    return type(cached_ids) == "table" and cached_ids[tostring(book_stub.id)] == true
end

-- Reset when a book is favorited/unfavorited or when refreshing the menu
function Zlibrary:resetFavoritesCache(is_all)
    Config.getConfigRuntimeCache():remove("favorite_book_ids")
    if is_all then Cache:new({ name = "multi_search" }):remove("favorites") end
end

function Zlibrary:showMyBooksDialog(def_position, def_search_input)
        local datetime = require("datetime")
        local my_books_dialog
        
        local get_quota_status = function()
            local quota_status = self:getDownloadQuotaCache()
            if type(quota_status) == "table" and quota_status.today ~= nil then
                quota_status.limit = quota_status.limit or 10
                 return string.format(" [%d/%d]", quota_status.today, quota_status.limit)
            end
        end
        
        local download_quota_status_string = get_quota_status() or ""

        local valid_api_result = function(api_result)
            local ok = type(api_result) == "table" and api_result.has_more_results ~= nil
            return ok, not ok and T("API returned an error, please try again")
        end

        local mandatory_format = function(mandatory_text)
             local secondsToDate, stringToSeconds = datetime.secondsToDate, datetime.stringToSeconds
             if not (mandatory_text and stringToSeconds) then return nil end
             local timestamp = stringToSeconds(mandatory_text)
             if not timestamp then return nil end
             local short_date = secondsToDate(timestamp, false)
             if type(short_date) == "string" then
                return (short_date:gsub("^%d%d(%d%d)%-0?(%d+)%-0?(%d+).*", "%1.%2.%3"))
             end
        end

        local opts = Config.getViewSettings()
        my_books_dialog = MultiSearchDialog:new{
            title = T("Z-library My Books"),
            def_position = def_position,
            show_cover = opts.show_cover_browse ~= false,
            list_per_page = opts.browse_per_page,
            def_search_input = def_search_input,
            on_select_book_callback = function(book)
                self:onSelectRecommendedBook(book)
            end,
            on_search_callback = function(def_input)
                Ui.showSearchDialog(self, def_input)
            end,
            on_similar_books_callback = function(book)
                self:searchSimilarBooks(book)
            end,
            on_download_book_callback = function(book)
                self:downloadBook(book)
            end,
            -- Invoked in fetchAndShow to dynamically update the widget
            on_fetch_and_show = function(widget)
                -- refresh download quota cache
                if download_quota_status_string == "" then
                    self.preLoader.getDownloadQuotaStatus(function(precheck_ok)
                        if precheck_ok == true then
                            download_quota_status_string = get_quota_status() or ""
                            widget:setToggleTitle(2, T("Downloaded") .. download_quota_status_string)  
                        end
                    end)
                end
            end,
            toggle_items = { {
                text = T("Favorites"),
                cache_key = "favorites",
                cache_expiry = 86400,
                enable_pagination = true,
                mandatory_func = function(book)
                    return mandatory_format(book and book.date_saved)
                end,
                callback = function(widget, page, is_refresh)
                    self:_requestDispatcher({
                        api_method = Api.getFavoriteBooks,
                        loading_text_key = T("Getting your favorites..."),
                        error_prefix_key = T("Failed to fetch favorite books"),
                        operation_name = T("Favorite books"),
                        log_context = "onShowFavoriteBooks",
                        hasValidApiResult = valid_api_result,
                        resolve_result = function(ui_self, api_result, plugin_self)
                            local books = api_result.books
                            local current_page = page or 1
                            local is_refresh_call = is_refresh

                            widget:setPaginationState(api_result.has_more_results, current_page)

                            if current_page == 1 then
                                widget:reloadFromBookData(books)
                            else
                                widget:appendBatchDataAndReload(books)
                            end
                            return is_refresh_call and plugin_self:resetFavoritesCache()
                        end,
                        requires_auth = true,
                    }, page)
                end}, {
                    text = T("Downloaded") .. download_quota_status_string,
                    cache_key = "downloaded",
                    cache_expiry = 86400,
                    enable_pagination = true,
                    mandatory_func = function(book)
                        return mandatory_format(book and book.date_download)
                    end,
                    -- Offered on a long press, and only on this tab. Confirm first: this edits the
                    -- account's history on the server and cannot be undone from here.
                    book_action = {
                        text = T("Remove from downloaded"),
                        callback = function(widget, book)
                            Ui.confirmRemoveDownloaded(book.title, function()
                                self:deleteDownloadedBook(book, function()
                                    widget:forceFetchAndReloadMenu()
                                end)
                            end)
                        end,
                    },
                    callback = function(widget, page, is_refresh)
                        self:_requestDispatcher({
                            api_method = Api.getDownloadedBooks,
                            loading_text_key = T("Getting your downloaded..."),
                            error_prefix_key = T("Failed to fetch downloaded books"),
                            operation_name = T("Downloaded books"),
                            log_context = "onShowDownloadedBooks",
                            hasValidApiResult = valid_api_result,
                            resolve_result = function(ui_self, api_result, plugin_self)
                                local books = api_result.books
                                local current_page = page or 1
                                local is_refresh_call = is_refresh

                                widget:setPaginationState(api_result.has_more_results, current_page)
                        
                                if current_page == 1 then
                                    widget:reloadFromBookData(books)
                                else
                                    -- Merge paginated results
                                    widget:appendBatchDataAndReload(books)
                                end
                                return is_refresh_call and plugin_self:resetDownloadQuotaCache()
                            end,
                            requires_auth = true,
                     }, page)
                 end},
            }}

        self.dialog_manager:trackDialog(my_books_dialog)
        my_books_dialog:fetchAndShow()
end

function Zlibrary:searchSimilarBooks(book_stub)
    if not (book_stub.id and book_stub.hash) then
        logger.warn("Zlibrary.searchSimilarBooks - parameter error")
        return
    end
    self:_fetchBookList({
        api_method = Api.getSimilarBooks,
        loading_text_key = T("Finding similar books..."),
        error_prefix_key = T("No similar books found"),
        operation_name = T("Similar books"),
        log_context = "searchSimilarBooks",
        results_member_name = "current_similar_books",
        display_menu_func = function(ui_self, books, plugin_self)
            local source_title = book_stub.title
            Ui.showSimilarBooksMenu(ui_self, books, plugin_self, source_title)
        end,
        requires_auth = true,
    }, book_stub.id, book_stub.hash)
end

function Zlibrary:deleteDownloadedBook(book_stub, on_success)
    if not (type(book_stub) == "table" and book_stub.id) then
        logger.warn("Zlibrary.deleteDownloadedBook - parameter error")
        return
    end
    self:_requestDispatcher({
        api_method = Api.deleteDownloadedBook,
        loading_text_key = T("Removing book from downloaded…"),
        error_prefix_key = T("Failed to remove book from downloaded"),
        -- Ui.showRetryErrorDialog quotes this inside "Could not complete \"%s\" …", so it names
        -- an operation rather than starting a sentence. A noun; no leading capital needed.
        operation_name = T("Remove from downloaded"),
        log_context = "deleteDownloadedBook",
        resolve_result = function(ui_self, api_result, plugin_self)
            if api_result and api_result.success == true then
                -- The server counts downloads against the daily quota, and the tab's title shows it,
                -- so let it be re-read rather than keep showing a figure this may have changed.
                plugin_self:resetDownloadQuotaCache()
                if type(on_success) == "function" then
                    on_success()
                else
                    Ui.showInfoMessage(T("Book removed from downloaded, please refresh"))
                end
            end
        end,
        hasValidApiResult = function(api_result)
            local ok = type(api_result) == "table"
            return ok, not ok and T("API returned an error, please try again")
        end,
        requires_auth = true,
    }, book_stub)
end

function Zlibrary:unfavoriteBook(book_stub, on_success)
     if not (book_stub.id and book_stub.hash) then
        logger.warn("Zlibrary.unfavoriteBook - parameter error")
        return
     end
     self:_requestDispatcher({
        api_method = Api.unfavoriteBook,
        loading_text_key = T("Removing book from favorites…"),
        error_prefix_key = T("Failed to remove book from favorites"),
        operation_name = T("Unfavorite book"),
        log_context = "unfavoriteBook",
        resolve_result = function(ui_self, api_result, plugin_self)
            if api_result and api_result.success == true then
                
                -- clear the book cache and favorite books after success
                plugin_self:resetFavoritesCache(true)
                if type(on_success) == "function" then 
                    on_success() 
                else
                    Ui.showInfoMessage(T("Book removed from favorites, please refresh"))
                end
            end
        end,
        hasValidApiResult = function(api_result)
            local ok = type(api_result) == "table"
            return ok, not ok and T("API returned an error, please try again")
        end,
        requires_auth = true,
    }, book_stub)
end

function Zlibrary:favoriteBook(book_stub, on_success)
     if not (book_stub.id and book_stub.hash) then
        logger.warn("Zlibrary.favoriteBook - parameter error")
        return
     end
     
     self:_requestDispatcher({
        api_method = Api.favoriteBook,
        loading_text_key = T("Adding book to favorites…"),
        error_prefix_key = T("Failed to add book to favorites"),
        operation_name = T("Favorite book"),
        log_context = "favoriteBook",
        resolve_result = function(ui_self, api_result, plugin_self)
            if api_result and api_result.success == true then
                plugin_self:resetFavoritesCache(true)
                if type(on_success) == "function" then 
                    on_success() 
                else
                    Ui.showInfoMessage(T("Book added to favorites, please refresh"))
                end
            end
        end,
        hasValidApiResult = function(api_result)
            local ok = type(api_result) == "table"
            return ok, not ok and T("API returned an error, please try again")
        end,
        requires_auth = true,
    }, book_stub)
end

function Zlibrary:onSelectRecommendedBook(book_stub)
    if not (book_stub.id and book_stub.hash) then
        logger.warn("Zlibrary.onSelectRecommendedBook - parameter error")
        return
    end

    local book_cache = Cache:new{ type="bookinfo" }
    local book_details_cache = book_cache:get(book_stub.hash, 604800)

    if type(book_details_cache) == "table" and book_details_cache.title then
        Ui.showBookDetails(self, book_details_cache, function()
                book_cache:clear(book_stub.hash)
                -- also clear comments
                local comments_key = string.format("%s_comments", book_stub.hash)
                book_cache:clear(comments_key)
                Cache:new{ type="cover" }:clear(book_stub.hash)
                self:onSelectRecommendedBook(book_stub)
        end)
        return
    end

    local on_success = function(ui_self, api_result, plugin_self)
        logger.info(string.format("Zlibrary:onSelectRecommendedBook - Fetch successful for book ID: %s", api_result.book.id))
        Ui.showBookDetails(self, api_result.book)
        book_cache:insert(book_stub.hash, api_result.book)
    end
    
    self:_requestDispatcher({
        api_method = Api.getBookDetails,
        loading_text_key = T("Fetching book details..."),
        error_prefix_key = T("Failed to fetch book details"),
        operation_name = T("Book details"),
        operation_key = "book_details",
        log_context = "onSelectRecommendedBook",
        resolve_result = on_success,
        requires_auth = true,
        hasValidApiResult = function(api_result)
            local ok = type(api_result) == "table" and type(api_result.book) == "table"
            return ok, not ok and T("Could not retrieve book details.")
        end,
    }, book_stub.id, book_stub.hash)
end

function Zlibrary:onSelectSearchBook(book_data)
    if NetworkMgr:willRerunWhenOnline(function()
        self:onSelectSearchBook(book_data)
    end) then
        return
    end

    -- If the book doesn't need detail fetching, show details directly
    if not book_data.needs_detail_fetch then
        Ui.showBookDetails(self, book_data)
        return
    end

    local function attemptBookDetails()
        local user_session = Config.getUserSession()
        local loading_msg = Ui.showLoadingMessage(T("Fetching book details..."))

        local task = function()
            return Api.getBookDetails(user_session and user_session.user_id, user_session and user_session.user_key, book_data.id, book_data.hash)
        end

        local on_success = function(api_result)
            if api_result.error then
                Ui.closeMessage(loading_msg)
                Ui.showErrorMessage(Ui.colonConcat(T("Failed to fetch book details"), tostring(api_result.error)))
                return
            end

            if not api_result.book then
                Ui.closeMessage(loading_msg)
                Ui.showErrorMessage(T("Could not retrieve book details."))
                return
            end

            Ui.closeMessage(loading_msg)
            logger.info(string.format("Zlibrary:onSelectSearchBook - Fetch successful for book ID: %s", api_result.book.id))

            Ui.showBookDetails(self, api_result.book)
        end

        local function on_error_handler(err_msg)
            -- Use retry dialog for timeout and network errors
            Ui.showRetryErrorDialog(err_msg, T("Book details"), function()
                -- Retry callback
                attemptBookDetails()
            end, function(final_err_msg)
                -- Cancel callback - user already knows about the error
            end, loading_msg, "book_details")
        end

        AsyncHelper.run(task, on_success, on_error_handler, loading_msg)
    end

    attemptBookDetails()
end

function Zlibrary:login(callback)
    if NetworkMgr:willRerunWhenOnline(function()
        self:login(callback)
    end) then
        return
    end

    local email = Config.getSetting(Config.SETTINGS_USERNAME_KEY)
    local password = Config.getSetting(Config.SETTINGS_PASSWORD_KEY)

    if not email or email == "" or not password or password == "" then
        Ui.showErrorMessage(T("Please set both username and password first."))
        if callback then callback(false) end
        return
    end

    local loading_msg = Ui.showLoadingMessage(T("Logging in..."))

    local task = function()
        return Api.login(email, password)
    end

    local on_success = function(result)
        Ui.closeMessage(loading_msg)

        if result.error then
            Ui.showErrorMessage(result.error)
            if callback then callback(false) end
            return
        end

        Config.saveUserSession(result.user_id, result.user_key)
        if callback then callback(true) end
    end

    local on_error_handler = function(err_msg)
        Ui.showRetryErrorDialog(err_msg, T("Sign-in"), function()
            self:login(callback)
        end, function(final_err_msg)
            if callback then callback(false) end
        end, loading_msg, "login")
    end

    AsyncHelper.run(task, on_success, on_error_handler, loading_msg)
end

function Zlibrary:performSearch(query)
    if NetworkMgr:willRerunWhenOnline(function()
        self:performSearch(query)
    end) then
        return
    end

    local function attemptSearch(retry_on_auth_error)
        retry_on_auth_error = retry_on_auth_error == nil and true or retry_on_auth_error
        
        local user_session = Config.getUserSession()
        local loading_msg = Ui.showLoadingMessage(string.format(T("Searching for \"%s\"..."), query))

        local selected_languages = Config.getSearchLanguages()
        local selected_extensions = Config.getSearchExtensions()
        local selected_order = Config.getSearchOrder()
        local current_page_to_search = 1

        local task = function()
            return Api.search(query, user_session and user_session.user_id, user_session and user_session.user_key, selected_languages, selected_extensions, selected_order, current_page_to_search)
        end

        local on_success
        on_success = function(api_result)
            if api_result.error then
                if retry_on_auth_error and Api.isAuthenticationError(api_result.error) then
                    Ui.closeMessage(loading_msg)
                    self:login(function(login_ok)
                        if login_ok then
                            attemptSearch(false)
                        end
                    end)
                    return
                end
                
                -- Use the retry dialog for timeouts and HTTP 400 errors
                Ui.showSearchErrorDialog(api_result.error, query, user_session, selected_languages, selected_extensions, selected_order, current_page_to_search, loading_msg, on_success, function(final_err_msg)
                    -- Cancel callback - user already knows about the error
                end)
                return
            end

            if not api_result.results or #api_result.results == 0 then
                Ui.closeMessage(loading_msg)
                Ui.showInfoMessage(string.format(T("No results found for \"%s\"."), query))
                return
            end

            Ui.closeMessage(loading_msg)
            logger.info(string.format("Zlibrary:performSearch - Fetch successful. Results: %d", #api_result.results))
            self.current_search_query = query
            self.current_search_api_page_loaded = current_page_to_search
            self.all_search_results_data = api_result.results
            self.has_more_api_results = true

            UIManager:nextTick(function()
                self:displaySearchResults(self.all_search_results_data, self.current_search_query)
            end)
        end

        local on_error_handler = function(err_msg)
            if retry_on_auth_error and Api.isAuthenticationError(err_msg) then
                Ui.closeMessage(loading_msg)
                self:login(function(login_ok)
                    if login_ok then
                        attemptSearch(false)
                    end
                end)
                return
            end
            
            -- Use the retry dialog for timeouts and HTTP 400 errors
            Ui.showSearchErrorDialog(err_msg, query, user_session, selected_languages, selected_extensions, selected_order, current_page_to_search, loading_msg, on_success, function(final_err_msg)
                -- Cancel callback - user already knows about the error
            end)
        end

        AsyncHelper.run(task, on_success, on_error_handler, loading_msg)
    end

    attemptSearch()
end

function Zlibrary:displaySearchResults(initial_book_data_list, query_string)
    if not initial_book_data_list or #initial_book_data_list == 0 then
        logger.info("Zlibrary:displaySearchResults - No initial results to display.")
        return
    end

    local menu_items = {}
    logger.info(string.format("Zlibrary:displaySearchResults - Preparing menu items from %d initial results.", #initial_book_data_list))
    local opts = Config.getViewSettings()
    local  is_show_cover = opts.show_cover_search ~= false

    for i = 1, #initial_book_data_list do
        local book_menu_item_data = initial_book_data_list[i]
        menu_items[i] = Ui.createBookMenuItem(book_menu_item_data, self, is_show_cover)
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
            local loading_msg_more = Ui.showLoadingMessage(string.format(T("Loading more results (Page %s)..."), next_api_page_to_fetch))

            local user_session_more = Config.getUserSession()
            local selected_languages_more = Config.getSearchLanguages()
            local selected_extensions_more = Config.getSearchExtensions()
            local selected_order_more = Config.getSearchOrder()

            local task_load_more = function()
                return Api.search(self.current_search_query, user_session_more.user_id, user_session_more.user_key, selected_languages_more, selected_extensions_more, selected_order_more, next_api_page_to_fetch)
            end

            local on_success_load_more
            local on_error_load_more

            on_success_load_more = function(api_result_more)
                Ui.closeMessage(loading_msg_more)
                if api_result_more.error then
                    -- No auth-retry here. Search is an unauthenticated endpoint: it answers
                    -- without a session and never returns "Please login", so isAuthenticationError
                    -- could not match. The retry pattern was copied from the authenticated fetch
                    -- handlers -- where it belongs, guarded and one-shot (see _requestDispatcher) --
                    -- but here it was dead code, and its self-recursion had no one-shot guard, so
                    -- had the endpoint ever started rejecting a session it would have looped. Any
                    -- real error just surfaces.
                    Ui.showErrorMessage(Ui.colonConcat(T("Failed to load more results"), tostring(api_result_more.error)))
                    return
                end

                local new_book_objects = api_result_more.results
                if new_book_objects and #new_book_objects > 0 then
                    logger.info(string.format("Zlibrary: Adding %d new book objects from API.", #new_book_objects))
                    self.current_search_api_page_loaded = next_api_page_to_fetch

                    local new_menu_items_to_add = {}
                    for _, book_api_data_transformed in ipairs(new_book_objects) do
                        table.insert(self.all_search_results_data, book_api_data_transformed)
                        table.insert(new_menu_items_to_add, Ui.createBookMenuItem(book_api_data_transformed, self, is_show_cover))
                    end
                    Ui.appendSearchResultsToMenu(menu_instance, new_menu_items_to_add)
                else
                    logger.info("Zlibrary: No more results from API or API returned empty.")
                    self.has_more_api_results = false
                    Ui.showInfoMessage(T("No more results found."))
                    menu_instance:updateItems(1, true)
                end
            end

            on_error_load_more = function(err_msg_more)
                Ui.closeMessage(loading_msg_more)
                -- No auth-retry: see on_success_load_more. Search is unauthenticated.
                Ui.showErrorMessage(Ui.colonConcat(T("Failed to load more results"), tostring(err_msg_more)))
            end

            AsyncHelper.run(task_load_more, on_success_load_more, on_error_load_more, loading_msg_more)
        else
            if is_last_page_of_current_items and not self.has_more_api_results then
                logger.info("Zlibrary: Reached last page, and no more API results to load.")
            end
            menu_instance:updateItems(1, true)
        end
        return true
    end

    -- Seed the box with the query that produced this page: refining a search is far more common
    -- than starting an unrelated one, and an empty box throws that away.
    self.active_results_menu = Ui.createSearchResultsMenu(self.ui, query_string, menu_items, on_goto_page_handler, opts,
        function() Ui.showSearchDialog(self, query_string) end,
        -- Holding a row downloads it without opening the detail view. downloadBook resolves the
        -- link from the id and hash a search result already carries, and ends by confirming, so
        -- this hands straight over -- asking here as well produced two dialogs in a row.
        function(book) self:downloadBook(book) end)
end


-- A file extension is only usable if it survives being pasted into a path.
--
-- Browse-list rows are stubs: they carry an id, a hash and a title, and the extension only
-- arrives with the full book details. Missing, it came through as the literal "N/A" -- truthy,
-- so the `or "unknown"` fallback never fired -- and the slash inside it turned
-- "<title> - <author>.N/A.downloading" into a directory that does not exist. The download died
-- at the open with "No such file or directory", naming a path no one had asked for.
-- Delegate to zlibrary/download.lua. Kept as methods: bookdetails_dialog calls downloadBook
-- on the plugin instance, and the retry and detail-fetch paths recurse through both.
function Zlibrary:_fetchDetailsThenDownload(book_stub)
    return Download.fetchDetailsThenDownload(self, book_stub)
end

function Zlibrary:downloadBook(book)
    return Download.run(self, book)
end

function Zlibrary:downloadAndShowCover(book)
    local cover_url = book.cover
    local book_hash = book.hash
    local book_title = book.title
    if not (cover_url and book_hash) then
        logger.warn("Zlibrary:downloadAndShowCover - parameter error")
        return
    end
    self.preLoader.getBookCover(cover_url, book_hash, function(is_ok)
            if is_ok == true then
                    local cover_cache = Cache:new{ type="cover" }
                     local cover_cache_path = cover_cache:get(book_hash)
                     Ui.showCoverDialog(book_title, cover_cache_path)
            end
    end)
end

function Zlibrary:fetchAndDisplayComments(book, skip_cache, callback)
    if not (book and book.id and book.hash) then
        Ui.showErrorMessage(T("Book ID is required."))
        return
    end
    
    local book_cache = Cache:new{ type="bookinfo" }
    local comments_key = string.format("%s_comments", book.hash)
    if not skip_cache then
        local book_comments_cache = book_cache:get(comments_key, 604800)
        if type(book_comments_cache) == "table" then
             if callback then callback(book_comments_cache) end
            return
        end
    end
    
    local task = function()
        return Api.getBookComments(book.id)
    end

    local on_success = function(ui_self, api_result, plugin_self)
        book_cache:insert(comments_key, api_result.comments)
        if callback then callback(api_result.comments) end
    end

    self:_requestDispatcher({
        api_method = Api.getBookComments,
        loading_text_key = T("Loading comments..."),
        error_prefix_key = T("Failed to load comments"),
        operation_name = T("Comments"),
        operation_key = "comments",
        log_context = "fetchAndDisplayComments",
        resolve_result = on_success,
        requires_auth = false,
        hasValidApiResult = function(api_result)
            local ok = type(api_result) == "table" and type(api_result.comments) == "table"
            return ok, not ok and T("No comments to display")
        end,
    }, book.id)
end

function Zlibrary:onExit()
    if self.dialog_manager and self.dialog_manager:getDialogCount() > 0 then
        logger.info("Zlibrary:onExit - Cleaning up " .. self.dialog_manager:getDialogCount() .. " remaining dialogs")
        self.dialog_manager:closeAllDialogs()
    end
    Cache.autoCacheCleanup(Config.getConfigRuntimeCache())
end

function Zlibrary:onCloseWidget()
    if self.dialog_manager and self.dialog_manager:getDialogCount() > 0 then
        logger.info("Zlibrary:onCloseWidget - Cleaning up " .. self.dialog_manager:getDialogCount() .. " remaining dialogs")
        self.dialog_manager:closeAllDialogs()
    end
    Cache.autoCacheCleanup(Config.getConfigRuntimeCache())
end

return Zlibrary