local Screen = require("device").screen
local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local TitleBar = require("ui/widget/titlebar")
local ToggleSwitch = require("ui/widget/toggleswitch")
local VerticalGroup = require("ui/widget/verticalgroup")
local FrameContainer = require("ui/widget/container/framecontainer")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local T = require("zlibrary.gettext")
local logger = require("logger")

local SearchDialog = WidgetContainer:extend{
    width = Screen:getWidth(),
    height = Screen:getHeight(),
    padding = Screen:scaleBySize(5),
    switch_refresh_fns = {},
    switch_list = {},
    switch_values = {},
    books = nil,
    position = nil,
    title = nil,
    filter_select = nil,
    search_func = nil,
    cache = nil,
    cache_expiry = nil,
    parent_zlibrary = nil,
    parent_ui_ref = nil
}

function SearchDialog:init()
    self.position = self.position or 1
    self.title = self.title or T("Z-library search")
    self.books = self.books or {}
    self.cache_expiry = self.cache_expiry or 600

    local titlebar = TitleBar:new{
        title = self.title,
        with_bottom_line = true,
        left_icon = "appbar.search",
        left_icon_size_ratio = 0.9,
        left_icon_allow_flash = true,
        left_icon_tap_callback = function()
            if type(self.search_func) ~= 'function' then
                logger.warn("SearchDialog search_func is undefined")
            end
            self.search_func()
        end,
        close_callback = function()
            UIManager:close(self)
        end
    }
    local titlebar_size = titlebar:getSize()

    local filter = ToggleSwitch:new{
        width = self.width,
        toggle = self.switch_list,
        values = self.switch_values,
        config = self,
        font_size = 20,
        alternate = false
    }
    filter:setPosition(self.position)

    local filter_size = filter:getSize()
    local menu_container_height = self.height - titlebar_size.h - filter_size.h

    self.menu_container = self:createMenuContainer(self.books, menu_container_height)
    self.container_parent = VerticalGroup:new{
        dimen = Geom:new{
            w = self.width,
            h = menu_container_height
        },
        self.menu_container
    }

    local frame = FrameContainer:new{
        width = self.width,
        height = self.height,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 2,
        bordercolor = Blitbuffer.COLOR_BLACK,
        padding = 2,
        VerticalGroup:new{
            align = "left",
            titlebar,
            filter,
            self.container_parent
        }
    }
    self[1] = frame
    self.menu_container.onMenuChoice = function(_, item)
        local book = self.books[item.book_index]
        self.parent_zlibrary:onSelectRecommendedBook(book)
    end
    self.cache = LuaSettings:open(string.format("%s/cache/zlibrary.cache.db", DataStorage:getDataDir()))
end

function SearchDialog:getCache(key)
    if not(key and self.cache and self.cache.data)then 
        return 
    end
    local uptime_key =  key .. "_ut"
    local uptime = self.cache.data[uptime_key]
    if not uptime or os.time() - uptime > self.cache_expiry then 
        self.cache.data[key] = nil
        return 
    end
    return self.cache.data[key]
end

function SearchDialog:addCache(key, object)
    if not (key and object and self.cache) then 
        return
    end
    local uptime_key = key .. "_ut"
    self.cache:saveSetting(key, object)
    self.cache:saveSetting(uptime_key, os.time()):flush()
end

function SearchDialog:onConfigChoose(_values, name, event, args, _position)
    if not (type(_position) == 'number' and _position > 0 and type(_values) == 'table' and _values[1]) then
        logger.warn("SearchDialog.onConfigChoose invalid parameter")
        return
    end

    if _values[_position] and self.filter_select ~= _values[_position] then
        self.filter_select = _values[_position]
        local cache_books = self:getCache(self.filter_select)
        if cache_books then
            -- use cached data
            self:refreshContainer(cache_books, true)
            return
        else
            if not (type(self.switch_refresh_fns) == 'table' and type(self.switch_refresh_fns[self.filter_select]) ==
                'function') then
                logger.warn("SearchDialog.onConfigChoose switch_refresh_fns is undefined")
                return
            end
            
            local refresh_func = self.switch_refresh_fns[self.filter_select]
            UIManager:nextTick(function()
                local ok, err = pcall(refresh_func)
                if not ok then
                    logger.warn("SearchDialog.onConfigChoose refresh_func err: ", err)
                end
            end)
        end
    end
end

function SearchDialog:getMenuItems(books)
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

function SearchDialog:refreshContainer(books, is_cache)
    local old_height = self.menu_container.height
    self.menu_container = self:createMenuContainer(books, old_height)
    Menu.updateItems(self.menu_container)
    if not is_cache and self.cache and self.filter_select and self.books and #self.books > 0 then
        local cache_key = self.filter_select
        local uptime_key =  cache_key .. "_ut"
        self:addCache(self.filter_select, self.books)
    end
end

function SearchDialog:fetchAndShow()
    UIManager:show(self)
    self:onConfigChoose(self.switch_values, nil, nil, nil, self.position)
end

function SearchDialog:createMenuContainer(books, height)
    self.books = books or self.books
    local menu_items = self:getMenuItems(books)
    if not self.menu_container then
        self.menu_container = Menu:new{
            width = self.width - Screen:scaleBySize(6),
            height = height,
            item_table = menu_items,
            is_popout = false,
            -- no_title = true,
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

return SearchDialog
