local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Screen = Device.screen
local Font = require("ui/font")
local Geom = require("ui/geometry")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local ButtonDialog = require("ui/widget/buttondialog")
local InputContainer = require("ui/widget/container/inputcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local ImageWidget = require("ui/widget/imagewidget")
local LineWidget = require("ui/widget/linewidget")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local GestureRange = require("ui/gesturerange")
local logger = require("logger")
local util = require("util")
local T = require("zlibrary.gettext")
local Cache = require("zlibrary.cache")

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

local function makeClickable(content_widget, callback)
    local container = InputContainer:new{
        ges_events = {TapCustom = { GestureRange:new{ ges = "tap" } }}, 
        content_widget 
    }
    if content_widget.getRefreshRegion then
        container.getRefreshRegion = function(self) return content_widget:getRefreshRegion() end
    end
    function container:onTapCustom(_, ges)
       local target_dimen = self.dimen or (self[1] and self[1].dimen)
        local hit_box = (type(self.getRefreshRegion) == "function" and self:getRefreshRegion()) or target_dimen
        if hit_box and hit_box.contains and ges and ges.pos and hit_box:contains(ges.pos) then
            return callback(self, ges)
        end
        return false 
    end
    return container
end

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
    local content = self:_buildContent()
    local dialog_buttons = self:_buildButtons()
    self.inner_dialog = ButtonDialog:new{
        title = self.title,
        title_align = self.title_align,
        buttons = dialog_buttons,
        --dismissable = false,
        _added_widgets = { content },
        show_parent = self,
    }
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

function BookDetailsDialog:_calculateDimensions()
    self.border = Size.border.thin
    self.gap = math.floor(Screen:scaleBySize(16))
    self.left_padding = math.floor(Screen:scaleBySize(16))
    self.right_padding = math.floor(Screen:scaleBySize(20))
    self.pop_out_offset = math.floor(Screen:scaleBySize(40))
    
    self.dlg_w = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.95)
    self.avail_w = math.floor(self.dlg_w - 2 * (Size.border.window + Size.padding.button) - 2 * (Size.padding.default + Size.margin.default))

    self.cover_max_w = math.floor(Screen:scaleBySize(160))
    self.cover_max_h = math.floor(Screen:scaleBySize(240))
    self.framed_h = self.cover_max_h + 2 * self.border
    self.cover_total_w = self.cover_max_w + 2 * self.border
    
    self.text_col_w = math.floor(math.max(self.avail_w - self.cover_total_w - self.left_padding - self.gap - self.right_padding, Screen:scaleBySize(100)))
end

function BookDetailsDialog:_buildContent()
    local vstack = VerticalGroup:new{ align = "left", not_focusable = true}
    local title_face = self.fonts.title
    local face_height = title_face.ftsize:getHeightAndAscender()
    local title_max_h = math.floor(face_height * 2.2)

    table.insert(vstack, TextBoxWidget:new{
        text = self.full_title,
        face = title_face,
        bold = true,
        alignment = "left",
        width = self.text_col_w,
        height = title_max_h,
        height_adjust = true, 
        height_overflow_show_ellipsis = true 
    })

    local self_ref = self
    if self.full_author ~= "" then
        table.insert(vstack, VerticalSpan:new{ width = math.floor(Screen:scaleBySize(8)) })
        local author_group = HorizontalGroup:new{
            TextWidget:new{
                text = "\u{F0013} " .. self.full_author,
                face = self.fonts.author,
                max_width = math.floor(self.text_col_w - Screen:scaleBySize(25)),
                truncation = "end"
            },
            TextWidget:new{ text = " \u{25B8}", face = self.fonts.author }
        }
        local clickable_author = makeClickable(author_group, function()
            UIManager:close(self_ref)
            self_ref.Ui_module.showSearchDialog(self_ref.parent_zlibrary, self_ref.full_author)
            return true
        end)
        table.insert(vstack, clickable_author)
    end

    local meta_lines = self:_generateMetaLines()
    if #meta_lines > 0 then
        table.insert(vstack, VerticalSpan:new{ width = math.floor(Screen:scaleBySize(10)) })
        for i, line_text in ipairs(meta_lines) do
            table.insert(vstack, TextWidget:new{ text = line_text, face = self.fonts.meta, fgcolor = Blitbuffer.COLOR_GRAY_3, max_width = self.text_col_w })
            if i < #meta_lines then table.insert(vstack, VerticalSpan:new{ width = math.floor(Screen:scaleBySize(4)) }) end
        end
    end

    self.cover_frame = self:_buildCoverComponent()
    self:_applyCoverPaintShadow(self.cover_frame)
    local clickable_cover = makeClickable(self.cover_frame, function()
        self_ref.parent_zlibrary:downloadAndShowCover(self_ref.book)
        return true
    end)
    local header_widget = LeftContainer:new{
        dimen = Geom:new{ w = self.avail_w, h = self.framed_h },
        HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = self.left_padding },
            clickable_cover,
            HorizontalSpan:new{ width = self.gap },
            vstack
        }
    }
    
    local orig_header_getSize = header_widget.getSize
    local offset = self.pop_out_offset
    header_widget.getSize = function(widget)
        local size = orig_header_getSize(widget)
        return Geom:new{ w = size.w, h = math.floor(size.h - offset + Screen:scaleBySize(5)) }
    end

    local content_group = VerticalGroup:new{ not_focusable = true, header_widget }

    if self.view_state == "description" and self.book.description  then
        table.insert(content_group, self:_buildHtmlSection(string.format("  %s  ", T("Profile")), self.book.description))
    elseif self.view_state == "comments" and self.book.comments_html  then
        table.insert(content_group, self:_buildHtmlSection(string.format("  %s  ", T("Comments")), self.book.comments_html, self.book.comments_css))
    end

    return content_group
end

function BookDetailsDialog:_buildHtmlSection(divider_text, raw_html, css)
    local section_group = VerticalGroup:new{ align = "left" }
    local clean_html = raw_html
    local engine_css = [[
        @page { margin: 0; }
        body { margin: 0; padding: 0 12px 0 0; text-align: justify; line-height: 1.4; }
        p, div { margin: 0; margin-bottom: 0.5em; text-indent: 1.5em; }
        a { text-decoration: none; }
        img, iframe { display: none !important; }
    ]]
    if self.view_state == "comments" and type(css) == "string" and css ~= "" then
        engine_css = css
    end
    local safe_h = math.floor(math.max(Screen:getHeight() - self.framed_h - Screen:scaleBySize(520), Screen:scaleBySize(200)))
    self.scrollable_html = ScrollHtmlWidget:new{ 
        html_body = clean_html, 
        width = self.avail_w, 
        scroll_bar_width = Screen:scaleBySize(2),
        text_scroll_span = Screen:scaleBySize(3),
        css = engine_css, 
        height = safe_h 
    }

    table.insert(section_group, VerticalSpan:new{ width = math.floor(Screen:scaleBySize(15)) })
    
    local desc_text_widget = TextWidget:new{ text = divider_text, face = self.fonts.meta, fgcolor = Blitbuffer.COLOR_GRAY_3 }
    local text_size = desc_text_widget:getSize()
    local line_h = math.max(1, math.floor(Screen:scaleBySize(1)))
    local left_line_w = math.max(0, math.floor((self.avail_w - text_size.w) / 2))
    local right_line_w = math.max(0, self.avail_w - left_line_w - text_size.w)
    
    table.insert(section_group, HorizontalGroup:new{
        align = "center",
        LineWidget:new{ dimen = Geom:new{ w = left_line_w, h = line_h }, background = Blitbuffer.COLOR_GRAY_3, style = "solid" },
        desc_text_widget,
        LineWidget:new{ dimen = Geom:new{ w = right_line_w, h = line_h }, background = Blitbuffer.COLOR_GRAY_3, style = "solid" }
    })
    
    table.insert(section_group, VerticalSpan:new{ width = math.floor(Screen:scaleBySize(10)) })
    table.insert(section_group, FrameContainer:new{ padding = 0, bordersize = 0, self.scrollable_html })
    
    return section_group
end

function BookDetailsDialog:_generateMetaLines()
    local meta_lines = {}
    local pub_parts = {}
    if self.book.publisher and self.book.publisher ~= "" then 
        table.insert(pub_parts, util.htmlEntitiesToUtf8(self.book.publisher)) 
    end
    if self.book.year and self.book.year ~= "N/A" and tostring(self.book.year) ~= "0" then
        table.insert(pub_parts, tostring(self.book.year))
    end
    if #pub_parts > 0 then table.insert(meta_lines, table.concat(pub_parts, " · ")) end
    if self.book.series and self.book.series ~= "" then 
        table.insert(meta_lines, util.htmlEntitiesToUtf8(self.book.series)) 
    end
    local tech_parts = {}
    if self.book.lang and self.book.lang ~= "N/A" then 
        table.insert(tech_parts, self.book.lang) 
    end
    if self.book.size and self.book.size ~= "N/A" then 
        table.insert(tech_parts, self.book.size) 
    end
    if self.book.pages and self.book.pages ~= 0 then
        table.insert(tech_parts, self.book.pages .. " " .. T("pages"))
    end
    if self.book.rating and self.book.rating ~= "N/A" then
        local rating_num = tonumber(self.book.rating)
        if rating_num then
            self.book.rating = string.format("%.1f", rating_num)
            table.insert(tech_parts, self.book.rating)
        end
    end
    if self.book.format and self.book.format ~= "N/A" then 
        table.insert(tech_parts, self.book.format:upper()) 
    end
    if #tech_parts > 0 then table.insert(meta_lines, table.concat(tech_parts, " | ")) end

    return meta_lines
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
                    if is_cached == true and self._is_closed ~= true then
                        self:refreshCoverImage(cover_cache:get(book_hash))
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

function BookDetailsDialog:onDownloadClick()
    UIManager:close(self)
    self.parent_zlibrary:downloadBook(self.book)
end

function BookDetailsDialog:_buildButtons()
    local dialog_buttons = {}

    if self.view_state ~= "menu" then
        table.insert(dialog_buttons, {{
            text = "\u{21A9}  " .. T("Back"),  align = "left",
            preselect = true,
            callback = function() self:switchState("menu") end
        }})
        return dialog_buttons
    end

     table.insert(dialog_buttons, {{
        text = "\u{F002}  " .. T("More Similar Books"), align = "left",
        preselect = true,
        callback = function()
            UIManager:close(self)
            self.parent_zlibrary:searchSimilarBooks(self.book)
        end
    }})

    if self.book.format and self.book.format ~= "N/A" then
        if self.book.download then
            table.insert(dialog_buttons, {{
                text = "\u{F019}  " .. string.format("%s (%s)", T("Download"), self.book.format:upper()), align = "left",
                callback = function() self:onDownloadClick() end
            }})
        else
            table.insert(dialog_buttons, {{
                text = "\u{F019}  " .. string.format("%s: %s (Not available)", T("Format"), self.book.format:upper()),
                align = "left", enabled = false
            }})
        end
    elseif self.book.download then
        table.insert(dialog_buttons, {{
            text = "\u{F019}  " .. T("Download book"), align = "left",
            callback = function() self:onDownloadClick() end 
        }})
    end

    table.insert(dialog_buttons, {{
        text = "\u{F02D}  " .. T("Profile"), align = "left",
        callback = function() self:switchState("description") end
    }})

    table.insert(dialog_buttons, {{
        text = "\u{F0E5}  " .. T("Comments"), align = "left",
        callback = function()
            if type(self.parent_zlibrary.fetchAndDisplayComments) == "function" then
                self.parent_zlibrary:fetchAndDisplayComments(self.book, false, function(book_comments)
                    local comments_html, css = self:_renderComments(book_comments)
                    self.book.comments_html = comments_html
                    self.book.comments_css= css
                    self:switchState("comments")
                end)
            end
        end
    }})

    if self.has_favorite_ids_cache then
        table.insert(dialog_buttons, {self:_generateFavoriteButtonDef(self.parent_zlibrary:isBookInFavorites(self.book) == true)})
    end

    if self.is_cache then
        table.insert(dialog_buttons, {{
            text = "\u{F021}  " .. T("Refresh"), align = "left",
            callback = function()
                UIManager:close(self)
                self.clear_cache_callback()
            end
        }})
    end

    table.insert(dialog_buttons, {{
        text = "\u{21A9}  " .. T("Back"), align = "left",
        callback = function() UIManager:close(self) end
    }})
    
    return dialog_buttons
end

function BookDetailsDialog:switchState(new_state, is_new)
    if is_new then
        UIManager:close(self)
        local new_dialog = BookDetailsDialog:new{
            Ui_module = self.Ui_module,
            parent_zlibrary = self.parent_zlibrary,
            book = self.book,
            clear_cache_callback = self.clear_cache_callback,
            view_state = new_state
        }
        UIManager:show(new_dialog)
        return
    end
    local orig_dimen = self.inner_dialog.dimen and self.inner_dialog.dimen:copy()
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
    -- self.inner_dialog:moveFocusTo(1, 1)
end

function BookDetailsDialog:_generateFavoriteButtonDef(in_favorites)
    return {
        id = "favorite_btn",
        text = in_favorites and ("\u{2665}  " .. T("Remove From Favorites")) or ("\u{2661}  " .. T("Add To Favorites")),
        align = "left",
        callback = function()
            local reload_ui = function()
                local new_in_favorites = not in_favorites
                local updated_config = self:_generateFavoriteButtonDef(new_in_favorites)
                local button = self.inner_dialog:getButtonById("favorite_btn")
                
                if button then
                    if type(button.setText) == "function" then
                        button:setText(updated_config.text)
                    else
                        button.text = updated_config.text
                        if type(button.free) == "function" then button:free() end
                    end
                    button.callback = updated_config.callback
                    UIManager:setDirty(self, "ui")
                end
            end
            
            if in_favorites then
                self.parent_zlibrary:unfavoriteBook(self.book, reload_ui)
            else
                self.parent_zlibrary:favoriteBook(self.book, reload_ui)
            end
        end
    }
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

function BookDetailsDialog:_renderComments(book_comments)
    if not (type(book_comments) == "table" and type(book_comments[1]) == "table") then 
        return T("No Comments"), "@page { margin: 0; }"
    end
    local function generateCommentsHTML(comments)
        local html_parts = {}
        local roots = {}
        local children = {}

        for i = #comments, 1, -1 do
            local comment = comments[i]
            local pid = comment.parent_id
            if pid and pid ~= "" and pid ~= 0 then
                if not children[pid] then children[pid] = {} end
                table.insert(children[pid], comment)
            else
                table.insert(roots, comment)
            end
        end

        -- Flatten if parent_id exists but root node not found
        if #roots == 0 and #comments > 0 then roots = comments end

        local function renderComment(comment, depth)
            local user = comment.user or {}
            local user_name = user.name or "Anonymous"
            local is_premium = user.isPremium and "⭐" or ""
            local date_str = comment.dateRelative or comment.date or ""
            local text = comment.text or ""

            local inline_style = depth > 0 and string.format(' style="margin-left: %sem;"', depth * 1.5) or ""
            local reply_class = depth > 0 and " comment-reply" or ""

            local comment_html = string.format([[
            <div class="comment-node%s"%s>
                <div class="comment-inner">
                    <div class="comment-header">%s <span>%s</span></div>
                    <div class="comment-body">%s</div>
                    <div class="comment-meta">%s</div>
                </div>
            </div>
            ]], reply_class, inline_style, user_name, is_premium, text, date_str)

            table.insert(html_parts, comment_html)

            local child_comments = children[comment.id]
            if child_comments then
                for _, child in ipairs(child_comments) do
                    renderComment(child, depth + 1)
                end
            end
        end

        for _, root_comment in ipairs(roots) do
            renderComment(root_comment, 0)
        end
        return table.concat(html_parts, "\n")
    end

    local rendered_html = generateCommentsHTML(book_comments)
    local COMMENTS_CSS = "@page { margin: 0; };body{padding-top:0;}.comment-node{margin-top:0.8em;margin-bottom:0.8em;}.comment-reply{border-left:2px solid #ccc;padding-left:1em;}.comment-inner{padding-bottom:0.8em;border-bottom:1px solid #e0e0e0;}.comment-header{font-weight:bold;margin-bottom:0.5em;color:#333;}.comment-body{margin-bottom:0.5em;line-height:1.4;word-break:break-word;}.comment-meta{font-size:0.85em;color:#666;font-style:italic;}"
    return rendered_html, COMMENTS_CSS 
end

function BookDetailsDialog:_sanitizeBookData(raw)
    local book = {}
    book.id =raw.id
    book.hash = raw.hash
    book.title = type(raw.title) == "string" and raw.title or ""
    book.author = type(raw.author) == "string" and raw.author or ""
    book.publisher = type(raw.publisher) == "string" and raw.publisher or ""
    book.series = type(raw.series) == "string" and raw.series or ""
    book.description = (type(raw.description) == "string" and raw.description ~= "") and raw.description or T("No Description")
    book.cover = type(raw.cover) == "string" and raw.cover or nil
    book.pages = tonumber(raw.pages) or 0
    book.download = raw.download
    book.year = "N/A"
    if raw.year and tostring(raw.year) ~= "0" and tostring(raw.year) ~= "N/A" then
        book.year = tostring(raw.year)
    end
    book.format = type(raw.format) == "string" and raw.format:upper() or "N/A"
    book.size = type(raw.size) == "string" and raw.size or "N/A"
    book.lang = type(raw.lang) == "string" and raw.lang or "N/A"
    book.rating = type(raw.rating) == "string" and raw.rating or "N/A"
    book.filesize = raw.filesize
    return book
end

function BookDetailsDialog:onCloseWidget()
    self._is_closed = true
    if self.inner_dialog and type(self.inner_dialog.onCloseWidget) == "function" then
        self.inner_dialog:onCloseWidget()
    end
    UIManager:setDirty(self.inner_dialog, function()
        return "flashui", self:getRefreshRegion()
   end)
end

local function showBookDetails(Ui_module, parent_zlibrary, book, clear_cache_callback)
     if not(type(book) == "table" and book.hash and book.title and book.id)then
        logger.warn("BookDetailsDialog: Cannot show details, invalid book data")
        return nil
    end
    local dialog = BookDetailsDialog:new{
        Ui_module = Ui_module,
        parent_zlibrary = parent_zlibrary,
        raw_book = book,
        clear_cache_callback = clear_cache_callback,
        view_state = "menu"
    }
    UIManager:show(dialog, function()  
         return "ui", dialog:getRefreshRegion()  
    end) 
    return dialog
end

return {
    showBookDetails = showBookDetails,
    BookDetailsDialog = BookDetailsDialog 
}