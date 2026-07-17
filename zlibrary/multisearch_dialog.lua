local Device = require("device")
local Blitbuffer = require("ffi/blitbuffer")
local Size = require("ui/size")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local Menu = require("zlibrary.menu")
local IconButton = require("ui/widget/iconbutton")
local ButtonDialog = require("ui/widget/buttondialog")
local TitleBar = require("ui/widget/titlebar")
local ToggleSwitch = require("ui/widget/toggleswitch")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup = require("ui/widget/verticalgroup")
local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local Screen = Device.screen
local T = require("zlibrary.gettext")
local Cache = require("zlibrary.cache")
local logger = require("logger")

local SearchDialog = InputContainer:extend{
    title = T("Z-library search"),
    width = nil,
    height = nil,
    toggle_items = nil,
    def_position = nil,
    def_search_input = nil,
    on_search_callback = nil,
    on_select_book_callback = nil,
    on_similar_books_callback = nil,
    on_fetch_and_show = nil,
    current_page_loaded = nil,
    has_more_api_results = nil,
    show_cover = nil,
    list_per_page = nil,
    books = nil,
    _position = nil,
    _cache = nil,
}

function SearchDialog:init()
    self.width = Screen:getWidth()
    self.height = Screen:getHeight()
    self._position = self.def_position or 1
    self.books = self.books or {}
    self.build_focus_layout = not Device:isTouchDevice() and Device:hasDPad() and Device:useDPadAsActionKeys()

    if type(self.on_select_book_callback) ~= "function" then
        logger.warn("MultiSearchDialog on_select_book_callback is undefined")
        self.on_select_book_callback = function(book)
        end
    end

    if type(self.on_search_callback) ~= 'function' then
        logger.warn("MultiSearchDialog on_search_callback is undefined")
        self.on_search_callback = function(def_input)
        end
    end

    local toggle_text_list, toggle_values = {}, {}
    if not (type(self.toggle_items) == "table" and #self.toggle_items > 0) then
        error("MultiSearchDialog ToggleSwitch not configured")
    end
    for i, v in ipairs(self.toggle_items) do
        if type(v) == 'table' and v["text"] then
            table.insert(toggle_text_list, v["text"])
            table.insert(toggle_values, i)
        end
    end

    local toggle_items_count = #self.toggle_items
    self._position = math.max(1, math.min(self._position, toggle_items_count))

    local frame_padding = Size.padding.default
    local frame_bordersize = Size.border.thin
    local frame_inner_width = self.width - 2 * frame_padding - 2 * frame_bordersize
    local frame_inner_height = self.height - 2 * frame_padding - 2 * frame_bordersize

    local titlebar = TitleBar:new{
        title = self.title,
        with_bottom_line = true,
        left_icon = "appbar.search",
        left_icon_size_ratio = 0.9,
        right_icon_size_ratio = 0.9,
        left_icon_tap_callback = function()
            self.on_search_callback(self.def_search_input)
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
            self:forceFetchAndReloadMenu()
        end
    }

    local has_multiple_items = toggle_items_count ~= 1
    local filter_width = frame_inner_width - force_refresh_button.width - force_refresh_button.padding_right
    self.toggle_switch = ToggleSwitch:new{
        width = filter_width,
        font_size = 20,
        alternate = false,
        enabled = has_multiple_items,
        toggle = toggle_text_list,
        values = toggle_values,
        config = {
            onConfigChoose = function(_, _values, name, event, args, _position)
                local position = type(_position) == "number" and _position or tonumber(name)
                UIManager:nextTick(function()
                    self:ToggleSwitchCallBack(position)
                end)
            end
        }
    }
    self.toggle_switch:setPosition(self._position)

    local filter_group = HorizontalGroup:new{
        dimen = Geom:new{
            w = frame_inner_width
        },
        align = "center",
        self.toggle_switch ,
        force_refresh_button
    }

    self.compound_title_bar = VerticalGroup:new{
        align = "left",
        titlebar,
        filter_group,
        _titlebar = titlebar,
        _toggle = self.toggle_switch,
        _refresh = force_refresh_button,
    }

    function self.compound_title_bar:getHeight() return self:getSize().h end
    function self.compound_title_bar:setTitle(...) end
    function self.compound_title_bar:setSubTitle(...) end
    function self.compound_title_bar:setLeftIcon(...) end

    local dialog = self 
    function self.compound_title_bar:generateVerticalLayout()
        local layout = {}
        if self._titlebar and self._titlebar.generateVerticalLayout then
            local tb_layout = self._titlebar:generateVerticalLayout()
            if tb_layout then
                for _, row in ipairs(tb_layout) do
                    table.insert(layout, row)
                end
            end
        end
        if dialog.build_focus_layout then
            table.insert(layout, { self._toggle, self._refresh })
        end
        return layout
    end

    self.menu_container = self:createMenuContainer(self.books, frame_inner_height)

    local frame = FrameContainer:new{
        width = self.width,
        height = self.height,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = frame_bordersize,
        bordercolor = Blitbuffer.COLOR_BLACK,
        padding = frame_padding,
        self.menu_container
    }
    self[1] = frame

    self.menu_container.onMenuSelect = function(_, item)
        self:onMenuSelect(item)
    end
    self.menu_container.onMenuHold= function(_, item)
        self:onMenuHold(item)
    end
    self.menu_container.onGotoPage = function(menu_instance, page)
        self:onMenuGotoPage(menu_instance, page)
    end
    
    if self.build_focus_layout then
        self.menu_container.key_events.Close = nil
        self.menu_container.key_events.FocusRight = nil
        self.menu_container.key_events.Right = nil
        self.toggle_switch:disableFocusManagement(self[1])
    end

    self._cache = Cache:new{
        name = "multi_search"
    }
end

function SearchDialog:onKeyPress(key)
    if type(key) ~= "table" then return false end
    if key["Tab"] or (self.build_focus_layout and key["Right"]) then
        local position = self._position + 1
        if position > #self.toggle_items then position = 1 end
        self.toggle_switch:togglePosition(position, true)
        UIManager:nextTick(function()
            self:ToggleSwitchCallBack(position)
        end)
        return true
    elseif key["Menu"] then
        self.on_search_callback(self.def_search_input)
        return true
    elseif key["Home"] then
        self:forceFetchAndReloadMenu()
        return true
    elseif key["Back"] then
        UIManager:close(self)
        return true
    end
    return InputContainer.onKeyPress(self, key)
end

function SearchDialog:ToggleSwitchCallBack(_position)
    if not (type(_position) == 'number' and _position > 0) then
        logger.warn("MultiSearchDialog.ToggleSwitchCallBack invalid parameter")
        return
    end

    self._position = _position
    self:clearMenuItems()
  
    local cache_key, cache_expiry = self:getActiveItemCacheKey()
    if cache_key then
        local cache_books = self._cache:get(cache_key, cache_expiry)
        if cache_books then
            self:reloadFromBookData(cache_books, true)
            return true
        end
    end

    self:_fetchAndProcessData()
end

function SearchDialog:_getMenuItems(books)
    local menu_items = {}
    if type(books) ~= "table" then return menu_items end

    local current_toggle = self:getActiveItem()
    local mandatory_func = current_toggle and current_toggle.mandatory_func
    
    local title, author, menu_text, mandatory_text
    local is_show_cover = self.show_cover
    for i, book in ipairs(books) do
        title = book.title or T("Untitled")
        author = book.author or T("Unknown Author")
        menu_text = string.format("\u{FFF1}\u{FFF2}%s\u{FFF3} - %s", title, author)
        mandatory_text = mandatory_func and mandatory_func(book)

        table.insert(menu_items, {
            book_index = i,
            text = menu_text,
            mandatory = mandatory_text,
            book_id = book.id,
            hash = book.hash,
            cover = is_show_cover and book.cover or nil,
        })
    end
    return menu_items
end

function SearchDialog:_fetchAndProcessData(page, is_refresh)
    local current_toggle = self:getActiveItem()
    local item_callback = current_toggle and current_toggle.callback
    if type(item_callback) == "function" then
        UIManager:nextTick(function()
            item_callback(self, page, is_refresh)
        end)
    end
end

function SearchDialog:reloadFromBookData(books, skip_cache, select_number, no_recalculate_dimen)
    local old_height = self.menu_container.height
    self.menu_container = self:createMenuContainer(books, old_height)

    self.menu_container:updateItems(select_number, no_recalculate_dimen)

    if not skip_cache then
        local cache_key = self:getActiveItemCacheKey()
        if cache_key and type(self.books) == "table" then
            self._cache:insert(cache_key, self.books)
        end
    end
end

function SearchDialog:fetchAndShow()
    UIManager:show(self)
    if not (self.books and #self.books > 0) then
        self:ToggleSwitchCallBack(self._position)
    else
        self:reloadFromBookData(self.books)
    end

    if type(self.on_fetch_and_show) == "function" then 
        self.on_fetch_and_show(self)
    end
    
    if not self.def_position then
        self.on_search_callback(self.def_search_input)
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
            no_title = false,
            custom_title_bar = self.compound_title_bar,
            show_captions = true,
            is_borderless = true,
            multilines_show_more_text = true,
            show_parent = self,
            show_cover = self.show_cover,
            list_per_page = self.list_per_page,
        }
    else
        self.menu_container.item_table = menu_items
    end
    return self.menu_container
end

function SearchDialog:clearMenuItems()
    self.books = {}
    if self.menu_container then
        self.menu_container.item_table = {}
        Menu.updateItems(self.menu_container)
    end
end

function SearchDialog:forceFetchAndReloadMenu()
   local cache_key = self:getActiveItemCacheKey()
   if cache_key then
        self._cache:remove(cache_key)
   end
   self:clearMenuItems()
   self:_fetchAndProcessData(nil, true)
end

function SearchDialog:onMenuSelect(item)
    if not (item and item.book_index) then
        return true
    end
    local book = self.books[item.book_index]
    self.on_select_book_callback(book)
    return true
end

function SearchDialog:onMenuHold(item)
    local book = self.books[item.book_index]
    if type(book) ~= "table" and not book.author and not book.title then
        return
    end

    local dialog
    local buttons = {}
    if book.title then
        local button_text = string.format("%s: %s", T("Title"), book.title)
        table.insert(buttons, {{
            text = button_text,
            callback = function()
                UIManager:close(dialog)
                self.on_search_callback(tostring(book.title))
            end
        }})
    end
    if book.author then
        local button_text = string.format("%s: %s", T("Author"), book.author)
        table.insert(buttons, {{
            text = button_text,
            callback = function()
                UIManager:close(dialog)
                self.on_search_callback(tostring(book.author))
            end
        }})
    end
    if book.id and book.hash and type(self.on_similar_books_callback) == 'function' then
        table.insert(buttons, {{
            text = T("More Similar Books"),
            callback = function()
                UIManager:close(dialog)
                self.on_similar_books_callback(book)
            end
        }})
    end

    -- A tab may offer an action that only makes sense on its own list, e.g. removing a book from the
    -- downloaded history. Read it off the active tab rather than test the position, so the tabs stay
    -- free to move.
    local active_item = self:getActiveItem()
    local book_action = type(active_item) == "table" and active_item.book_action or nil
    if book.id and type(book_action) == "table" and type(book_action.callback) == "function" then
        table.insert(buttons, {{
            text = book_action.text,
            callback = function()
                UIManager:close(dialog)
                book_action.callback(self, book)
            end
        }})
    end
    dialog = ButtonDialog:new{
        buttons = buttons,
        title = string.format("\u{f002} %s", T("Search")),
        title_align = "center"
    }
    UIManager:show(dialog)
end

-- Can be appended multiple times, then call reloadFromBookData(nil, nil, 1)
function SearchDialog:extendBatchData(books)
    if not self.current_page_loaded or self.current_page_loaded == 1 then
        self.books = {}
    end
    if type(books) ~= "table" then return self.books end
    for _, book in ipairs(books) do
        table.insert(self.books, book)
    end
    return self.books
end

function SearchDialog:appendBatchDataAndReload(books)
    self:extendBatchData(books)
    self:reloadFromBookData(nil, nil, 1)
end

function SearchDialog:setPaginationState(has_more_results, current_page)
    self.has_more_api_results = has_more_results
    self.current_page_loaded = current_page
end

function SearchDialog:onMenuGotoPage(menu_instance, new_page)
    Menu.onGotoPage(menu_instance, new_page)

    local is_last_page = new_page == menu_instance.page_num
    if not (is_last_page and self.has_more_api_results and self:_isEnablePagination()) then
        return true
    end

    logger.dbg(string.format("MultiSearchDialo.GotoPage gexecuting paginated fetch, current page %s", new_page))
    self:_fetchAndProcessData((self.current_page_loaded or 1) + 1)
    return true
end

function SearchDialog:getActiveItem()
    return self.toggle_items[self._position]
end

function SearchDialog:_isEnablePagination()
    local current_toggle = self:getActiveItem()
    if current_toggle then
        return current_toggle["enable_pagination"] == true
    end
end

function SearchDialog:getActiveItemCacheKey()
    local current_toggle = self:getActiveItem()
    if current_toggle then
        return current_toggle["cache_key"], current_toggle["cache_expiry"]
    end
end

function SearchDialog:setToggleTitle(position, title)  
    local toggle_switch = self.toggle_switch
    local toggle_items_count = #self.toggle_items
     if position > toggle_items_count or position < 1 then return end
    if not (toggle_switch.toggle_content and toggle_switch.n_pos) then return end  
      
    local n_pos = toggle_switch.n_pos  
    local row = math.ceil(position / n_pos)  
    local col = ((position - 1) % n_pos) + 1  
      
    local button = toggle_switch.toggle_content[row][col]  
    if button and button[1] and button[1][1] then  
        button[1][1]:setText(title)  
        UIManager:setDirty("all", "ui")
    else
        self.toggle_items[position].text = title or ""
        self:free()
        self.menu_container = nil 
        self:init()
        UIManager:setDirty("all", "ui")
    end
end

return SearchDialog