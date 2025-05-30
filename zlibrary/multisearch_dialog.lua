local Screen = require("device").screen
local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local Size = require("ui/size")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local Menu = require("zlibrary.menu")
local IconButton = require("ui/widget/iconbutton")
local TitleBar = require("ui/widget/titlebar")
local ToggleSwitch = require("ui/widget/toggleswitch")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup = require("ui/widget/verticalgroup")
local FrameContainer = require("ui/widget/container/framecontainer")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local util = require("util")
local T = require("zlibrary.gettext")
local logger = require("logger")

local SearchDialog = WidgetContainer:extend{
    title = T("Z-library search"),
    width = nil,
    height = nil,
    toggle_items = nil,
    position = nil,
    search_tap_callback = nil,
    parent_zlibrary = nil,
    parent_ui_ref = nil,
    books = nil,
    _cache = nil
}

function SearchDialog:init()
    self.width = Screen:getWidth()
    self.height = Screen:getHeight()
    self.position = self.position or 1
    self.books = self.books or {}

    local toggle_text_list, toggle_values = {}, {}
    if not (type(self.toggle_items) == "table" and #self.toggle_items > 0) then
        error("SearchDialog ToggleSwitch not configured")
    end
    for i, v in ipairs(self.toggle_items) do
        if type(v) == 'table' and v["text"] then
            table.insert(toggle_text_list, v["text"])
            table.insert(toggle_values, i)
        end
    end

    local toggle_items_count = #self.toggle_items
    if self.position > toggle_items_count then
        self.position = toggle_items_count
    end
    
    local frame_padding = Size.padding.default
    local frame_bordersize = Size.border.thin
    local frame_inner_width = self.width - 2 * frame_padding - 2 * frame_bordersize
    local frame_inner_hight = self.height - 2 * frame_padding - 2 * frame_bordersize

    local titlebar = TitleBar:new{
        title = self.title,
        with_bottom_line = true,
        left_icon = "appbar.search",
        left_icon_size_ratio = 0.9,
        left_icon_allow_flash = true,
        left_icon_tap_callback = function()
            if type(self.search_tap_callback) ~= 'function' then
                logger.warn("SearchDialog search_tap_callback is undefined")
                return
            end
            self.search_tap_callback()
        end,
        close_callback = function()
            UIManager:close(self)
        end
    }

    local icon_size = Size.item.height_default + 2 * Size.padding.default + 2 * Size.border.thin
    local force_refresh_button = IconButton:new{
        icon = "cre.render.reload",
        height = icon_size,
        width = icon_size,
        padding_right = Size.padding.button,
        callback = function()
            self:forceRefreshMenuItems()
        end
    }

    local has_multiple_items = toggle_items_count ~= 1
    local filter_width = frame_inner_width - force_refresh_button.width - force_refresh_button.padding_right
    local filter = ToggleSwitch:new{
        width = filter_width,
        font_size = 20,
        alternate = false,
        enabled = has_multiple_items,
        toggle = toggle_text_list,
        values = toggle_values,
        config = {
            onConfigChoose = function(_, _values, name, event, args, _position)
                -- compatible with older versions
                local position = type(_position) == "number" and _position or tonumber(name)
                self:ToggleSwitchCallBack(position)
            end
        }
    }

    local filter_group = HorizontalGroup:new{
        dimen = Geom:new{
            w = frame_inner_width
        },
        align = "center",
        filter,
        force_refresh_button
    }
    filter:setPosition(self.position)

    local titlebar_size = titlebar:getSize()
    local filter_size = filter:getSize()
    local menu_container_height = frame_inner_hight - titlebar_size.h - filter_size.h
    self.menu_container = self:createMenuContainer(self.books, menu_container_height)
    self.container_parent = VerticalGroup:new{
        dimen = Geom:new{
            w = frame_inner_width,
            h = menu_container_height
        },
        self.menu_container
    }

    local frame = FrameContainer:new{
        width = self.width,
        height = self.height,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = frame_bordersize,
        bordercolor = Blitbuffer.COLOR_BLACK,
        padding = frame_padding,
        VerticalGroup:new{
            align = "left",
            titlebar,
            filter_group,
            self.container_parent
        }
    }
    self[1] = frame
    self.menu_container.onMenuChoice = function(_, item)
        local book = self.books[item.book_index]
        self.parent_zlibrary:onSelectRecommendedBook(book)
    end
    self._cache = LuaSettings:open(string.format("%s/cache/zlibrary.cache.db", DataStorage:getDataDir()))
end

function SearchDialog:getCache(key, cache_expiry)
    if not (key and self._cache and self._cache.data) then
        return
    end
    cache_expiry = cache_expiry or 86400
    local uptime_key = key .. "_ut"
    local uptime = self._cache.data[uptime_key]
    if not uptime or os.time() - uptime > cache_expiry then
        self._cache:delSetting(key)
        return
    end
    return self._cache.data[key]
end

function SearchDialog:addCache(key, object)
    if not (key and self._cache and type(object) == "table" and next(object)) then
        return
    end
    local uptime_key = key .. "_ut"
    self._cache:saveSetting(key, object)
    self._cache:saveSetting(uptime_key, os.time()):flush()
end

function SearchDialog:ToggleSwitchCallBack(_position)
    if not (type(_position) == 'number' and _position > 0) then
        logger.warn("SearchDialog.ToggleSwitchCallBack invalid parameter")
        return
    end
    local toggle_item = self.toggle_items[_position]
    if type(toggle_item) ~= "table" then
        return
    end

    self.position = _position
    self:resetMenuItems()

    local cache_key = toggle_item["cache_key"]
    if cache_key then
        local cache_expiry = toggle_item["cache_expiry"]
        local cache_books = self:getCache(cache_key, cache_expiry)
        if cache_books then
            -- use cached data
            self:refreshMenuItems(cache_books, true)
            return true
        end
    end

    local toggle_item_callback = toggle_item["callback"]
    if type(toggle_item_callback) == "function" then
        UIManager:nextTick(function()
            local ok, err = pcall(toggle_item_callback, self)
            if not ok then
                logger.warn("SearchDialog.ToggleSwitchCallBack callback err: ", err)
            end
        end)
    end
end

function SearchDialog:_getMenuItems(books)
    local menu_items = {}
    for i, book in ipairs(books) do
        local title = book.title or T("Untitled")
        local author = book.author or T("Unknown Author")
        local menu_text = string.format("%s - %s", title, author)
        table.insert(menu_items, {
            text = menu_text,
            book_index = i
        })
    end
    return menu_items
end

function SearchDialog:refreshMenuItems(books, is_cache)
    local old_height = self.menu_container.height
    self.menu_container = self:createMenuContainer(books, old_height)
    Menu.updateItems(self.menu_container)

    local toggle_item = self.toggle_items[self.position]
    if not is_cache and toggle_item and toggle_item["cache_key"] then
        local cache_key = toggle_item["cache_key"]
        self:addCache(cache_key, self.books)
    end
end

function SearchDialog:fetchAndShow()
    UIManager:show(self)
    if not (self.books and #self.books > 0) then
        self:ToggleSwitchCallBack(self.position)
    else
        self:refreshMenuItems(self.books)
    end
end

function SearchDialog:createMenuContainer(books, height)
    self.books = books or self.books
    local menu_items = self:_getMenuItems(self.books)
    if not self.menu_container then
        self.menu_container = Menu:new{
            width = self.width - Screen:scaleBySize(6),
            height = height,
            item_table = menu_items,
            is_popout = false,
            no_title = true,
            show_captions = true,
            is_borderless = true,
            multilines_show_more_text = true,
            show_parent = self
        }
    else
        self.menu_container.item_table = menu_items
    end
    return self.menu_container
end

function SearchDialog:resetMenuItems()
    if self.menu_container then
        self.menu_container.item_table = {}
        Menu.updateItems(self.menu_container)
    end
end

function SearchDialog:forceRefreshMenuItems()
    if not (self._cache and self._cache.delSetting) then
        return
    end
    local toggle_item = self.toggle_items[self.position]
    if toggle_item and toggle_item["cache_key"] then
        local cache_key = toggle_item["cache_key"]
        self._cache:delSetting(cache_key)
    end
    self:ToggleSwitchCallBack(self.position)
end

return SearchDialog
