-- The cover in the details dialog: loading it from the cache or fetching it, rounded corners, the
-- drop shadow, and swapping it in when it arrives late. Part of the details dialog; see
-- bookdetails_dialog.lua.

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Screen = Device.screen
local Geom = require("ui/geometry")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local TextWidget = require("ui/widget/textwidget")
local ImageWidget = require("ui/widget/imagewidget")
local util = require("util")
local T = require("zlibrary.gettext")
local Cache = require("zlibrary.cache")

local BookDetailsDialog = require("zlibrary.bookdetails_core")

local function applyRoundedCorners(frame_widget, border_size)
    local r = math.floor(Screen:scaleBySize(6))
    local r_inner = r - border_size
    local orig_pt = frame_widget.paintTo

    local cut_table = {}
    for j = 0, r - 1 do
        local inner = math.sqrt(r * r - (r - j) * (r - j))
        cut_table[j] = math.ceil(r - inner)
    end
    local border_pixels = {}
    for j = 0, r - 1 do
        border_pixels[j] = {}
        for c = 0, r - 1 do
            local dx, dy = r - c - 0.5, r - j - 0.5
            local dist = math.sqrt(dx * dx + dy * dy)
            border_pixels[j][c] = (dist >= r_inner and dist <= r)
        end
    end
    frame_widget.paintTo = function(self, bb, x, y)
        orig_pt(self, bb, x, y)
        if not (self.dimen and self.dimen.x) then return end
        local tx, ty, tw, th = self.dimen.x, self.dimen.y, self.dimen.w, self.dimen.h
        local wh, blk = Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_BLACK
        for j = 0, r - 1 do
            local cut = cut_table[j]
            if cut > 0 then
                bb:paintRect(tx, ty + j, cut, 1, wh)
                bb:paintRect(tx + tw - cut, ty + j, cut, 1, wh)
                bb:paintRect(tx, ty + th - 1 - j, cut, 1, wh)
                bb:paintRect(tx + tw - cut, ty + th - 1 - j, cut, 1, wh)
            end
            for c = 0, r - 1 do
                if border_pixels[j][c] then
                    bb:paintRect(tx + c, ty + j, 1, 1, blk)
                    bb:paintRect(tx + tw - 1 - c, ty + j, 1, 1, blk)
                    bb:paintRect(tx + c, ty + th - 1 - j, 1, 1, blk)
                    bb:paintRect(tx + tw - 1 - c, ty + th - 1 - j, 1, 1, blk)
                end
            end
        end
    end
end

function BookDetailsDialog:_buildCoverComponent()
    local book_hash = self.book.hash
    local cover_url = self.book.cover
    local cover_cache = Cache:new{ type="cover" }
    local cached_cover_path = cover_cache:get(book_hash)
    local cover_inner_widget
    if cached_cover_path and util.fileExists(cached_cover_path) then
        cover_inner_widget = ImageWidget:new{
            file = cached_cover_path, width = self.cover_max_w, height = self.cover_max_h, scale_factor = 0, file_do_cache = true, alpha = false
        }
    else
        cover_inner_widget = CenterContainer:new{
            dimen = Geom:new{ w = self.cover_max_w, h = self.cover_max_h },
            TextWidget:new{ text = "\u{23F3}\n\n" .. T("Cover"), face = self.fonts.cover, align = "center", fgcolor = Blitbuffer.COLOR_DARK_GRAY }
        }

        local preLoader = self.parent_zlibrary and self.parent_zlibrary.preLoader
        if preLoader and preLoader.getBookCover and cover_url and cover_url ~= "" and book_hash then
             preLoader.getBookCover(cover_url, book_hash, function(is_cached)
                    if is_cached ~= true then return end
                    if self._is_closed ~= true then
                        self:refreshCoverImage(cover_cache:get(book_hash))
                    else
                        -- Landed after the dialog closed: the list it was opened from can still show it.
                        UIManager:broadcastEvent(Event:new("ZlibraryCoverCached"))
                    end
            end)
        end
    end
    local backgrounds = {
        Blitbuffer.COLOR_LIGHT_GRAY,
        Blitbuffer.COLOR_GRAY_D,
        Blitbuffer.COLOR_GRAY_E,
    }
    local cover_frame = FrameContainer:new{
        radius = Size.radius.default, color = Blitbuffer.COLOR_GRAY_3,
        margin = 0,  padding = 0, bordersize = self.border, background = backgrounds[2],
        width = self.cover_total_w, height = self.framed_h, cover_inner_widget
    }
    applyRoundedCorners(cover_inner_widget, self.border)
    return cover_frame
end

function BookDetailsDialog:_applyCoverPaintShadow(cover_component)
    local orig_cover_paintTo = cover_component.paintTo
    local offset = self.pop_out_offset
    local shadow_thickness = math.floor(Screen:scaleBySize(5))
    local shadow_color = Blitbuffer.COLOR_GRAY_D
    cover_component.paintTo = function(widget, bb, x, y)
        local target_y = y and (y - offset) or nil
        if widget.dimen and x and target_y then
            local w, h = widget.dimen.w, widget.dimen.h
            bb:paintRect(x + w, target_y + shadow_thickness, shadow_thickness, h - shadow_thickness, shadow_color)
            bb:paintRect(x + shadow_thickness, target_y + h, w, shadow_thickness, shadow_color)
        end
        orig_cover_paintTo(widget, bb, x, target_y)
    end
end

function BookDetailsDialog:refreshCoverImage(new_image_path)
    if not (new_image_path and util.fileExists(new_image_path)) then return end
    if self.cover_frame then
        local new_cover_widget = ImageWidget:new{
            file = new_image_path, width = self.cover_max_w, height = self.cover_max_h, scale_factor = 0, file_do_cache = true, alpha = false
        }
        if self.cover_frame[1] and type(self.cover_frame[1].free) == "function" then
            self.cover_frame[1]:free()
        end
        self.cover_frame[1] = new_cover_widget
        new_cover_widget.parent = self.cover_frame 
        applyRoundedCorners(new_cover_widget, self.border)
        UIManager:setDirty(self, "ui")
    end
end

return BookDetailsDialog
