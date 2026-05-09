local NetworkMgr = require("ui/network/manager")
local Font = require("ui/font")
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
}
-- fix no_title = true koreader crash
function M:mergeTitleBarIntoLayout()
    if self.no_title then
        return
    end
   Menu.mergeTitleBarIntoLayout(self)
end

local function downloadCover(url, cache_path)
    if type(url) ~= "string" or type(cache_path) ~= "string" then return false end
    if util.fileExists(cache_path) then return true end

    local temp_path = cache_path .. ".downloading"
    if util.fileExists(temp_path) then util.removeFile(temp_path) end

    local download_result = Api.downloadBookCover(url, temp_path)
    if not download_result or download_result.error or not download_result.success then
        if util.fileExists(temp_path) then util.removeFile(temp_path) end
        -- if return is empty, retry
        return nil
    end
    local cover_bb = RenderImage:renderImageFile(temp_path, false, nil, nil)  
    if not cover_bb then
        logger.err("[downloadCover] Image corrupted, deleted:", url)
        util.removeFile(temp_path)
        return nil
    end
    cover_bb = nil
    local rename_success, err = os.rename(temp_path, cache_path)
    return rename_success ~= nil
end


local function attachCover(item, cover_w, cover_h)
    if not (item and item.hash) then return nil end
    local cover_cache_path = Cache:getCoverPath(item.hash)

    if util.fileExists(cover_cache_path) then
        item._is_cover_cached = true
        item.state = CenterContainer:new{
            dimen = Geom:new{ w = cover_w, h = cover_h },
            ImageWidget:new{ 
                -- image = cover_bb, 
                file = cover_cache_path,
                width = cover_w, 
                height = cover_h, 
                scale_factor = 0, 
                file_do_cache = true, 
                image_disposable = true,
            }
        }
        return cover_cache_path
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

    return cover_cache_path
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

        self._cover_channel = self._cover_channel or AsyncHelper:createChannel("Menu_Covers", 4)

        if tonumber(self.perpage) ~= 8 then
            self.items_per_page = 8
            self:_recalculateDimen()
            perpage = self.perpage
            current_page = self.page
            idx_offset = (current_page - 1) * perpage
        end

        -- data digest, used to detect page changes
        local new_last_page_summary = tostring(first_item.hash) .. "_" .. tostring(perpage)

        local cover_h = self.item_dimen.h - 2 * Size.line.medium 
        local cover_w = math.floor(cover_h * 2 / 3)
        self.state_w = cover_w + 8 * Size.padding.small 

        for idx = 1, perpage do
            local item = self.item_table[idx_offset + idx]
            if item then attachCover(item, cover_w, cover_h) end
        end

        if new_last_page_summary ~= self._last_page_summary then
            logger.info("[menucovers] Page change detected, restarting task...")
            self._last_page_summary = new_last_page_summary
            self._cover_channel:clearTasks()

            -- debounce
            if self._debounce_timer_cancel then 
                self._debounce_timer_cancel() 
                logger.info("[menucovers] Previous publish schedule cancelled")
            end

            if not NetworkMgr:isConnected() then return false end
            
            self._debounce_timer_cancel = AsyncHelper.delay(1, function()
                self._debounce_timer_cancel = nil
                if self.page ~= current_page then return end

                logger.info("[menucovers] Stopped, collecting covers...")
                
                local missing_covers = {}
                for idx = 1, perpage do
                    local item = self.item_table[idx_offset + idx]
                    if item and item.cover and item.hash then
                        local cache_path = Cache:getCoverPath(item.hash)
                        if not item._is_cover_cached then
                            table.insert(missing_covers, { item = item, path = cache_path })
                        end
                    end
                end

                if #missing_covers == 0 then 
                    logger.info("[menucovers] all covers ready")
                    return 
                end

                self._cover_channel:executeBatch({
                    items = missing_covers,
                    task_func = downloadCover,
                    max_retries = 2,
                    get_task_args = function(req)
                        return { req.item.cover, req.path } 
                    end,
                    on_item_end = function(idx, req, success)
                        req = req or {}
                        if success and req.item and util.fileExists(req.path) then
                            UIManager:nextTick(function()
                                if not (type(self) == "table" and self.page) then return end
                                -- callback, page unchanged
                                if self.page == current_page then
                                    self:updateItems(nil, true)
                                    UIManager:setDirty(self, "ui")
                                end
                            end)
                        end
                        return false 
                    end
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
    Menu.onCloseWidget(self)
end

return M