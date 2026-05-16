local NetworkMgr = require("ui/network/manager")
local Font = require("ui/font")
local Screen = require("device").screen
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local ImageWidget = require("ui/widget/imagewidget")
local AsyncHelper = require("zlibrary.async_helper")
local Api = require("zlibrary.api")
local util = require("util")
local RenderImage = require("ui/renderimage")
local UIManager = require("ui/uimanager") 
local Geom = require("ui/geometry")
local Size = require("ui/size")
local Cache = require("zlibrary.cache")
local logger = require("logger")
local Menu = require("ui/widget/menu")

local M = Menu:extend{
    _cover_channel = nil,
    _debounce_timer_cancel = nil,
    _last_page_summary = nil,
    _last_page = nil,
    list_cover_per_page = nil,
    is_enable_shortcut = false,
}
-- fix no_title = true koreader crash
function M:mergeTitleBarIntoLayout()
    if self.no_title then
        return
    end
   Menu.mergeTitleBarIntoLayout(self)
end

local function downloadCover(url, book_hash)
    if type(url) ~= "string" or type(book_hash) ~= "string" then return false end
    local cover_cache = Cache:new{ type="cover" }
    
    local cache_path = cover_cache:get(book_hash)
    if cache_path then return true end

    local temp_path = cover_cache:getTempPath(book_hash)
    if util.fileExists(temp_path) then util.removeFile(temp_path) end

    local download_result = Api.downloadBookCover(url, temp_path)
    if not download_result or download_result.error or not download_result.success then
        if util.fileExists(temp_path) then util.removeFile(temp_path) end
        -- if return false, retry
        return false
    end
    local cover_bb = RenderImage:renderImageFile(temp_path, false, nil, nil)  
    if not cover_bb then
        logger.err("[downloadCover] Image corrupted, deleted:", url)
        util.removeFile(temp_path)
        return false
    end
    if cover_bb.free then cover_bb:free() end
    cover_cache:insert(book_hash, temp_path)
    return true
end


local function _updateItemsBuildUI(item, cover_w, cover_h)
    if not (item and item.hash) then return nil end
    local cover_cache = Cache:new{ type="cover" }
    local cover_cache_path = cover_cache:get(item.hash)

    if cover_cache_path then
        item._is_cover_cached = true
        item.state = CenterContainer:new{
            dimen = Geom:new{ w = cover_w, h = cover_h },
            ImageWidget:new{ 
                file = cover_cache_path,
                width = cover_w, 
                height = cover_h, 
                scale_factor = 0, 
                file_do_cache = true,
                alpha = false,
                use_legacy_image_scaling = true,
            }
        }
        return true
    end

    local bordersize = Size.border.thin
    local icon_text = "⛶"
    local icon_scale_ratio = 0.2

    local inner_w = cover_w - 2 * bordersize
    local inner_h = cover_h - 2 * bordersize
    local icon_fsize = math.floor(inner_h * icon_scale_ratio)

    item.state = FrameContainer:new{
        width = cover_w,
        height = cover_h,
        bordersize = bordersize,
        margin = 0,
        padding = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            TextBoxWidget:new{
                text = icon_text,
                face = Font:getFace("cfont", icon_fsize),
                width = inner_w,
                alignment = "center",
            }
        }
    }

    return true
end

function M:getCoverItemsPerPage()
    local scale_by_size = Screen:scaleBySize(1000000) * (1/1000000)  
    
    local top_height = 0  
    if self.title_bar and not self.no_title then  
        top_height = self.title_bar:getHeight()  
    end  
    local bottom_height = 0  
    if self.page_return_arrow and self.page_info_text then  
        bottom_height = math.max(self.page_return_arrow:getSize().h, self.page_info_text:getSize().h)  
                    + Size.padding.button
    end  
    local available_height = self.inner_dimen.h - top_height - bottom_height
    local items_per_page = math.floor(available_height / scale_by_size / 120)
    return math.max(3, math.min(14, items_per_page))
end

function M:updateItems(select_number, no_recalculate_dimen)
    local old_perpage = self.perpage or 14
    local ok, err = pcall(function()
        if not self.item_table or self.items_max_lines then return end
        
        local perpage = self.perpage
        local current_page = self.page
        local idx_offset = (current_page - 1) * perpage
        
        local first_item = self.item_table[idx_offset + 1]
        if not (first_item and first_item.cover and first_item.hash) then return end

        -- data digest, used to detect page changes
        local new_last_page_summary = tostring(first_item.hash) .. "_" .. tostring(perpage)
        if not self.list_cover_per_page then self.list_cover_per_page = self:getCoverItemsPerPage() end
        local is_perpage_changed = (tonumber(perpage) ~= self.list_cover_per_page)
        local is_page_unchanged = (current_page == self._last_page) 
        local is_summary_changed = (new_last_page_summary ~= self._last_page_summary)

        if is_perpage_changed or (is_page_unchanged and is_summary_changed) then
            self.items_per_page = self.list_cover_per_page
            self:_recalculateDimen()
            perpage = self.perpage
            current_page = self.page
            idx_offset = (current_page - 1) * perpage
        end

        local cover_h = self.item_dimen.h - 2 * Size.line.medium 
        local cover_w = math.floor(cover_h * 2 / 3)
        self.state_w = cover_w + 8 * Size.padding.small 

        for idx = 1, perpage do
            local item = self.item_table[idx_offset + idx]
            if item then _updateItemsBuildUI(item, cover_w, cover_h) end
        end

        self._last_page = current_page
        if new_last_page_summary ~= self._last_page_summary then
            logger.info("[menucovers] Page change detected, restarting task...")
            self._last_page_summary = new_last_page_summary
            self._cover_channel = self._cover_channel or AsyncHelper:createChannel("Menu_Covers", 4)
            self._cover_channel:clearTasks()

            -- debounce
            if self._debounce_timer_cancel then 
                self._debounce_timer_cancel() 
                logger.dbg("[menucovers] Previous publish schedule cancelled")
            end

            if not NetworkMgr:isConnected() then return false end
            
            self._debounce_timer_cancel = AsyncHelper.delay(1, function()
                self._debounce_timer_cancel = nil
                if self.page ~= current_page then return end

                logger.dbg("[menucovers] Stopped, collecting covers...")
                
                local missing_covers = {}
                for idx = 1, perpage do
                    local item = self.item_table[idx_offset + idx]
                    if item and item.cover and item.hash then
                        if not item._is_cover_cached then
                            table.insert(missing_covers, { item = item })
                        end
                    end
                end

                if #missing_covers == 0 then 
                    logger.dbg("[menucovers] all covers ready")
                    return 
                end

                local cover_cache = Cache:new{ type="cover" }
                self._cover_channel:executeBatch({
                    items = missing_covers,
                    task_func = downloadCover,
                    max_retries = 2,
                   get_task_args = function(req)
                        return { req.item.cover, req.item.hash }
                    end,
                    on_item_end = function(idx, req, success)
                        req = req or {}
                        if success and req.item and req.item.hash then
                            local cover_cache_path = cover_cache:get(req.item.hash)
                            if cover_cache_path and type(self) == "table" and self.page == current_page then
                                  logger.dbg(" [covermenu]page unchanged, callback refresh menu item:", req.item.hash)
                                  UIManager:nextTick(function()
                                        self:updateItems(nil, true)
                                        UIManager:setDirty(self, "ui")
                                   end)
                            end
                        end
                        return false 
                    end,
                })
            end)
        end
    end)

    if not ok then
        logger.err("[menucovers] Cover preprocessing crashed:", tostring(err))
        self.items_per_page = old_perpage
        self:_recalculateDimen()
        pcall(Menu.updateItems, self, select_number, no_recalculate_dimen)
    else
        return Menu.updateItems(self, select_number, no_recalculate_dimen)
    end
end

function M:onCloseWidget()
    if self._cover_channel then self._cover_channel:clearTasks() end
    self._last_page_summary = nil
    self._last_page = nil
    self.list_cover_per_page = nil
    Menu.onCloseWidget(self)
end

return M