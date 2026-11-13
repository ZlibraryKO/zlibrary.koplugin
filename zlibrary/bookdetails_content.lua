-- The dialog's content: the header (title, author, metadata, ISBN line, beside the cover) and the
-- text section under it (description or comments), sized to the room the buttons leave. Part of
-- the details dialog; see bookdetails_dialog.lua.

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Screen = Device.screen
local Geom = require("ui/geometry")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local InputContainer = require("ui/widget/container/inputcontainer")
local InfoMessage = require("ui/widget/infomessage")
local IconButton = require("ui/widget/iconbutton")
local OverlapGroup = require("ui/widget/overlapgroup")
local FrameContainer = require("ui/widget/container/framecontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local LineWidget = require("ui/widget/linewidget")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local GestureRange = require("ui/gesturerange")
local T = require("zlibrary.gettext")

local BookDetailsDialog = require("zlibrary.bookdetails_core")

-- Without a touchscreen these lines are reached by moving focus onto them (_addKeyFocusRows), so
-- they need a focus mark. The border is there all along, white until focused, so taking focus
-- never shifts the text.
local KEY_FOCUS_BORDER = Device:hasDPad() and Size.border.thick or 0

local function makeClickable(content_widget, callback)
    if KEY_FOCUS_BORDER > 0 then
        content_widget = FrameContainer:new{
            focusable = true,
            padding = 0, margin = 0,
            bordersize = KEY_FOCUS_BORDER, focus_border_size = KEY_FOCUS_BORDER,
            color = Blitbuffer.COLOR_WHITE, focus_border_color = Blitbuffer.COLOR_BLACK,
            content_widget,
        }
    end
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

-- Everything above the buttons: the header (the cover beside the title, author, metadata and ISBN),
-- then the text section that fills what the buttons leave. Each piece below builds one part; the
-- rows that act on a tap register themselves in _key_focus_rows, in screen order, so a reader
-- without a touchscreen can reach them (_addKeyFocusRows).
function BookDetailsDialog:_buildContent()
    self._key_focus_rows = {}
    -- Key-only readers have Back and nothing to tap an X with.
    self.close_icon_size = Device:isTouchDevice()
        and Screen:scaleBySize(G_defaults:readSetting("DGENERIC_ICON_SIZE") * 0.6) or nil

    local header_widget = self:_buildHeader(self:_buildTextColumn())

    local content_group = VerticalGroup:new{ not_focusable = true }
    if self.cover_top_margin and self.cover_top_margin > 0 then
        table.insert(content_group, VerticalSpan:new{ width = self.cover_top_margin })
    end
    table.insert(content_group, self:_withCloseButton(header_widget))
    local text_section = self:_buildTextSection()
    if text_section then
        table.insert(content_group, text_section)
    end
    return content_group
end

-- The column beside the cover: title, author, metadata lines, ISBN.
function BookDetailsDialog:_buildTextColumn()
    local vstack = VerticalGroup:new{ align = "left", not_focusable = true}
    table.insert(vstack, self:_buildTitle())

    local author_line = self:_buildAuthorLine()
    if author_line then
        table.insert(vstack, VerticalSpan:new{ width = math.floor(Screen:scaleBySize(8)) })
        table.insert(vstack, author_line)
    end

    local meta_lines = self:_generateMetaLines()
    if #meta_lines > 0 then
        table.insert(vstack, VerticalSpan:new{ width = math.floor(Screen:scaleBySize(10)) })
        for i, line_text in ipairs(meta_lines) do
            table.insert(vstack, TextWidget:new{ text = line_text, face = self.fonts.meta, fgcolor = Blitbuffer.COLOR_GRAY_3, max_width = self.text_col_w })
            if i < #meta_lines then table.insert(vstack, VerticalSpan:new{ width = math.floor(Screen:scaleBySize(4)) }) end
        end
    end

    -- The ISBN sits apart from the other metadata lines because it is the only one here nobody
    -- reads on the device: it exists to be carried to a desktop, where it identifies an edition
    -- exactly and a title does not. Its own line, and tappable, so it can be copied without
    -- transcribing thirteen digits by eye.
    local isbn_line = self:_buildIsbnLine()
    if isbn_line then
        table.insert(vstack, VerticalSpan:new{ width = math.floor(Screen:scaleBySize(#meta_lines > 0 and 4 or 10)) })
        table.insert(vstack, isbn_line)
    end
    return vstack
end

-- Up to three lines of title, beside the close X when there is one.
function BookDetailsDialog:_buildTitle()
    local title_face = self.fonts.title
    local face_height = title_face.ftsize:getHeightAndAscender()
    local title_max_h = math.floor(face_height * 3.2)
    local title_w = self.text_col_w - (self.close_icon_size or 0)

    local title_widget = TextBoxWidget:new{
        text = self.full_title,
        face = title_face,
        bold = true,
        alignment = "left",
        width = title_w,
    }
    if title_widget:getSize().h <= title_max_h then
        return title_widget
    end
    -- Lists shorten titles and this header can only hold so many lines, so a title this long
    -- would otherwise never be readable in full anywhere on the device.
    title_widget:free()
    local clickable_title = makeClickable(TextBoxWidget:new{
        text = self.full_title,
        face = title_face,
        bold = true,
        alignment = "left",
        width = title_w,
        height = title_max_h,
        height_adjust = true,
        height_overflow_show_ellipsis = true,
    }, function()
        UIManager:show(InfoMessage:new{ text = self.full_title })
        return true
    end)
    table.insert(self._key_focus_rows, clickable_title)
    return clickable_title
end

-- The author, tappable to search for them. nil when the record has no author.
function BookDetailsDialog:_buildAuthorLine()
    if self.full_author == "" then return nil end
    -- Search glyph: tapping the author searches for them. U+F0013 was here, a
    -- Nerd Fonts Material-Design codepoint that the bundled symbols.ttf does not
    -- carry -- it has nothing at all in U+F0000-F1FFF -- so it drew as a box.
    local author_text = "\u{F002} " .. self.full_author
    local author_max_w = math.floor(self.text_col_w - Screen:scaleBySize(25)) - 2 * KEY_FOCUS_BORDER
    local author_widget = TextWidget:new{ text = author_text, face = self.fonts.author }
    if author_widget:getSize().w > author_max_w then
        author_widget:free()
        author_widget = TextBoxWidget:new{
            text = author_text,
            face = self.fonts.author,
            alignment = "left",
            width = author_max_w,
            height = math.floor(self.fonts.author.ftsize:getHeightAndAscender() * 3.2),
            height_adjust = true,
            height_overflow_show_ellipsis = true,
        }
    end
    local author_group = HorizontalGroup:new{
        author_widget,
        TextWidget:new{ text = " \u{25B8}", face = self.fonts.author }
    }
    local clickable_author = makeClickable(author_group, function()
        UIManager:close(self)
        self.Ui_module.showSearchDialog(self.parent_zlibrary, self.full_author)
        return true
    end)
    table.insert(self._key_focus_rows, clickable_author)
    return clickable_author
end

-- The cover (tap to open it large) beside the text column. Sets self._header_h, which the text
-- section below is sized from.
function BookDetailsDialog:_buildHeader(text_column)
    self.cover_frame = self:_buildCoverComponent()
    self:_applyCoverPaintShadow(self.cover_frame)
    local clickable_cover = makeClickable(self.cover_frame, function()
        self.parent_zlibrary:downloadAndShowCover(self.book)
        return true
    end)
    -- The row must be tall enough for whichever column is taller. The cover used to decide this on
    -- its own, which held while it was always the tallest thing here -- but now that it is capped
    -- against a short landscape screen, the metadata column can outgrow it, and a row sized to the
    -- cover alone lets whatever follows be drawn straight through the text.
    local text_col_h = text_column:getSize().h
    local header_box_h = math.max(self.framed_h, text_col_h)
    local header_widget = LeftContainer:new{
        dimen = Geom:new{ w = self.avail_w, h = header_box_h },
        HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = self.left_padding },
            clickable_cover,
            HorizontalSpan:new{ width = self.gap },
            text_column
        }
    }

    local orig_header_getSize = header_widget.getSize
    local offset = self.pop_out_offset
    header_widget.getSize = function(widget)
        local size = orig_header_getSize(widget)
        -- The cover is painted `offset` above its slot, so the slot may end that much sooner. The
        -- text column is not popped out, though, so never report less than it actually occupies --
        -- otherwise the divider and text below are laid out over the metadata line.
        local popped_h = math.floor(size.h - offset + Screen:scaleBySize(5))
        return Geom:new{ w = size.w, h = math.max(popped_h, text_col_h) }
    end

    -- Remember what the header actually costs (the override above already discounts the cover's
    -- pop-out shadow) so _buildHtmlSection can give the rest of the screen to the text.
    self._header_h = header_widget:getSize().h
    return header_widget
end

-- The header with the close X over its top right corner, on a touch screen; the header alone
-- otherwise.
function BookDetailsDialog:_withCloseButton(header_widget)
    if not self.close_icon_size then
        return header_widget
    end
    -- Same corner and size as the X on the list screens. The extra padding widens the tap zone
    -- towards the screen, the same way TitleBar does.
    local close_button = IconButton:new{
        icon = "close",
        width = self.close_icon_size,
        height = self.close_icon_size,
        padding_left = self.close_icon_size,
        padding_bottom = self.close_icon_size,
        show_parent = self,
        callback = function() UIManager:close(self) end,
    }
    close_button.overlap_align = "right"
    return OverlapGroup:new{
        dimen = Geom:new{ w = self.avail_w, h = self._header_h },
        header_widget,
        close_button,
    }
end

-- What fills the rest of the budget under the header: the comments, the description, a note that
-- there is none, or -- with no room for text -- padding. nil when there is nothing to pad.
function BookDetailsDialog:_buildTextSection()
    -- Is there room for a text section at all? On a short landscape screen the cover and the full
    -- button stack nearly fill the height on their own, and forcing a section in anyway pushes the
    -- dialog past the screen -- at which point ButtonDialog wraps the buttons in a scroll container
    -- and the reader is left fighting two nested scrolling areas. In that case the menu view pads
    -- instead and the Description button remains the way in. The other views only ever carry one button,
    -- so they always have room.
    local header_h = self._header_h or self.framed_h
    local text_room = (self._content_h or 0) - header_h - Screen:scaleBySize(45)
    local has_room = self.view_state ~= "menu" or text_room >= Screen:scaleBySize(80)
    local has_description = self.book.description and self.book.description ~= ""

    if self.view_state == "comments" and self.book.comments_html then
        return self:_buildHtmlSection(string.format("  %s  ", T("Comments")), self.book.comments_html, self.book.comments_css)
    elseif has_description and has_room then
        -- The menu view shows the description as well, not just the "description" view. That is what
        -- keeps the dialog one size: every view fills the same content budget, and pressing Description
        -- only trades the button stack for more reading room rather than resizing the dialog.
        local section = self:_buildHtmlSection(string.format("  %s  ", T("Description")), self.book.description)

        -- In the menu view the description is only a preview, so tapping it opens the full view --
        -- the same thing the Description button does. ScrollHtmlWidget claims taps for scrolling
        -- (onTapScrollText pages up or down by tap position) and only reports the event handled when
        -- it actually scrolled, so wrapping this in a tap container would expand only once the
        -- preview hit its end. Repurpose the widget's own tap handler instead, which leaves swipe
        -- and the page keys scrolling the preview as before.
        if self.view_state == "menu" and self.scrollable_html then
            self.scrollable_html.onTapScrollText = function()
                self:switchState("description")
                return true
            end
        end
        return section
    elseif not has_description and has_room then
        -- No description at all. Say so rather than leaving a blank region, which reads like
        -- something failed to load, and still fill the budget so a book without a description does
        -- not open a shorter dialog than one with it.
        return self:_buildHtmlSection(
            string.format("  %s  ", T("Description")),
            string.format("<div>%s</div>", T("No description available")))
    end
    -- No room for any text section (a short landscape screen). Pad to the budget so the dialog
    -- keeps one size across views, and leave the height to the buttons rather than overflowing.
    local pad_h = (self._content_h or 0) - header_h
    if pad_h > 0 then
        return VerticalSpan:new{ width = math.floor(pad_h) }
    end
    return nil
end

function BookDetailsDialog:_buildHtmlSection(divider_text, raw_html, css)
    local section_group = VerticalGroup:new{ align = "left" }
    local clean_html = raw_html
    local engine_css = [[
        @page { margin: 0; }
        body { margin: 0; padding: 0 12px 0 0; font-family: sans-serif; text-align: left; line-height: 1.4; }
        p, div { margin: 0; margin-bottom: 0.5em; }
        b, strong, h1, h2, h3, h4, h5, h6 { font-weight: normal; }
        a { text-decoration: none; }
        img, iframe { display: none !important; }
    ]]
    if self.view_state == "comments" and type(css) == "string" and css ~= "" then
        engine_css = css
    end
    -- Build the divider first so its real height can be measured before sizing the text area.
    local top_span_h = math.floor(Screen:scaleBySize(15))
    local bottom_span_h = math.floor(Screen:scaleBySize(10))
    local desc_text_widget = TextWidget:new{ text = divider_text, face = self.fonts.meta, fgcolor = Blitbuffer.COLOR_GRAY_3 }
    local text_size = desc_text_widget:getSize()
    local line_h = math.max(1, math.floor(Screen:scaleBySize(1)))
    local left_line_w = math.max(0, math.floor((self.avail_w - text_size.w) / 2))
    local right_line_w = math.max(0, self.avail_w - left_line_w - text_size.w)
    local divider_block_h = top_span_h + math.max(text_size.h, line_h) + bottom_span_h

    -- Fill the content budget _contentBudget() worked out for this view: whatever is left after the
    -- measured header and this divider. The budget already accounts for the button rows actually on
    -- screen, so every view ends up the same overall height. The old code instead subtracted a
    -- hardcoded scaleBySize(520) -- a reservation for the full menu button stack, which is never
    -- shown alongside this section. On a 1264x1680 screen that withheld ~1096px, produced ~74px and
    -- collapsed onto its own floor: a small band of text in a mostly empty dialog.
    local header_h = self._header_h or self.framed_h
    local available_h = (self._content_h or Screen:getHeight()) - header_h - divider_block_h
    -- Guard degenerate geometry only. Do not clamp up to a large scaled floor: scaleBySize keys off
    -- the SHORTER screen edge, so in landscape such a floor can exceed the height actually left and
    -- push the dialog off-screen.
    local safe_h = math.floor(math.max(available_h, Screen:scaleBySize(120)))

    self.scrollable_html = ScrollHtmlWidget:new{
        html_body = clean_html,
        width = self.avail_w,
        scroll_bar_width = Screen:scaleBySize(2),
        text_scroll_span = Screen:scaleBySize(3),
        css = engine_css,
        height = safe_h
    }

    table.insert(section_group, VerticalSpan:new{ width = top_span_h })

    table.insert(section_group, HorizontalGroup:new{
        align = "center",
        LineWidget:new{ dimen = Geom:new{ w = left_line_w, h = line_h }, background = Blitbuffer.COLOR_GRAY_3, style = "solid" },
        desc_text_widget,
        LineWidget:new{ dimen = Geom:new{ w = right_line_w, h = line_h }, background = Blitbuffer.COLOR_GRAY_3, style = "solid" }
    })

    table.insert(section_group, VerticalSpan:new{ width = bottom_span_h })
    table.insert(section_group, FrameContainer:new{ padding = 0, bordersize = 0, self.scrollable_html })

    return section_group
end

-- nil when the record carried no usable ISBN, which is common enough that an "ISBN: N/A" row
-- would be noise on a screen this crowded.
function BookDetailsDialog:_buildIsbnLine()
    if not self.book.isbn then return nil end
    local self_ref = self
    local can_copy = Device:hasClipboard()
    -- U+25B8 is this dialog's own mark for "tapping this does something"; the author line uses it
    -- too. Omitted without a clipboard, where the tap would do nothing and the mark would lie.
    local widget = TextWidget:new{
        text = can_copy and ("ISBN " .. self.book.isbn .. " \u{25B8}") or ("ISBN " .. self.book.isbn),
        face = self.fonts.meta,
        fgcolor = Blitbuffer.COLOR_GRAY_3,
        max_width = can_copy and (self.text_col_w - 2 * KEY_FOCUS_BORDER) or self.text_col_w,
    }
    if not can_copy then return widget end
    local clickable = makeClickable(widget, function()
        -- The bare number, not the displayed line: it is going into a Calibre search box.
        Device.input.setClipboardText(self_ref.book.isbn)
        self_ref.Ui_module.showInfoMessage(T("Selection copied to clipboard."))
        return true
    end)
    table.insert(self._key_focus_rows, clickable)
    return clickable
end

return BookDetailsDialog
