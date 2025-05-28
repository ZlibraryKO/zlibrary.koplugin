local Screen = require("device").screen
local Blitbuffer = require("ffi/blitbuffer")

local Font = require("ui/font")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")

local Menu = require("ui/widget/menu")
local TitleBar = require("ui/widget/titlebar")
local ToggleSwitch = require("ui/widget/toggleswitch")
local VerticalGroup = require("ui/widget/verticalgroup")
local FrameContainer = require("ui/widget/container/framecontainer")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local T = require("zlibrary.gettext")

local SearchDialog = WidgetContainer:extend {
  width = Screen:getWidth(),
  height = Screen:getHeight(),
  padding = Screen:scaleBySize(5),
  filter_select = nil,
  refresh_func_list = nil,
  menu_items = nil,
  search_func = nil
}

function SearchDialog:init()
  local titlebar = TitleBar:new {
      title = T("Z-library search"), 
      with_bottom_line = true,
      left_icon = "appbar.search",
      left_icon_tap_callback = function()
           if self.search_func then
              self.search_func()
           end
      end,
      close_callback = function()
        UIManager:close(self)
      end
  }
  local titlebar_size = titlebar:getSize()

  local filter = ToggleSwitch:new {
      width = self.width,
      toggle = {
          T("Recommended"), T("Most popular")
      },
      values = {"Recommended", "Most popular"},
      config = self,
      alternate = false,
  }
  filter:setPosition(1)

  local filter_size = filter:getSize()
  local menu_container_height = self.height - titlebar_size.h - filter_size.h

  self.menu_container = self:buildMenuContainer(self.menu_items, menu_container_height)

  self.container_parent = VerticalGroup:new {
    dimen = Geom:new {
      w = self.width,
      h = menu_container_height,
    },
    self.menu_container
  }

  local frame = FrameContainer:new {
    width = self.width,
    height = self.height,
    background = Blitbuffer.COLOR_WHITE,
    bordersize = 2,
    bordercolor = Blitbuffer.COLOR_BLACK,
    padding = 2,
    VerticalGroup:new {
      align = "left", 
      titlebar,
      filter,
      self.container_parent,
    }
  }

  self[1] = frame
  pcall(self.refresh_func_list["Recommended"]) 
end

function SearchDialog:onConfigChoose(_values, _name, _event, _args, position)
    if _values and self.filter_select ~= _values[position] then
      self.filter_select = _values[position]
      local refresh_func = self.refresh_func_list[self.filter_select]
      if type(self.refresh_func_list) == 'table' and type(refresh_func) == 'function' then
            local ok, err = pcall(refresh_func) 
            if not ok then
               logger.warn("refresh_func err: ", err)
            end
      end
    end
end

function SearchDialog:refreshContainer(menu_items)
  local old_height = self.menu_container.height
  self.menu_items = menu_items or self.menu_items
  self.menu_container:free()
  self.menu_container = self:buildMenuContainer(self.menu_items, old_height)
  self.container_parent[1] = self.menu_container

  UIManager:nextTick(function()
    UIManager:setDirty(self, "ui", self.menu_container.dimen)
  end)
end

function SearchDialog:buildMenuContainer(menu_items, height)
  menu_items = menu_items or {}
  local menu = Menu:new {
    width = self.width - Screen:scaleBySize(6),
    height = height,
    item_table = menu_items,
    is_popout = false,
    --no_title = true,
    show_captions = true,
    is_borderless = true,
    multilines_show_more_text = true,
    show_parent = self,
  }
  return menu
end

return SearchDialog
