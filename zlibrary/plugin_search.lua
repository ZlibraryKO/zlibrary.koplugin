-- Searching: running a search and the paged results list, which loads more from the server as the
-- reader reaches its last page.
--
-- Part of the plugin class. main.lua used to hold all of it in one 1,579-line file; it now copies
-- the methods each part returns onto the class at load (see the end of main.lua). The methods are
-- written exactly as they were there -- `function Zlibrary:name(...)` on this local table -- so
-- `self` is the plugin instance as before. Diff with --color-moved against the commit before the
-- split to see where the code came from.

local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local T = require("zlibrary.gettext")
local Config = require("zlibrary.config")
local Api = require("zlibrary.api")
local Ui = require("zlibrary.ui")
local AsyncHelper = require("zlibrary.async_helper")
local logger = require("logger")

local Zlibrary = {}

function Zlibrary:performSearch(query)
    if NetworkMgr:willRerunWhenOnline(function()
        self:performSearch(query)
    end) then
        return
    end

    -- No auth-retry here, on purpose. Search works without an account, and a session the server
    -- cannot use is ignored rather than refused: a malformed one still gets results (HTTP 200,
    -- checked 2026-11-10), so a search never answers "Please login". The re-login branches that
    -- used to sit in both handlers could not fire -- and had one ever matched, it would have put
    -- a credentials dialog in the middle of a search. The session itself must still go with every
    -- request: it carries the account's website settings, such as hiding 18+ books.
    local function attemptSearch()
        local user_session = Config.getUserSession()
        local loading_msg = Ui.showCancellableLoadingMessage(string.format(T("Searching for \"%s\"..."), query))

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
            Config.addSearchHistory(query)
            self.current_search_query = query
            self.current_search_api_page_loaded = current_page_to_search
            self.all_search_results_data = api_result.results
            self.has_more_api_results = true

            UIManager:nextTick(function()
                self:displaySearchResults(self.all_search_results_data, self.current_search_query)
            end)
        end

        local on_error_handler = function(err_msg)
            -- Use the retry dialog for timeouts and HTTP 400 errors
            Ui.showSearchErrorDialog(err_msg, query, user_session, selected_languages, selected_extensions, selected_order, current_page_to_search, loading_msg, on_success, function(final_err_msg)
                -- Cancel callback - user already knows about the error
            end)
        end

        AsyncHelper.runCancellable(task, on_success, on_error_handler, loading_msg)
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
            local loading_msg_more = Ui.showCancellableLoadingMessage(string.format(T("Loading more results (Page %s)..."), next_api_page_to_fetch))

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
                    -- The fetch failed with the page counter already advanced; redraw what is
                    -- actually loaded so the display and the counter agree again.
                    menu_instance:updateItems(1, true)
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
                -- Same as the error path above: redraw so the page counter matches the display.
                menu_instance:updateItems(1, true)
            end

            AsyncHelper.runCancellable(task_load_more, on_success_load_more, on_error_load_more, loading_msg_more, function()
                -- Same as the error path above: the page counter was already advanced, so
                -- redraw what is actually loaded to keep display and counter in agreement.
                menu_instance:updateItems(1, true)
            end)
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

return Zlibrary
