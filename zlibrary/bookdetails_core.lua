-- The book details dialog: the class itself, building and sizing the dialog, switching between
-- the button list, Description and Comments, key focus, the refresh region, and closing. The parts
-- (bookdetails_book, _content, _cover, _buttons, _comments) add the rest of its methods to this
-- class; bookdetails_dialog.lua loads them all. See there.

local Device = require("device")
local Screen = Device.screen
local Font = require("ui/font")
local Geom = require("ui/geometry")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonTable = require("ui/widget/buttontable")
local FocusManager = require("ui/widget/focusmanager")
local InputContainer = require("ui/widget/container/inputcontainer")
local util = require("util")

local BookDetailsDialog = InputContainer:extend{
    title = nil,
    title_align = "center",
    view_state = "menu",
    _is_closed = nil,
}

function BookDetailsDialog:init()
    self.book = self:_sanitizeBookData(self.raw_book or {})
    self.raw_book = nil
    self._is_closed = nil
    self.is_cache = (type(self.clear_cache_callback) == "function")
    self.has_favorite_ids_cache = self.parent_zlibrary:isBookInFavorites()
    self.full_title = util.htmlEntitiesToUtf8(self.book.title)
    self.full_author = util.htmlEntitiesToUtf8(self.book.author)
    self.show_parent = self.parent_zlibrary.ui
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.fonts = {
        title = Font:getFace("cfont", 22),
        author = Font:getFace("cfont", 17),
        meta = Font:getFace("cfont", 15),
        cover = Font:getFace("cfont", 16)
    }
    self:_buildInnerDialog()
    if not self.has_favorite_ids_cache then 
        self.parent_zlibrary.preLoader.getFavoriteBookIds(function(precheck_ok)
            if precheck_ok == true and UIManager:isWidgetShown(self) then
                self:switchState(self.view_state)
            end
        end)
    end
end

function BookDetailsDialog:_buildInnerDialog()
    self:_calculateDimensions()
    -- Buttons first: their height decides how much is left for the content, and it differs per view
    -- (the description and comments views collapse to a single "Back" row).
    local dialog_buttons = self:_buildButtons()
    self._content_h = self:_contentBudget(dialog_buttons)
    local content = self:_buildContent()
    self.inner_dialog = ButtonDialog:new{
        title = self.title,
        title_align = self.title_align,
        buttons = dialog_buttons,
        width = self.dlg_w,
        --dismissable = false,
        _added_widgets = { content },
        show_parent = self,
    }
    -- ButtonDialog wraps itself in a MovableContainer, so the dialog can be dragged around by
    -- hold-and-pan. Nothing here benefits from being repositioned, and it is easy to knock askew by
    -- accident: MovableContainer listens for touch/hold/pan/swipe across the WHOLE screen, which
    -- also puts it in competition with the description's own swipe-to-scroll. MovableContainer
    -- supports an `unmovable` flag for exactly this, but ButtonDialog does not forward it and the
    -- gestures are registered during init, so clear them here instead. The container itself has to
    -- stay: ButtonDialog uses self.movable.dimen for its refresh region and tap-outside handling.
    if self.inner_dialog.movable then
        self.inner_dialog.movable.unmovable = true
        self.inner_dialog.movable.ges_events = {}
    end
    if Device:hasDPad() then
        self:_addKeyFocusRows()
    end

    local wrapper = self
    self.inner_dialog.onClose = function()
        if wrapper.view_state == "menu" then
            UIManager:close(wrapper)
        else
            wrapper:switchState("menu")
        end
    end
    if self.scrollable_html then
        self.scrollable_html.dialog = self
    end
    self[1] = self.inner_dialog
end

-- How much vertical room the content (header + divider + text) may use in the current view.
--
-- The dialog has to be the same height in every view, otherwise it visibly jumps when you press
-- Description or Comments. ButtonDialog sizes itself to what it holds, and everything except our content
-- and the button rows is constant, so keeping (content + buttons) constant keeps the whole dialog
-- constant. Measure the real button block for this view -- it is the full stack in the menu but a
-- single "Back" row in the others -- and hand the remainder to the content. A view with fewer
-- buttons simply gets more reading room, at the same overall size.
--
-- Note the chrome figure below need not be perfect: an error in it shifts every view equally, so it
-- can make the dialog slightly smaller or larger overall but can never reintroduce the jump.
function BookDetailsDialog:_contentBudget(buttons)
    local probe = ButtonTable:new{
        buttons = buttons,
        width = self.dlg_w - 2 * Size.border.window - 2 * Size.padding.button,
        show_parent = self,
    }
    local buttons_h = probe:getSize().h
    if type(probe.free) == "function" then probe:free() end

    -- ButtonDialog's own paddings/margins, plus the frame it wraps our content in.
    local chrome_h = 2 * Size.padding.buttontable + 2 * Size.margin.default
                   + 2 * Size.padding.large + 2 * Size.margin.title
                   + Size.line.medium

    local target_h = Screen:getHeight()
    -- The margin above the popped-out cover comes out of the same budget, so it shifts the content
    -- down without making the dialog taller.
    return math.max(target_h - buttons_h - chrome_h - (self.cover_top_margin or 0), Screen:scaleBySize(120))
end

function BookDetailsDialog:_calculateDimensions()
    self.border = Size.border.thin
    self.gap = math.floor(Screen:scaleBySize(16))
    self.left_padding = math.floor(Screen:scaleBySize(16))
    self.right_padding = math.floor(Screen:scaleBySize(20))
    -- The dialog fills the screen, so a cover floating above it would be cut off by the screen edge.
    self.pop_out_offset = 0
    -- This span is taken out of the content budget in _contentBudget, so adding it cannot change the
    -- dialog's overall height.
    self.cover_top_margin = math.floor(Screen:scaleBySize(12))

    self.dlg_w = math.min(Screen:getWidth(), Screen:getHeight())
    self.avail_w = math.floor(self.dlg_w - 2 * (Size.border.window + Size.padding.button) - 2 * (Size.padding.default + Size.margin.default))

    self.cover_max_w = math.floor(Screen:scaleBySize(160))
    -- scaleBySize keys off the SHORTER screen edge, so an uncapped cover is exactly as tall in
    -- landscape as in portrait -- about 40% of a short screen. Together with the button stack that
    -- leaves nothing for the text and makes ButtonDialog wrap the buttons in a scroll container.
    -- Cap against the real screen height; in portrait this is not binding.
    self.cover_max_h = math.min(math.floor(Screen:scaleBySize(240)), math.floor(Screen:getHeight() * 0.30))
    self.framed_h = self.cover_max_h + 2 * self.border
    self.cover_total_w = self.cover_max_w + 2 * self.border
    
    self.text_col_w = math.floor(math.max(self.avail_w - self.cover_total_w - self.left_padding - self.gap - self.right_padding, Screen:scaleBySize(100)))
end

function BookDetailsDialog:switchState(new_state)
    local orig_dimen = self.inner_dialog.dimen and self.inner_dialog.dimen:copy()
    -- Leaving the button list (for Description or Comments, or rebuilding it in place): note which
    -- button had focus, so coming back lands on it rather than on the first one.
    if self.view_state == "menu" and self.inner_dialog and self.inner_dialog.selected then
        local focused = self.inner_dialog:getFocusItem()
        self._menu_focus = { text = focused and focused.text, y = self.inner_dialog.selected.y }
    end
    self.view_state = new_state
    if self.inner_dialog then
        if type(self.inner_dialog.onCloseWidget) == "function" then
            self.inner_dialog:onCloseWidget()
        end
        if type(self.inner_dialog.free) == "function" then
            self.inner_dialog:free()
        end
    end
    self[1] = nil
    self.inner_dialog = nil
    self.scrollable_html = nil
    self.cover_frame = nil
    self:_buildInnerDialog()
    -- UIManager:setDirty("all", "flashui")
    UIManager:setDirty("all", function()
        local current_region = self:getRefreshRegion()
        local refresh_dimen = current_region
        if orig_dimen and type(orig_dimen.combine) == "function" then
            refresh_dimen = orig_dimen:combine(current_region)
        end
        return "ui", refresh_dimen
    end)
end

-- Focus for a reader without a touchscreen, who moves it with keys.
--
-- The author and ISBN lines act on a tap, and a tap is all they listened for: with keys, focus
-- went from button to button and never reached them. Put them above the buttons in the focus
-- order, so Up from the first button lands on them; Press sends them a tap like any button.
--
-- Then focus a button explicitly. ButtonDialog merges the buttons into its own focus order when it
-- carries extra widgets, as this one does, and that merge unfocuses the preselected button and
-- leaves it so: focus was on it, but nothing showed which. In the button list it goes back to the
-- button that was used last (switchState), otherwise to the preselected one.
function BookDetailsDialog:_addKeyFocusRows()
    local dialog = self.inner_dialog
    if not (dialog.layout and dialog.selected) then return end
    local rows = self._key_focus_rows or {}
    for i, widget in ipairs(rows) do
        table.insert(dialog.layout, i, { widget })
    end
    local y = #rows + 1
    local remembered = self.view_state == "menu" and self._menu_focus
    if remembered then
        local found
        for row = #rows + 1, #dialog.layout do
            local widget = dialog.layout[row][1]
            if remembered.text and widget and widget.text == remembered.text then
                found = row
                break
            end
        end
        -- The text changes for one button (Add To / Remove From Favorites): fall back to its row.
        y = found or math.max(1, math.min(remembered.y, #dialog.layout))
    end
    dialog:moveFocusTo(1, y, FocusManager.FOCUS_ONLY_ON_NT)
end

function BookDetailsDialog:getRefreshRegion()
    local inner = self.inner_dialog or self[1]
    if inner then
        local inner_region = inner.getRefreshRegion and inner:getRefreshRegion() or inner.dimen
        if inner_region then
            local offset = self.pop_out_offset or math.floor(Screen:scaleBySize(40))
            local shadow_thickness = math.floor(Screen:scaleBySize(5))
            return Geom:new{
                x = inner_region.x,
                y = math.max(0, inner_region.y - offset),
                w = inner_region.w,
                h = inner_region.h + offset + shadow_thickness
            }
        end
    end
    return self.dimen
end

function BookDetailsDialog:onCloseWidget()
    self._is_closed = true
    if self.inner_dialog and type(self.inner_dialog.onCloseWidget) == "function" then
        self.inner_dialog:onCloseWidget()
    end
    UIManager:setDirty(self.inner_dialog, function()
        return "flashui", self:getRefreshRegion()
   end)
    -- The list this was opened from may be showing a blank slot for a cover fetched while the
    -- dialog was open. Next tick, so the dialog is off the window stack before the list redraws.
    UIManager:nextTick(function()
        UIManager:broadcastEvent(Event:new("ZlibraryCoverCached"))
    end)
end

return BookDetailsDialog
