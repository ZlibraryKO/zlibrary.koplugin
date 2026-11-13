-- What the book details dialog puts on screen above its buttons, built by the real
-- bookdetails_content.lua (with the core, book and cover parts) on top of stand-in KOReader widgets.
--
-- The details screen needs an account, so the emulator can't open it, and its layout code is the
-- longest in the plugin. This pins what it builds for each kind of book and screen: the header
-- rows in order (title, author, metadata, ISBN), which of them are tappable and reachable by keys,
-- the close X on touch screens only, and which text section fills the rest -- the description, a
-- "No description available" note, the comments, or on a short landscape screen just padding.
--
-- ZL_DUMP=<file> also writes every case's whole widget tree, with sizes, to that file: build it
-- before and after a change to the layout code, and a diff shows exactly what changed on screen.

local PLUGIN = assert(arg[1], "usage: luajit bookdetails_content_harness.lua <plugin-root> <luasocket-src>")
local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()
support.preload_koreader_stubs()
package.path = PLUGIN .. "/?.lua;" .. package.path

-- ---------------------------------------------------------------- stand-in widgets
-- Sizes are made up but consistent: a character is 10 px wide, a line 20 px high, and
-- scaleBySize returns its argument. Containers size themselves from their children the way
-- KOReader's do, which is all the layout code measures.
local CHAR_W, LINE_H = 10, 20

local Geom = {}
Geom.__index = Geom
function Geom:new(t) return setmetatable(t or {}, Geom) end
function Geom:copy() return Geom:new{ x = self.x, y = self.y, w = self.w, h = self.h } end
function Geom:combine(o) return o end
function Geom:contains() return true end

local function size_of(w) return w and w.getSize and w:getSize() or Geom:new{ w = 0, h = 0 } end

local sizers = {
    TextWidget = function(w)
        local width = #w.text * CHAR_W
        if w.max_width then width = math.min(width, w.max_width) end
        return width, LINE_H
    end,
    TextBoxWidget = function(w)
        local lines = math.max(1, math.ceil(#w.text * CHAR_W / w.width))
        local h = lines * LINE_H
        if w.height then h = math.min(h, w.height) end
        return w.width, h
    end,
    VerticalGroup = function(w)
        local mw, h = 0, 0
        for _, c in ipairs(w) do local s = size_of(c) mw = math.max(mw, s.w) h = h + s.h end
        return mw, h
    end,
    HorizontalGroup = function(w)
        local width, mh = 0, 0
        for _, c in ipairs(w) do local s = size_of(c) width = width + s.w mh = math.max(mh, s.h) end
        return width, mh
    end,
    VerticalSpan = function(w) return 0, w.width end,
    HorizontalSpan = function(w) return w.width, 0 end,
    ImageWidget = function(w) return w.width, w.height end,
    ScrollHtmlWidget = function(w) return w.width, w.height end,
    IconButton = function(w) return w.width + (w.padding_left or 0), w.height + (w.padding_bottom or 0) end,
    FrameContainer = function(w)
        local s = size_of(w[1])
        local extra = 2 * ((w.bordersize or 0) + (w.padding or 0) + (w.margin or 0))
        return w.width or (s.w + extra), w.height or (s.h + extra)
    end,
}

local widget_kinds = {}
local function widget_class(kind)
    local C = { kind = kind }
    C.__index = C
    function C:extend(t)
        t = t or {}
        t.__index = t
        return setmetatable(t, { __index = self })
    end
    function C:new(t)
        t = setmetatable(t or {}, self)
        if rawget(self, "init") and self ~= C then t:init() end
        return t
    end
    function C:getSize()
        if self.dimen and self.dimen.w then return Geom:new{ w = self.dimen.w, h = self.dimen.h } end
        local sizer = sizers[kind]
        if sizer then
            local w, h = sizer(self)
            return Geom:new{ w = w, h = h }
        end
        return size_of(self[1])
    end
    function C:free() end
    widget_kinds[C] = kind
    return C
end

local WIDGETS = {
    ["ui/widget/textwidget"] = "TextWidget", ["ui/widget/textboxwidget"] = "TextBoxWidget",
    ["ui/widget/verticalgroup"] = "VerticalGroup", ["ui/widget/horizontalgroup"] = "HorizontalGroup",
    ["ui/widget/verticalspan"] = "VerticalSpan", ["ui/widget/horizontalspan"] = "HorizontalSpan",
    ["ui/widget/imagewidget"] = "ImageWidget", ["ui/widget/scrollhtmlwidget"] = "ScrollHtmlWidget",
    ["ui/widget/iconbutton"] = "IconButton", ["ui/widget/container/framecontainer"] = "FrameContainer",
    ["ui/widget/container/leftcontainer"] = "LeftContainer",
    ["ui/widget/container/centercontainer"] = "CenterContainer",
    ["ui/widget/container/inputcontainer"] = "InputContainer",
    ["ui/widget/overlapgroup"] = "OverlapGroup", ["ui/widget/linewidget"] = "LineWidget",
    ["ui/widget/infomessage"] = "InfoMessage", ["ui/widget/buttondialog"] = "ButtonDialog",
    ["ui/widget/buttontable"] = "ButtonTable",
}

local shown = {}
local device = {}

local function install_stubs(opts)
    for mod, kind in pairs(WIDGETS) do
        package.loaded[mod] = nil
        package.preload[mod] = function() return widget_class(kind) end
    end
    local Screen = {
        getWidth = function() return opts.screen_w end,
        getHeight = function() return opts.screen_h end,
        scaleBySize = function(_, v) return v end,
    }
    device = {
        screen = Screen,
        hasDPad = function() return opts.keys == true end,
        isTouchDevice = function() return opts.keys ~= true end,
        hasClipboard = function() return opts.clipboard ~= false end,
        input = { setClipboardText = function(text) device.copied = text end },
    }
    local face = { ftsize = { getHeightAndAscender = function() return LINE_H, 15 end } }
    local stubs = {
        ["device"] = device,
        ["ffi/blitbuffer"] = setmetatable({}, { __index = function(_, k) return k end }),
        ["ui/font"] = { getFace = function() return face end },
        ["ui/geometry"] = Geom,
        ["ui/size"] = {
            border = { thin = 1, thick = 3, window = 2 },
            padding = { button = 4, default = 5, large = 10, buttontable = 4 },
            margin = { default = 5, title = 5 },
            line = { medium = 1 },
            radius = { default = 5 },
        },
        ["ui/uimanager"] = {
            show = function(_, w) table.insert(shown, w) end,
            close = function() end, setDirty = function() end, nextTick = function() end,
            broadcastEvent = function() end, isWidgetShown = function() return true end,
        },
        ["ui/event"] = { new = function(_, ...) return { ... } end },
        ["ui/gesturerange"] = { new = function(_, t) return t end },
        ["ui/widget/focusmanager"] = {},
        ["zlibrary.cache"] = { new = function() return { get = function() return nil end } end },
    }
    package.preload["util"] = nil
    package.loaded["util"] = nil
    support.preload_koreader_stubs()
    local util = require("util")
    util.fileExists = function() return false end
    util.htmlEntitiesToUtf8 = function(s) return s end
    for mod, value in pairs(stubs) do
        package.loaded[mod] = nil
        package.preload[mod] = function() return value end
    end
    for _, part in ipairs{ "core", "book", "content", "cover" } do
        package.loaded["zlibrary.bookdetails_" .. part] = nil
    end
    _G.G_defaults = { readSetting = function() return 48 end }
end

-- ---------------------------------------------------------------- building one case
local BOOK = {
    id = 1, hash = "abc", title = "A Short Title", author = "Ann Author",
    publisher = "Pub", year = 2020, series = "Series", lang = "english", size = "1 MB",
    pages = 300, rating = "4.5", format = "epub", identifier = "978-0-306-40615-7",
    description = "<p>Once upon a time.</p>", cover = "",
}

local function copy(t, over)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    for k, v in pairs(over or {}) do out[k] = v end
    return out
end

local function build(opts)
    install_stubs(opts)
    local BookDetailsDialog = require("zlibrary.bookdetails_core")
    require("zlibrary.bookdetails_book")
    require("zlibrary.bookdetails_content")
    require("zlibrary.bookdetails_cover")

    local searched, switched = {}, {}
    local dialog = setmetatable({}, { __index = BookDetailsDialog })
    dialog.book = dialog:_sanitizeBookData(copy(BOOK, opts.book))
    dialog.full_title = dialog.book.title
    dialog.full_author = dialog.book.author
    dialog.view_state = opts.view or "menu"
    dialog.parent_zlibrary = { downloadAndShowCover = function() end }
    dialog.Ui_module = {
        showSearchDialog = function(_, author) table.insert(searched, author) end,
        showInfoMessage = function() end,
    }
    dialog.fonts = { title = { ftsize = { getHeightAndAscender = function() return LINE_H, 15 end } } }
    dialog.fonts.author, dialog.fonts.meta, dialog.fonts.cover = dialog.fonts.title, dialog.fonts.title, dialog.fonts.title
    dialog.switchState = function(_, state) table.insert(switched, state) end
    if opts.comments then
        dialog.book.comments_html = "<div>a comment</div>"
        dialog.book.comments_css = "body{}"
    end
    dialog:_calculateDimensions()
    -- What _buildInnerDialog hands over: the screen less the buttons. Fixed here, since the
    -- buttons are not this harness's business.
    dialog._content_h = opts.content_h or (opts.screen_h - 300)
    local content = dialog:_buildContent()
    return { dialog = dialog, content = content, searched = searched, switched = switched }
end

-- ---------------------------------------------------------------- reading the tree
local function find_all(w, kind, out)
    out = out or {}
    if type(w) ~= "table" then return out end
    local mt = getmetatable(w)
    local k = mt and widget_kinds[mt]
    if k == kind then table.insert(out, w) end
    for _, c in ipairs(w) do find_all(c, kind, out) end
    return out
end

local function kind_of(w)
    local mt = getmetatable(w)
    return mt and widget_kinds[mt] or "?"
end

-- The text a row shows, looking through clickable and focus-frame wrappers.
local function text_of(w)
    while type(w) == "table" and w.text == nil and w[1] ~= nil do w = w[1] end
    if type(w) ~= "table" then return nil end
    if w.text then return w.text end
end

-- The header's text column: the VerticalGroup beside the cover.
local function text_column(case)
    for _, g in ipairs(find_all(case.content, "VerticalGroup")) do
        if g.not_focusable and g.align == "left" then return g end
    end
end

local function rows(case)
    local out = {}
    for _, w in ipairs(text_column(case)) do
        local k = kind_of(w)
        if k ~= "VerticalSpan" then
            table.insert(out, { kind = k, text = text_of(w) or "" })
        end
    end
    return out
end

local function html_section(case)
    local html = find_all(case.content, "ScrollHtmlWidget")
    return html[1]
end

local dump_lines = {}
local function dump(name, w)
    local function walk(node, depth)
        local s = size_of(node)
        local props = {}
        for _, key in ipairs{ "text", "width", "height", "align", "bordersize", "focusable",
                              "not_focusable", "overlap_align", "icon", "html_body", "css", "max_width" } do
            if rawget(node, key) ~= nil then table.insert(props, key .. "=" .. tostring(node[key])) end
        end
        if rawget(node, "ges_events") then table.insert(props, "tappable") end
        table.insert(dump_lines, string.rep("  ", depth) .. kind_of(node)
            .. string.format(" [%dx%d] ", s.w, s.h) .. table.concat(props, " "))
        for _, c in ipairs(node) do if type(c) == "table" then walk(c, depth + 1) end end
    end
    table.insert(dump_lines, "== " .. name)
    walk(w, 0)
end

-- ---------------------------------------------------------------- the cases
local PORTRAIT = { screen_w = 600, screen_h = 800 }
local function case(name, opts)
    local o = copy(PORTRAIT, opts)
    local c = build(o)
    dump(name, c.content)
    return c
end

-- An ordinary book on a touch screen, in the button list.
do
    local c = case("touch, menu, full record", {})
    local rs = rows(c)
    r.check("the header lists title, author, three metadata lines and the ISBN, in that order",
        #rs == 6 and rs[1].text == BOOK.title and rs[2].kind == "InputContainer"
        and rs[3].kind == "TextWidget" and rs[4].kind == "TextWidget" and rs[5].kind == "TextWidget"
        and rs[6].text:find("^ISBN 9780306406157") ~= nil,
        #rs .. " rows")
    r.check("a short title is plain text", rs[1].kind == "TextBoxWidget")
    r.check("the author line shows the author with the search mark",
        find_all(c.content, "TextWidget")[1] ~= nil
        and text_of(text_column(c)[3]) == "\u{F002} " .. BOOK.author)
    r.check("only the author and ISBN lines take key focus",
        #c.dialog._key_focus_rows == 2
        and text_of(c.dialog._key_focus_rows[2]):find("^ISBN") ~= nil)
    r.check("the metadata lines read publisher · year, series, and the technical line",
        rs[3].text == "Pub · 2020" and rs[4].text == "Series"
        and rs[5].text == "english · 1 MB · 300 pages · \u{2605}\u{00A0}4.5 · EPUB",
        rs[3].text .. " / " .. rs[4].text .. " / " .. rs[5].text)
    local overlaps = find_all(c.content, "OverlapGroup")
    r.check("a touch screen gets the close X over the header",
        #overlaps == 1 and #find_all(c.content, "IconButton") == 1)
    r.check("the cover's top margin comes first", kind_of(c.content[1]) == "VerticalSpan"
        and c.content[1].width == c.dialog.cover_top_margin)
    local html = html_section(c)
    r.check("the menu view shows the description", html and html.html_body == BOOK.description)
    r.check("tapping the description opens the Description view",
        html and html.onTapScrollText and html:onTapScrollText() == true
        and c.switched[1] == "description")
    -- The cover's top margin comes on top: _contentBudget takes it out of the budget beforehand.
    local s = size_of(c.content)
    r.check("the content fills its budget plus the cover's top margin",
        s.h == c.dialog._content_h + c.dialog.cover_top_margin, s.h .. " vs " .. c.dialog._content_h)
end

-- A title too long for three lines becomes tappable, and the first focus row.
do
    local c = case("touch, long title", { book = { title = string.rep("Very long title ", 30) } })
    local rs = rows(c)
    r.check("a long title is tappable", rs[1].kind == "InputContainer")
    r.check("and is the first key focus row", #c.dialog._key_focus_rows == 3
        and text_of(c.dialog._key_focus_rows[1]) == c.dialog.full_title)
    local box = find_all(c.content, "TextBoxWidget")[1]
    r.check("and is cut to three lines with an ellipsis", box.height_overflow_show_ellipsis == true
        and box.height == math.floor(LINE_H * 3.2))
end

-- No author: no author line, and nothing to focus but the ISBN.
do
    local c = case("touch, no author", { book = { author = "" } })
    local rs = rows(c)
    r.check("without an author there is no author line", #rs == 5 and rs[2].kind == "TextWidget")
    r.check("and only the ISBN takes key focus", #c.dialog._key_focus_rows == 1)
end

-- No clipboard: the ISBN is plain text, without the tap mark.
do
    local c = case("touch, no clipboard", { clipboard = false })
    local rs = rows(c)
    r.check("without a clipboard the ISBN line is plain, with no tap mark",
        rs[6].kind == "TextWidget" and rs[6].text == "ISBN 9780306406157")
end

-- No ISBN and no metadata.
do
    local c = case("touch, bare record", { book = { identifier = "", publisher = "", year = 0, series = "",
        lang = "N/A", size = "N/A", pages = 0, rating = "N/A", format = "N/A" } })
    local rs = rows(c)
    r.check("a bare record shows only title and author", #rs == 2, #rs .. " rows")
end

-- No description: say so rather than leave a gap.
do
    local c = case("touch, no description", { book = { description = "" } })
    local html = html_section(c)
    r.check("a book without a description says so",
        html and html.html_body == "<div>No description available</div>")
end

-- The Description view.
do
    local c = case("touch, description view", { view = "description" })
    local html = html_section(c)
    r.check("the Description view shows the description", html and html.html_body == BOOK.description)
    r.check("and its taps scroll rather than switch views", rawget(html, "onTapScrollText") == nil)
end

-- The Comments view, with the comments' own CSS.
do
    local c = case("touch, comments view", { view = "comments", comments = true })
    local html = html_section(c)
    r.check("the Comments view shows the comments with their CSS",
        html and html.html_body == "<div>a comment</div>" and html.css == "body{}")
end

-- A short landscape screen: no room for text in the button list, so it pads instead.
do
    local c = case("touch, short screen, menu", { screen_w = 800, screen_h = 600, content_h = 300 })
    r.check("a short screen's button list has no text section", html_section(c) == nil)
    local last = c.content[#c.content]
    r.check("and pads to the budget instead", kind_of(last) == "VerticalSpan"
        and size_of(c.content).h == 300 + c.dialog.cover_top_margin, size_of(c.content).h)
    local d = case("touch, short screen, description", { screen_w = 800, screen_h = 600, content_h = 300,
        view = "description" })
    r.check("but its Description view still shows the description", html_section(d) ~= nil)
end

-- A reader without a touchscreen: no X, and focus frames around the tappable lines.
do
    local c = case("keys, menu, long title", { keys = true, book = { title = string.rep("Very long title ", 30) } })
    r.check("a keys-only reader gets no close X", #find_all(c.content, "IconButton") == 0
        and #find_all(c.content, "OverlapGroup") == 0)
    local framed = 0
    for _, w in ipairs(c.dialog._key_focus_rows) do
        if kind_of(w[1]) == "FrameContainer" and w[1].focusable then framed = framed + 1 end
    end
    r.check("and every focus row has a focus frame", framed == 3, framed .. " of 3")
end

local dump_path = os.getenv("ZL_DUMP")
if dump_path then
    local fh = assert(io.open(dump_path, "w"))
    fh:write(table.concat(dump_lines, "\n"), "\n")
    fh:close()
end

r.finish()
