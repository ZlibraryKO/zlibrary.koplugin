local NetworkMgr = require("ui/network/manager")
local Font = require("ui/font")
local Screen = require("device").screen
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local ImageWidget = require("ui/widget/imagewidget")
local util = require("util")
local UIManager = require("ui/uimanager") 
local Geom = require("ui/geometry")
local Size = require("ui/size")
local logger = require("logger")
local Menu = require("ui/widget/menu")
local PreLoader = require("zlibrary.preloader").Preloader
local PreHelper = require("zlibrary.preloader").helper
local AsyncHelper = require("zlibrary.async_helper")
local Api = require("zlibrary.api")
local Cache = require("zlibrary.cache")

local M = Menu:extend{
    _cover_channel = nil,
    _debounce_timer_cancel = nil,
    _last_page_summary = nil,
    _is_closed = nil,
    list_per_page = nil,
    show_cover = nil,
    is_enable_shortcut = false,
}
-- fix no_title = true koreader crash
function M:mergeTitleBarIntoLayout()
    if self.no_title then 
        return
    end
   Menu.mergeTitleBarIntoLayout(self)
end
function M:init()
    self._is_closed = false
    Menu.init(self)
    if self.show_cover then
        PreLoader.getFavoriteBookIds()
    end
end

local function _updateItemsBuildUI(item, cover_w, cover_h)
    if not (item and item.hash) then return nil end
    local cover_cache_path = item._is_cover_loaded or Cache:new{ type="cover" }:get(item.hash)

    if cover_cache_path then
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
        return cover_cache_path
    end

    local border = Size.border.thin
    local in_w, in_h = cover_w - 2 * border, cover_h - 2 * border
    item.state = FrameContainer:new{
        width = cover_w, height = cover_h, 
        bordersize = border, margin = 0, padding = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = in_w, h = in_h },
            TextBoxWidget:new{
                text = "⛶",
                face = Font:getFace("cfont", math.floor(in_h * 0.2)),
                width = in_w, alignment = "center",
            }
        }
    }
end

function M:getCoverItemsPerPage()
    if not self.inner_dimen then return 10 end
    local scale_by_size = Screen:scaleBySize(1000000) / 1000000  
    local top_height = (self.title_bar and not self.no_title) and self.title_bar:getHeight() or 0 
    local bottom_height = 0
    if self.page_return_arrow and self.page_info_text then 
        bottom_height = math.max(self.page_return_arrow:getSize().h, self.page_info_text:getSize().h) + Size.padding.button
    end 
    local available_height = self.inner_dimen.h - top_height - bottom_height
    local items_per_page = math.floor(available_height / scale_by_size / 120)
    return math.max(3, math.min(14, items_per_page))
end

function M:_updateCoverItems(select_number, no_recalculate_dimen)
    if not self.show_cover then return end
    if not self.item_table or self.items_max_lines then return end
    local perpage = self.perpage
    local current_page = self.page
    local idx_offset = (current_page - 1) * perpage
    local first_item = self.item_table[idx_offset + 1]
    if not (first_item and first_item.hash) then return end

    local cover_h = self._cached_cover_h
    local cover_w = self._cached_cover_w
    for idx = 1, perpage do
        local item = self.item_table[idx_offset + idx]
        if item and item.hash then
            item._is_cover_loaded = _updateItemsBuildUI(item, cover_w, cover_h)
        end
    end

    -- data digest, used to detect page changes
    local new_last_page_summary = tostring(first_item.hash) .. "_" .. tostring(perpage)
    local is_summary_changed = (new_last_page_summary ~= self._last_page_summary)
    if not is_summary_changed then return false end

    logger.info("[menucovers] Page change detected, restarting task...")
    self._last_page_summary = new_last_page_summary
    self._cover_channel = self._cover_channel or AsyncHelper:createChannel("Menu_Covers", 4)
    self:_clearTasks()
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
        local added_hashes = {}
        for idx = 1, perpage do
            local item = self.item_table[idx_offset + idx]
            if item and item.cover and item.hash then
                if not (item._is_cover_loaded or added_hashes[item.hash]) then
                    table.insert(missing_covers, { item = item })
                    added_hashes[item.hash] = true
                end
            end
            if item and item.book_id and item.hash then
                PreLoader.getBookDetails(item.book_id, item.hash)
                PreLoader.getBookComments(item.book_id, item.hash)
            end
        end

        if #missing_covers == 0 then
            logger.dbg("[menucovers] all covers ready")
            return
        end

        local cover_cache = Cache:new{ type = "cover" }
        self._cover_channel:executeBatch({
            items = missing_covers,
            task_func = PreHelper.downloadCover,
            max_retries = 2,
            get_task_args = function(req)
                return {req.item.cover, req.item.hash, true}
            end,
            on_item_end = function(idx, req, success)
                if self._is_closed or self.page ~= current_page then return false end
                if success and req and req.item and req.item.hash then
                    if cover_cache:get(req.item.hash) then
                        logger.dbg(" [covermenu]page unchanged, callback refresh menu item:", req.item.hash)
                        UIManager:nextTick(function()
                            if self._is_closed or self.page ~= current_page then return false end
                            self:updateItems(nil, true)
                        end)
                    end
                end
                return false
            end
        })
    end) 
end

function M:_recalculateDimen()
    if not self.list_per_page then
        self.list_per_page = self.show_cover and self:getCoverItemsPerPage() or G_reader_settings:readSetting("items_per_page") or 10
    end
    if tonumber(self.perpage) ~= self.list_per_page then
        self.items_per_page = self.list_per_page
    end
    Menu._recalculateDimen(self)
    if self.show_cover and self.item_dimen then
        self._cached_cover_h = self.item_dimen.h - 2 * Size.line.medium 
        self._cached_cover_w = math.floor(self._cached_cover_h * 2 / 3)
        self.state_w = self._cached_cover_w + 8 * Size.padding.small
    end
end
function M:updateItems(select_number, no_recalculate_dimen)
    if self.show_cover then self:_updateCoverItems(select_number, no_recalculate_dimen) end
    return Menu.updateItems(self, select_number, no_recalculate_dimen)
end

function M:_clearTasks()
    if self._cover_channel then self._cover_channel:clearTasks() end
    if PreLoader and PreLoader.channel then PreLoader.channel:clearTasks() end
end

function M:onCloseWidget()
    self:_clearTasks()
    self._last_page_summary = nil
    self._is_closed = true
    self.list_per_page = nil
    if self._debounce_timer_cancel then
        self._debounce_timer_cancel()
        self._debounce_timer_cancel = nil
    end
    Menu.onCloseWidget(self)
end

return M