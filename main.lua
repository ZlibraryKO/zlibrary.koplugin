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

function Zlibrary:autoDiscoverAndSetBaseUrl(is_interactive, retry_callback)
    if not is_interactive and NetworkMgr:willRerunWhenOnline(function()
        self:autoDiscoverAndSetBaseUrl(is_interactive, retry_callback)
    end) then return end

    logger.info("Zlibrary:autoDiscoverAndSetBaseUrl - START")
    local loading_msg = false
    local safe_close_loading_msg = function()
        if type(loading_msg) == "table" then 
            UIManager:close(loading_msg)
            loading_msg = false
        end
    end
    self.discover_channel = self.discover_channel or AsyncHelper:createChannel("findWorkingBaseUrl", 3, safe_close_loading_msg)

    local function getCleanUrl(url)
        if type(url) ~= "string" then return "" end
        return url:gsub("^https?://", ""):gsub("/+$", "")
    end

    local domains_cache = Cache:new{ name = "_domains_cache" }
    local check_cache = Cache:new{ name = "_domains_check_cache" }

    local function refreshDomainsCache(callback)
        local task_channel = self.discover_channel
        local fetch_task = function()
            logger.dbg("Zlibrary - Fetching dynamic domains...")
            local response = Api.fetchDynamicDomains()
            if response and response.success then
                local domains_data = response.domains and response.domains.domains
                if type(domains_data) == "table" then
                    local flat = {}
                    for _, item in ipairs(domains_data) do
                        if type(item.domain) == "string" then table.insert(flat, item.domain) end
                    end
                    if #flat > 0 then 
                        domains_cache:insert("domains", flat)
                        return true 
                    end
                end
            end
            return false -- return false to allow retry
        end
        local on_callback = function(success, res)
            safe_close_loading_msg()
            if is_interactive and not (success and res) then
                Ui.showErrorMessage(T("Operation failed, please retry."))
            end
            if callback then callback(success and res == true) end
        end
        task_channel:pushTask(fetch_task, on_callback, {
            max_retries = 3,
            insert_at_head = true,
            on_start = function()
                loading_msg = Ui.showLoadingMessage(T("Fetching domains..."))
            end
        })
    end

    local health_check_task = function(url) return Api.healthCheck(url, true) end

    local function executeDiscovery()
        local valid_seeds = {}
        for _, item in ipairs(Config.getSeedUrls() or {}) do
            local raw_url = type(item) == "table" and item.url or item
            if type(raw_url) == "string" and raw_url ~= "" then
                table.insert(valid_seeds, { url = raw_url:gsub("/$", ""), src = type(item) == "table" and item.src or "X" })
            end
        end

        local connection_menu, updateBaseUrlItem
        local first_working_url = nil
        -- task status lock
        local is_discovering = false
        local max_idx = 1
        local offset = 3

        local function finishDiscovery()
            is_discovering = false
            safe_close_loading_msg()
            if first_working_url then
                local ok, err = Config.setAndValidateBaseUrl(first_working_url)
                if ok then
                    if not is_interactive and type(retry_callback) == "function" then
                        retry_callback()
                    else
                        Ui.showInfoMessage(T("Successfully set base URL to: ") .. first_working_url)
                        if updateBaseUrlItem then updateBaseUrlItem(first_working_url) end
                    end
                else
                    logger.warn("Zlibrary - URL validation failed: " .. tostring(err))
                end
            elseif not is_interactive then
                Ui.showErrorMessage(T("Failed to find a working base URL."))
            end
        end

        local function initOrResetItem(item, seed)
            if not item then return end
            item.mandatory = "\u{23F3} " .. T("Queued")
            item.mandatory_dim = false
            item.bold = false
            item.callback = Device:hasClipboard() and function()
                Device.input.setClipboardText("https://" .. getCleanUrl(seed.url))
                Ui.showInfoMessage(T("Selection copied to clipboard."))
            end or nil
        end

        local function resetAllItems()
            if is_interactive and connection_menu and connection_menu.item_table then
                for i, seed in ipairs(valid_seeds) do
                    local pos = i + offset
                    initOrResetItem(connection_menu.item_table[pos], seed)
                end
                connection_menu:updateItems(nil, true)
            end
        end

        local function start_discover_task()
            is_discovering = true
            first_working_url = nil
            
            resetAllItems()
            self.discover_channel:executeBatch({
                items = valid_seeds,
                aggregate = true,
                task_func = health_check_task,
                get_task_args = function(seed) return { seed.url } end,
                
                on_start = function(idx, seed)
                    local pos = idx + offset
                    -- Match the on_item_end guard below: clearTasks cannot recall a probe that has
                    -- already forked, so this can still fire after the menu is gone, and
                    -- updateItems would repaint through show_parent onto whatever is on screen now.
                    if is_interactive and connection_menu and UIManager:isWidgetShown(connection_menu) then
                        local item = connection_menu.item_table[pos]
                        if item then
                            item.mandatory = "\u{27F3} " .. T("Checking")
                            item.bold = true
                            item.mandatory_dim = false
                            connection_menu:updateItems(pos, true)
                        end
                    end
                end,
                
                on_item_end = function(idx, seed, success, result)
                    if type(result) ~= "table" then result = {} end

                    -- UI update logic
                    if is_interactive and connection_menu and UIManager:isWidgetShown(connection_menu) then
                        local pos = idx + offset
                        local item = connection_menu.item_table[pos]
                        if item then
                            item.bold = false
                            if success and result.success then
                                item.mandatory = string.format("\u{2714} %dms", result.elapsed or 0)
                                item.mandatory_dim = false
                                item.callback = function()
                                    local ok, err = Config.setAndValidateBaseUrl(seed.url)
                                    if ok then
                                        Ui.showInfoMessage(string.format("%s : %s", T("Set base URL"), seed.url))
                                        updateBaseUrlItem(seed.url)
                                    else
                                        Ui.showErrorMessage(T("Invalid Base URL.") .. " " .. tostring(err))
                                    end
                                end
                            else
                                item.mandatory = "\u{2718} " .. T("Failed")
                                item.mandatory_dim = true
                                item.callback = function() Ui.showInfoMessage(result.error or T("Unknown error")) end
                            end
                            
                            -- auto page-turning logic
                            max_idx = math.max(max_idx, pos)
                            -- only go forward
                            if connection_menu.page < connection_menu:getPageNumber(max_idx) then
                                connection_menu:switchItemTable(nil, nil, max_idx)
                            else
                                connection_menu:updateItems(nil, true)
                            end
                        end
                    end

                    -- early return
                    -- `success` only says the probe ran and returned something. Api.healthCheck reports a
                    -- dead mirror by RETURNING { success = false }, which is a perfectly successful task,
                    -- so the health check's own verdict has to be read too -- exactly as the item display
                    -- above does. Without it the first probe to come back wins, and a mirror that fails
                    -- instantly (NXDOMAIN answers in ~30ms) beats every mirror that actually works.
                    if success and result.success and not first_working_url then
                        first_working_url = seed.url
                        -- return true to break all subsequent tasks
                        if not is_interactive then return true end
                    end
                    return false
                end,
                on_batch_end = function(is_aborted, results_map)
                    if not is_aborted and type(results_map) == "table" and next(results_map) then
                        local filtered_results = {}
                        for i, seed in ipairs(valid_seeds) do
                            if type(seed) == "table" and seed.url and type(results_map[i]) == "table"  then
                                filtered_results[seed.url] = results_map[i].result
                            end
                        end
                        if next(filtered_results) then check_cache:insert("result", filtered_results) end
                    end
                    finishDiscovery()
                end,
            })
        end

        if not is_interactive then
            -- block until done
            loading_msg = Ui.showLoadingMessage(T("Searching for working Z-library server..."))
            return start_discover_task() 
        end

        -- interactive part
        updateBaseUrlItem = function(base)
            if connection_menu and connection_menu.item_table and connection_menu.item_table[1] then
                connection_menu.item_table[1].text = string.format("%s [ %s ]", T("Current Base URL:"), getCleanUrl(base))
                connection_menu:updateItems(nil, true)
            end
        end

        local check_status
        local menu_items = {
            {
                text = string.format("%s  [ %s ]", T("Current Base URL:"), getCleanUrl(Config.getBaseUrl(true))),
                mandatory = "\u{2699}",
                callback = function()
                    local base = Config.getBaseUrl(true)
                    local real = Config.getCacheRealUrl()
                    
                    local build_dialog
                    build_dialog = function(val, info)
                        return Ui.showGenericInputDialog(T("Set base URL"), Config.SETTINGS_BASE_URL_KEY, val, false, function(in_val)
                            local ok, err = Config.setAndValidateBaseUrl(in_val)
                            if ok then updateBaseUrlItem(in_val); return true end
                            Ui.showErrorMessage(err or T("Invalid Base URL.")); return false
                        end, info)
                    end
                    
                    local dlg = build_dialog(base, real and (T("Mirror site redirected to: ") .. real) or nil)
                    
                    if base and base ~= "" and NetworkMgr:isConnected() then
                        if not check_status then
                            -- with debounce
                            check_status = UIManager:debounce(12, true, function()
                                -- queue-jump detection
                                self.discover_channel:pushTask(health_check_task, function(success, res)
                                    if type(res) ~= "table" then res = {} end
                                    -- Same as on_item_end: a returned { success = false } is a successful
                                    -- task reporting a dead mirror, so both have to hold for a tick.
                                    local status = (success and res.success)
                                        and string.format("\u{2714} %dms", res.elapsed or 0)
                                        or ("\u{2718} " .. tostring(res.error or ""))
                                    real = Config.getCacheRealUrl()
                                    local final_info = string.format(" %s \n %s", status, real and (T("Mirror site redirected to: ") .. real) or "")
                                    if dlg then
                                        pcall(function()
                                            local txt = dlg:getInputText()
                                            UIManager:close(dlg)
                                            dlg = build_dialog(txt, final_info)
                                        end)
                                    end
                                end, { args = {base}, insert_at_head = true })
                            end)
                        end
                        check_status()
                    end
                end
            }, {
                text = T("Auto-discover base URL"), 
                mandatory = "\u{25B7}",
                callback = function()
                    if not NetworkMgr:isConnected() then return Ui.showErrorMessage(T("Network unavailable.")) end
                    if is_discovering then return Ui.showInfoMessage(T("Discovery is already running...")) end
                    -- back to first page
                    max_idx = 1
                    UIManager:nextTick(start_discover_task)
                end
            }, { text = "---" }
        }

        offset = #menu_items
        local last_check = check_cache:get("result", 600)
        local has_last_check = (type(last_check) == "table")
        for _, seed in ipairs(valid_seeds) do
            local item = {
                text = string.format("[%s] %s", seed.src, getCleanUrl(seed.url)),
                show_indicator = false
            }
            initOrResetItem(item, seed)
            -- has cache
            if has_last_check and type(last_check[seed.url]) == "table" then
                local url_last_check = last_check[seed.url]
                if url_last_check.success then
                    item.mandatory = string.format("\u{2714} %dms", url_last_check.elapsed or 0)
                    item.callback = function()
                        local ok, err = Config.setAndValidateBaseUrl(seed.url)
                        if ok then
                            Ui.showInfoMessage(string.format("%s : %s", T("Set base URL"), seed.url))
                            if updateBaseUrlItem then updateBaseUrlItem(seed.url) end
                        else
                            Ui.showErrorMessage(T("Invalid Base URL.") .. " " .. tostring(err))
                        end
                    end
                else
                     item.mandatory = "\u{2718} " .. T("Failed")
                     item.mandatory_dim = true
                    item.callback = function() Ui.showInfoMessage(url_last_check.error or T("Unknown error")) end
                end
            end
            table.insert(menu_items, item)
        end
        
        table.insert(menu_items, { text = "---" })
        table.insert(menu_items, {
            text = T("Refresh Dynamic Domains"), mandatory = "\u{25B7}", callback = function()
                if is_discovering then return Ui.showInfoMessage(T("Discovery is already running...")) end
                if not NetworkMgr:isConnected() then return Ui.showErrorMessage(T("Network unavailable.")) end
                if connection_menu then UIManager:close(connection_menu) end
                refreshDomainsCache(function() self:autoDiscoverAndSetBaseUrl(true) end)
        end})
        table.insert(menu_items, { text = T("Back"), mandatory = "\u{21A9}", callback = function()
            if connection_menu and connection_menu.onFirstPage then connection_menu:onFirstPage() end
        end})

        connection_menu = Ui.showUrlCheckProgress(self, menu_items, function()
            -- Clear the state BEFORE clearTasks: it runs the session abort hooks synchronously, and
            -- the batch hook calls on_batch_end -> finishDiscovery, which would otherwise still see
            -- first_working_url and set the base URL the user just walked away from.
            first_working_url = nil
            is_discovering = false
            self.discover_channel:clearTasks()
        end)
    end

    if domains_cache:get("domains", 172800, true) or not NetworkMgr:isConnected() then
        executeDiscovery()
    else
        refreshDomainsCache(executeDiscovery)
    end
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
                    if Api.isAuthenticationError(api_result_more.error) then
                        self:login(function(login_ok)
                            if login_ok then
                                on_goto_page_handler(menu_instance, new_page_number)
                            end
                        end)
                        return
                    end
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
                if Api.isAuthenticationError(err_msg_more) then
                    self:login(function(login_ok)
                        if login_ok then
                            on_goto_page_handler(menu_instance, new_page_number)
                        end
                    end)
                    return
                end
                
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

    self.active_results_menu = Ui.createSearchResultsMenu(self.ui, query_string, menu_items, on_goto_page_handler,  opts)
end

function Zlibrary:downloadBook(book)
    if NetworkMgr:willRerunWhenOnline(function()
        self:downloadBook(book)
    end) then
        return
    end

    if not book.id or not book.hash then
        Ui.showErrorMessage(T("Book identifiers missing. Cannot download."))
        return
    end

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

    local attemptDownload

    -- The child owns the socket, so it cannot drive the parent's progress bar. It does not need to:
    -- it is already writing the bytes to a file we know the name of. Watch that instead. Legal only
    -- because the dismissable run yields while it waits, so UIManager is live to run this.
    -- Not via Trapper's pipe: any byte readable there is taken as the child's final result, which
    -- would both corrupt it and re-block the parent until the child exits.
    local function startProgressPoll(target_filepath, progress_callback, progress_max)
        if not progress_callback or not progress_max then return function() end end
        local temp_filepath = Api.getDownloadTempPath(target_filepath)
        local stopped = false
        local poll
        poll = function()
            if stopped then return end
            local size = lfs.attributes(temp_filepath, "size")
            -- nil while the link is still being resolved, and again once the child has renamed the
            -- file onto the target: neither is a reset to zero. Clamp because the reported size is
            -- catalogue metadata and the body can overrun it; setPercentage does not clamp itself.
            if size then progress_callback(math.min(size, progress_max)) end
            UIManager:scheduleIn(1, poll)
        end
        UIManager:scheduleIn(1, poll)
        return function()
            stopped = true
            UIManager:unschedule(poll)
        end
    end

    -- Resolving the link and fetching the body both block for as long as the network takes. Run them in
    -- a forked child so the UI loop keeps running and the user can tap to cancel: the child cannot yield
    -- out of socket.http (it sits behind socket.protect's C frame), but it does not need to -- blocking
    -- is fine over there, and Trapper yields in the parent while it waits.
    local function runDownloadInSubprocess(user_session, referer_url)
        return Trapper:dismissableRunInSubprocess(function()
            -- This process exists only to return a result table, and it shares the cache file with the
            -- parent. Nothing it writes there can help, and some of it would destroy the parent's copy.
            Config.disableRuntimeCacheWrites()

            logger.info(string.format("Zlibrary:downloadBook - Fetching download link from endpoint for book ID: %s", book.id))
            local link_result = Api.getDownloadLink(user_session and user_session.user_id,
                user_session and user_session.user_key, book.id, book.hash)

            if link_result.error then
                return { success = false, error = link_result.error }
            end

            logger.info(string.format("Zlibrary:downloadBook - Got download link from endpoint: %s", link_result.download_link))

            -- No progress callback: it would run in this process and could not reach the parent's
            -- dialog. The parent watches the temp file instead.
            return Api.downloadBook(link_result.download_link, target_filepath,
                user_session and user_session.user_id, user_session and user_session.user_key,
                referer_url, nil)
        end, false) -- false: an invisible trap widget that swallows the dismissing tap
    end

    attemptDownload = function(retry_on_auth_error, progress_title)
        retry_on_auth_error = retry_on_auth_error == nil and true or retry_on_auth_error

        local user_session = Config.getUserSession()
        local referer_url = book.href and Config.getBookUrl(book.href) or nil
        local loading_msg

        -- The wrap below routes any result carrying .error to on_error_download, so api_result never
        -- has one here; on_error_download owns every failure, including the auth retry.
        local function on_success_download(api_result)
            Ui.closeMessage(loading_msg)
            if api_result and api_result.success then

                -- reset download quota cache
                self:resetDownloadQuotaCache()

                local has_wifi_toggle = Device:hasWifiToggle()
                local default_turn_off_wifi = Config.getTurnOffWifiAfterDownload()

                Ui.confirmOpenBook(filename, has_wifi_toggle, default_turn_off_wifi, function(should_turn_off_wifi)
                    if should_turn_off_wifi then
                        NetworkMgr:disableWifi(function()
                            logger.info("Zlibrary:downloadBook - Wi-Fi disabled after download as requested by user")
                        end)
                    end

                    if ReaderUI then
                        logger.info("Zlibrary:downloadBook - Cleaning up dialogs before opening reader")
                        self.dialog_manager:closeAllDialogs()
                        ReaderUI:showReader(target_filepath)
                    else
                        Ui.showErrorMessage(T("Could not open reader UI."))
                        logger.warn("Zlibrary:downloadBook - ReaderUI not available.")
                    end
                end,
                function(should_turn_off_wifi)
                    if should_turn_off_wifi then
                        NetworkMgr:disableWifi(function()
                            logger.info("Zlibrary:downloadBook - Wi-Fi disabled after download as requested by user")
                        end)
                        logger.info("Zlibrary:downloadBook - Cleaning up dialogs cause wifi is turned off")
                        self.dialog_manager:closeAllDialogs()
                    end
                end
            )
            else
                -- Only reachable when the task returned no result at all; a result carrying .error
                -- went to on_error_download instead.
                Ui.showErrorMessage((api_result and api_result.message) or T("Download failed: Unknown error"))
            end
        end

        local function on_error_download(err_msg)
            if retry_on_auth_error and Api.isAuthenticationError(err_msg) then
                Ui.closeMessage(loading_msg)
                self:login(function(login_ok)
                    if login_ok then
                        attemptDownload(false)
                    end
                end)
                return
            end
            
            local error_string = tostring(err_msg)
            if string.find(error_string, "Download limit reached or file is an HTML page", 1, true) then
                Ui.closeMessage(loading_msg)
                Ui.showErrorMessage(T("Download limit reached. Please try again later or check your account."))
                return
            end
            
            -- Use retry dialog for timeout and network errors
            Ui.showRetryErrorDialog(err_msg, T("Book download"), function()
                -- Retry callback. Re-enter attemptDownload so the retry gets its own wrap: this runs
                -- from a fresh event, outside any coroutine, and an unwrapped dismissable run silently
                -- falls back to blocking in-process.
                attemptDownload(retry_on_auth_error, T("Retrying download… (tap to cancel)"))
            end, function(final_err_msg)
                -- Cancel callback - user already knows about the error. Nothing to clean up:
                -- Api.downloadBook discards its own temp file, and this path is also reached when
                -- Api.getDownloadLink failed and no file was ever created.
            end, loading_msg, "download")
        end

        Trapper:wrap(function()
            -- A previous download that was killed never got to clean up after itself.
            Api.discardDownloadTempFile(target_filepath)

            local progress_callback
            loading_msg, progress_callback = Ui.showBookDownloadProgress(book, progress_title)

            -- Trapper polls the child at up to one second, so a cancel can land after the child has
            -- already renamed the finished book into place. Remember what was there first, so that
            -- case is reported as the success it is instead of stranding a complete book.
            local target_before = lfs.attributes(target_filepath, "modification")

            -- Trapper returns false both for "user dismissed" and for "fork failed". A dismiss cannot
            -- happen without at least one yield, and a fork failure never reaches the poll loop, so
            -- this tells the two apart.
            local yielded = false
            UIManager:nextTick(function() yielded = true end)

            local stop_poll = startProgressPoll(target_filepath, progress_callback, book.filesize)
            local ok, completed, api_result = pcall(runDownloadInSubprocess, user_session, referer_url)
            -- After the pcall, so a throw cannot leave the poll rescheduling against a closed dialog.
            stop_poll()

            if not ok then
                logger.err("Zlibrary:downloadBook - Download failed: " .. tostring(completed))
                Ui.closeMessage(loading_msg)
                Ui.showErrorMessage(T("Download failed: Unknown error"))
                return
            end

            if not completed then
                if lfs.attributes(target_filepath, "modification") ~= target_before then
                    -- The rename beat the kill; the book is whole.
                    return on_success_download({ success = true })
                end
                Api.discardDownloadTempFile(target_filepath)
                Ui.closeMessage(loading_msg)
                Ui.showInfoMessage(yielded and T("Download cancelled.")
                    or T("Download failed: Unknown error"))
                return
            end

            if not api_result then
                Ui.closeMessage(loading_msg)
                Ui.showErrorMessage(T("Download failed: Unknown error"))
                return
            end
            if api_result.error then
                return on_error_download(api_result.error)
            end
            on_success_download(api_result)
        end)
    end

    Ui.confirmDownload(filename, function()
        attemptDownload()
    end)
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