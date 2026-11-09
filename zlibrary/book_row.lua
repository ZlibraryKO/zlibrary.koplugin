-- What a book's row in a list says: the title on top, then the author and a short line of details.
-- Kept free of KOReader widgets; zlibrary/menu.lua fits these parts to the space a row really has.

local BookRow = {}

BookRow.SEPARATOR = " · "

local BOLD_HEADER = "\u{FFF1}\u{FFF2}"
local BOLD_END = "\u{FFF3}"

local function _usable(value)
    if value == nil or value == "N/A" then return nil end
    local text = tostring(value)
    if text == "" or text == "0" then return nil end
    return text
end

-- The API sends a score of 0 for a book nobody has rated. Shown as a number, that reads as a very
-- bad book, so a rating only appears when there is one.
local function _rating(value)
    local score = tonumber(value)
    if not score or score <= 0 then return nil end
    return string.format("\u{2605}\u{00A0}%.1f", score)
end

-- Some lists send a size in bytes as a bare number, which means nothing to a reader.
local function _size(value)
    local text = _usable(value)
    if text and text:match("%a") then return text end
    return nil
end

function BookRow.details(book, hide_format)
    local parts = {}
    local function add(part)
        if part then parts[#parts + 1] = part end
    end
    add(_usable(book.year))
    if not hide_format then add(_usable(book.format)) end
    add(_size(book.size))
    add(_rating(book.rating))
    return table.concat(parts, BookRow.SEPARATOR)
end

function BookRow.new(title, author, book, hide_format)
    return { title = title, author = author, details = BookRow.details(book, hide_format) }
end

function BookRow.format(title, second_line)
    if not second_line or second_line == "" then
        return BOLD_HEADER .. title .. BOLD_END
    end
    return BOLD_HEADER .. title .. BOLD_END .. "\n" .. second_line
end

function BookRow.secondLine(author, details)
    if not details or details == "" then return author end
    if not author or author == "" then return details end
    return author .. BookRow.SEPARATOR .. details
end

function BookRow.text(row)
    return BookRow.format(row.title, BookRow.secondLine(row.author, row.details))
end

return BookRow
