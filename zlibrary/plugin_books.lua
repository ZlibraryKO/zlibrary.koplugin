-- Acting on one book: opening its details, similar books, adding or removing a favourite, removing
-- it from the downloaded history, its cover and its comments.
--
-- Part of the plugin class. main.lua used to hold all of it in one 1,579-line file; it now copies
-- the methods each part returns onto the class at load (see the end of main.lua). The methods are
-- written exactly as they were there -- `function Zlibrary:name(...)` on this local table -- so
-- `self` is the plugin instance as before. Diff with --color-moved against the commit before the
-- split to see where the code came from.

local NetworkMgr = require("ui/network/manager")
local T = require("zlibrary.gettext")
local Config = require("zlibrary.config")
local Api = require("zlibrary.api")
local Ui = require("zlibrary.ui")
local AsyncHelper = require("zlibrary.async_helper")
local logger = require("logger")
local Cache = require("zlibrary.cache")

local Zlibrary = {}

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
        logger.info(string.format("Zlibrary:onSelectRecommendedBook - Fetch successful for book ID: %s", tostring(api_result.book.id)))
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
        cancellable = true,
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
        local loading_msg = Ui.showCancellableLoadingMessage(T("Fetching book details..."))

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
            logger.info(string.format("Zlibrary:onSelectSearchBook - Fetch successful for book ID: %s", tostring(api_result.book.id)))

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

        AsyncHelper.runCancellable(task, on_success, on_error_handler, loading_msg)
    end

    attemptBookDetails()
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
        cancellable = true,
        hasValidApiResult = function(api_result)
            local ok = type(api_result) == "table" and type(api_result.comments) == "table"
            return ok, not ok and T("No comments to display")
        end,
    }, book.id)
end

return Zlibrary
