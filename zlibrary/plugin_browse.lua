-- The browse screens: Most popular / Recommended, My Books (favourites, downloaded, booklists) and a
-- single booklist, with the download-quota and favourite-id caches they read.
--
-- Part of the plugin class. main.lua used to hold all of it in one 1,579-line file; it now copies
-- the methods each part returns onto the class at load (see the end of main.lua). The methods are
-- written exactly as they were there -- `function Zlibrary:name(...)` on this local table -- so
-- `self` is the plugin instance as before. Diff with --color-moved against the commit before the
-- split to see where the code came from.

local T = require("zlibrary.gettext")
local Config = require("zlibrary.config")
local Api = require("zlibrary.api")
local Ui = require("zlibrary.ui")
local MultiSearchDialog = require("zlibrary.multisearch_dialog")

local Zlibrary = {}

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
            cache_key = Config.getMostPopularCacheKey,
            cache_expiry = 180000,
            -- Only the language/format search has more pages; Z-library's own list is one fixed
            -- page of 100, and says so by never reporting more (has_more_results stays nil).
            enable_pagination = true,
            callback = function(widget, page, is_refresh)
                self:_fetchBookList({
                    api_method = Api.getMostPopularBooks,
                    loading_text_key = T("Fetching most popular books..."),
                    error_prefix_key = T("Failed to fetch most popular books"),
                    operation_name = T("Most popular books"),
                    operation_key = "popular",
                    log_context = "onShowMostPopularBooks",
                    results_member_name = "current_most_popular_books",
                    display_menu_func = function(ui_self, books, plugin_self, api_result)
                        local current_page = page or 1
                        widget:setPaginationState(api_result.has_more_results, current_page)
                        if current_page == 1 then
                            widget:reloadFromBookData(books)
                        else
                            widget:appendBatchDataAndReload(books)
                        end
                    end,
                    requires_auth = false,
                    cancellable = true,
                }, Config.getSearchLanguages(), Config.getSearchExtensions(), page)
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
                        cancellable = true,
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
    if is_all then Config.getMultiSearchCache():remove("favorites") end
end

function Zlibrary:showMyBooksDialog(def_position, def_search_input)
        local datetime = require("datetime")
        local my_books_dialog
        
        local get_quota_status = function()
            local quota_status = self:getDownloadQuotaCache()
            if type(quota_status) == "table" then
                -- Coerce: this is raw server JSON, and %d throws on a string value.
                local today = tonumber(quota_status.today)
                local limit = tonumber(quota_status.limit) or 10
                if today then
                     return string.format(" [%d/%d]", today, limit)
                end
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
             if type(short_date) == "string" then return short_date end
        end

        local opts = Config.getViewSettings()
        my_books_dialog = MultiSearchDialog:new{
            -- In the title rather than on the Downloaded tab, which is too narrow to show it.
            title = T("Z-library My Books") .. download_quota_status_string,
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
                            local titlebar = widget.compound_title_bar and widget.compound_title_bar._titlebar
                            if titlebar then
                                titlebar:setTitle(T("Z-library My Books") .. download_quota_status_string)
                            end
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
                callback = function(widget, page, is_refresh, fetch_generation)
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

                            widget:setPaginationState(api_result.has_more_results, current_page, fetch_generation)

                            if current_page == 1 then
                                widget:reloadFromBookData(books, nil, nil, nil, fetch_generation)
                            else
                                widget:appendBatchDataAndReload(books, fetch_generation)
                            end
                            return is_refresh_call and plugin_self:resetFavoritesCache()
                        end,
                        requires_auth = true,
                    }, page)
                end}, {
                    text = T("Downloaded"),
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
                    callback = function(widget, page, is_refresh, fetch_generation)
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

                                widget:setPaginationState(api_result.has_more_results, current_page, fetch_generation)
                        
                                if current_page == 1 then
                                    widget:reloadFromBookData(books, nil, nil, nil, fetch_generation)
                                else
                                    -- Merge paginated results
                                    widget:appendBatchDataAndReload(books, fetch_generation)
                                end
                                return is_refresh_call and plugin_self:resetDownloadQuotaCache()
                            end,
                            requires_auth = true,
                     }, page)
                 end}, {
                    text = T("Booklists"),
                    cache_key = "booklists",
                    cache_expiry = 86400,
                    enable_pagination = false,
                    rows = {
                        show_cover = false,
                        to_menu_item = function(booklist)
                            return {
                                text = booklist.name or T("Untitled"),
                                mandatory = booklist.count and tostring(booklist.count),
                                callback = function() self:showBooklistDialog(booklist) end,
                            }
                        end,
                    },
                    callback = function(widget, _, is_refresh, fetch_generation)
                        -- Each list's cached books carry its old count, so they go with the lists.
                        if is_refresh then Config.getMultiSearchCache():removePrefix("booklist_") end
                        self:_requestDispatcher({
                            api_method = Api.getBooklists,
                            loading_text_key = T("Getting your booklists..."),
                            error_prefix_key = T("Failed to fetch booklists"),
                            operation_name = T("Booklists"),
                            log_context = "onShowBooklists",
                            hasValidApiResult = function(api_result)
                                local ok = type(api_result) == "table" and type(api_result.booklists) == "table"
                                return ok, not ok and T("API returned an error, please try again")
                            end,
                            resolve_result = function(_, api_result)
                                widget:setPaginationState(false, 1, fetch_generation)
                                widget:reloadFromBookData(api_result.booklists, nil, nil, nil, fetch_generation)
                                if #api_result.booklists == 0 then
                                    Ui.showInfoMessage(T("You have no booklists yet"))
                                end
                            end,
                            requires_auth = true,
                        })
                    end,
                },
            }}

        self.dialog_manager:trackDialog(my_books_dialog)
        my_books_dialog:fetchAndShow()
end

-- One booklist's books, opened over My Books. A single tab hides the switch, so it is a plain paged list.
function Zlibrary:showBooklistDialog(booklist)
    local opts = Config.getViewSettings()
    local booklist_dialog = MultiSearchDialog:new{
        title = booklist.name,
        -- Without it fetchAndShow treats the dialog as a search screen and opens the search input.
        def_position = 1,
        show_cover = opts.show_cover_browse ~= false,
        list_per_page = opts.browse_per_page,
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
        toggle_items = { {
            text = booklist.name,
            cache_key = "booklist_" .. booklist.id,
            cache_expiry = 86400,
            enable_pagination = true,
            callback = function(widget, page, _, fetch_generation)
                self:_requestDispatcher({
                    api_method = Api.getBooklistBooks,
                    loading_text_key = T("Getting booklist books..."),
                    error_prefix_key = T("Failed to fetch booklist books"),
                    operation_name = T("Booklist books"),
                    log_context = "onShowBooklistBooks",
                    hasValidApiResult = function(api_result)
                        local ok = type(api_result) == "table" and type(api_result.books) == "table"
                        return ok, not ok and T("API returned an error, please try again")
                    end,
                    resolve_result = function(_, api_result)
                        local current_page = page or 1
                        widget:setPaginationState(api_result.has_more_results, current_page, fetch_generation)
                        if current_page == 1 then
                            widget:reloadFromBookData(api_result.books, nil, nil, nil, fetch_generation)
                            if #api_result.books == 0 then
                                Ui.showInfoMessage(T("This booklist is empty"))
                            end
                        else
                            widget:appendBatchDataAndReload(api_result.books, fetch_generation)
                        end
                    end,
                    requires_auth = true,
                }, booklist.id, page)
            end,
        } },
    }

    self.dialog_manager:trackDialog(booklist_dialog)
    booklist_dialog:fetchAndShow()
end

return Zlibrary
