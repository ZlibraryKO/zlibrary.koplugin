-- Fitting a book to its list row. MenuItem wraps a row at one font size and cuts off whatever does
-- not fit at the bottom, so a long title would hide the author and details. The title is shortened
-- first, and the author gives way before the details do.
--
-- Compiles the real functions from zlibrary/menu.lua against a text measurer where every character
-- is 10 wide, so each expected length below can be worked out by hand.

local PLUGIN = assert(arg[1], "usage: luajit book_row_fit_harness.lua <plugin-root>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()
local BookRow = dofile(PLUGIN .. "/zlibrary/book_row.lua")

local function chars(text)
    local list = {}
    for c in tostring(text):gmatch("[%z\1-\127\194-\244][\128-\191]*") do list[#list + 1] = c end
    return list
end

local function prefix(text, count)
    local list = chars(text)
    return table.concat(list, "", 1, math.max(0, math.min(count, #list)))
end

local RenderText = {
    getSubTextByWidth = function(_, text, _, width) return prefix(text, math.floor(width / 10)) end,
    truncateTextByWidth = function(_, text, _, width) return prefix(text, math.floor(width / 10) - 1) .. "…" end,
    sizeUtf8Text = function(_, _, _, _, text) return { x = #chars(text) * 10 } end,
}

local env = {
    M = {},
    BookRow = BookRow,
    RenderText = RenderText,
    Font = { getFace = function(_, _, size) return { size = size } end },
    Size = { padding = { fullscreen = 0 }, span = { horizontal_default = 5 } },
    TextBoxWidget = {
        line_height = 0.3,
        getFontSizeToFitHeight = function(_, height, lines) return math.floor(height / lines / 1.3) end,
    },
    TextWidget = {
        new = function(_, spec)
            return { getSize = function() return { w = #chars(spec.text) * 8 } end, free = function() end }
        end,
    },
    util = { splitToChars = chars },
    math = math, string = string, table = table, ipairs = ipairs, tostring = tostring, type = type,
}

local source = PLUGIN .. "/zlibrary/menu.lua"
local code = table.concat({
    support.extract_block(source, "(local LEADING_PUNCTUATION = {.-\nlocal function _coverLetter.-\nend\n)"),
    support.extract_block(source, "(local function _fitToWidth.-\nend\n)"),
    support.extract_block(source, "(function M:_fitFontToBookRows.-\nend\n)"),
    support.extract_block(source, "(function M:_fitBookRows.-\nend\n)"),
    "M._coverLetter = _coverLetter\n",
}, "\n")
local chunk = assert(loadstring(code, "=book_row_fit"))
setfenv(chunk, env)
chunk()
local M = env.M

local BOLD, END = "\u{FFF1}\u{FFF2}", "\u{FFF3}"
local function row(title, author, details)
    return { book_row = { title = title, author = author, details = details } }
end
-- Rows are 400 wide at font size 20, so a line is 26 high and holds 40 characters.
local function menu(height, items, extra)
    local m = setmetatable({
        item_table = items, item_dimen = { w = 400, h = height }, perpage = #items, font_size = 20,
        linesize = 0, page = 1, show_cover = false,
    }, { __index = M })
    for k, v in pairs(extra or {}) do m[k] = v end
    return m
end
local function fit(height, item, extra)
    menu(height, { item }, extra):_fitBookRows()
    return item.text
end
local function parts(text)
    return text:match("^" .. BOLD .. "(.-)" .. END .. "\n?(.*)$")
end
local LONG = string.rep("t", 100)
local LONG_AUTHOR = string.rep("a", 60)

-- ---------------------------------------------------------------- what fits stays whole
local text = fit(80, row("Dune", "Frank Herbert", "1965 · 1 MB"))
r.check("a short row is left whole", text == BOLD .. "Dune" .. END .. "\nFrank Herbert · 1965 · 1 MB", text)

-- ---------------------------------------------------------------- long titles
local title, second = parts(fit(52, row(LONG, "Frank Herbert", "1965")))
r.check("with two lines, a long title is cut to one line", #chars(title) == 36 and title:sub(-3) == "…", title)
r.check("and the author and details stay", second == "Frank Herbert · 1965", second)

title = parts(fit(80, row(LONG, "Frank Herbert", "1965")))
r.check("with three lines, a long title gets two", #chars(title) == 72, tostring(#chars(title)))

-- ---------------------------------------------------------------- long authors
title, second = parts(fit(52, row("Dune", LONG_AUTHOR, "2000 · 1 MB")))
local whole_details = " · 2000 · 1 MB"
r.check("a long author gives way, the details stay whole", second:sub(-#whole_details) == whole_details, second)
r.check("and the author is shortened to the room left", second:find("…", 1, true) ~= nil and #chars(second) <= 40,
        tostring(#chars(second)))

title, second = parts(fit(80, row("Dune", LONG_AUTHOR, "2000")))
r.check("a short title leaves its spare line to the author", second == LONG_AUTHOR .. " · 2000", second)

title, second = parts(fit(52, row("Dune", LONG_AUTHOR, "")))
r.check("with no details the author has the whole line", #chars(second) == 40 and second:sub(-3) == "…",
        tostring(#chars(second)))

title, second = parts(fit(52, row("Dune", "Frank Herbert", string.rep("d", 45))))
r.check("details that fill the line leave no half-shown author", second:find("Frank", 1, true) == nil, second)

-- ---------------------------------------------------------------- tight rows and a date column
text = fit(30, row(LONG, "Frank Herbert", "1965"))
r.check("a one-line row shows only the title", text:find("\n", 1, true) == nil and #chars((parts(text))) == 40, text)

local dated = row(LONG, "Frank Herbert", "1965")
dated.mandatory = "2026-08-09"
title = parts(fit(52, dated))
r.check("a date on the right takes its width from the title", #chars(title) == 28, tostring(#chars(title)))

-- ---------------------------------------------------------------- the row keeps its line break
local hooked = row("Dune", "Frank Herbert", "1965")
fit(80, hooked)
r.check("the hook returns the text with its line break", hooked.bidi_wrap_func("flattened") == hooked.text,
        tostring(hooked.bidi_wrap_func("flattened")))

-- ---------------------------------------------------------------- only what is needed
local first, other = row("One", "A", ""), row("Two", "B", "")
first.text, other.text = "untouched", "untouched"
local paged = menu(80, { first, other }, { perpage = 1, page = 2 })
paged:_fitBookRows()
r.check("only the current page is fitted", first.text == "untouched" and other.text ~= "untouched", first.text)

local again = row("Dune", "Frank Herbert", "1965")
local twice = menu(80, { again })
twice:_fitBookRows()
again.text = "marker"
twice:_fitBookRows()
r.check("an unchanged row is not fitted twice", again.text == "marker", again.text)
twice.font_size = 18
twice:_fitBookRows()
r.check("a new font size fits it again", again.text ~= "marker", again.text)

local plain = { text = "Not a book" }
menu(80, { plain }):_fitBookRows()
r.check("rows that are not books are left alone", plain.text == "Not a book", plain.text)

-- ---------------------------------------------------------------- the list's font size
local function font_for(height, size, items)
    local m = menu(height, items or { row("Dune", "A", "") }, { font_size = size })
    m:_fitFontToBookRows()
    return m.font_size
end
r.check("a row with room for three lines keeps its font", font_for(80, 20) == 20, tostring(font_for(80, 20)))
r.check("a shorter row shrinks the font to fit three lines", font_for(52, 20) == 13, tostring(font_for(52, 20)))
r.check("never more than 8 points smaller", font_for(60, 30) == 22, tostring(font_for(60, 30)))
r.check("never below 12", font_for(39, 20) == 12, tostring(font_for(39, 20)))
r.check("lists that are not books keep their font", font_for(52, 20, { plain }) == 20,
        tostring(font_for(52, 20, { plain })))

-- ---------------------------------------------------------------- the cover placeholder
local function letter(title_text) return M._coverLetter({ book_row = { title = title_text } }) end
r.check("a cover letter is upper case", letter("dune") == "D", tostring(letter("dune")))
r.check("Chinese titles use their first character", letter("西游记") == "西", tostring(letter("西游记")))
r.check("opening punctuation is skipped", letter("《西游记》") == "西" and letter("\"Emma\"") == "E",
        tostring(letter("《西游记》")))
r.check("nothing to show means no letter", letter("") == nil and M._coverLetter({}) == nil, tostring(letter("")))

r.finish()
