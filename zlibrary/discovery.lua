-- Finding a Z-library mirror that answers.
--
-- Lifted out of main.lua unchanged. It was 346 lines -- a fifth of that file -- and touched
-- exactly one field of the plugin instance, self.discover_channel, calling no method on it but
-- itself. A feature that happened to live on the plugin object rather than part of it.
--
-- The parameter really is named `self`, which is why the body below is byte-for-byte what it was
-- in main.lua: a move that changes no line cannot change behaviour, and that is worth more here
-- than a tidier signature. main.lua keeps a one-line method delegating to this, so the recursive
-- call inside, and Ui's call on the plugin instance, both still resolve.

local Api = require("zlibrary.api")
local AsyncHelper = require("zlibrary.async_helper")
local Cache = require("zlibrary.cache")
local Config = require("zlibrary.config")
local Device = require("device")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local Ui = require("zlibrary.ui")
local T = require("zlibrary.gettext")
local logger = require("logger")

local Discovery = {}

function Discovery.run(self, is_interactive, retry_callback)
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

return Discovery
