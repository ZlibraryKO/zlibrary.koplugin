-- The book record behind the details dialog: cleaning up the server's fields, picking the ISBN,
-- and the metadata lines under the author. Part of the details dialog; see bookdetails_dialog.lua.

local util = require("util")
local T = require("zlibrary.gettext")

local BookDetailsDialog = require("zlibrary.bookdetails_core")

-- The one ISBN out of a record's `identifier` field that is worth handing to the user.
--
-- Z-Library sends that field loosely: one ISBN, or several separated by commas or semicolons,
-- hyphenated or not, occasionally with something in the list that is not an ISBN at all. What it
-- is for is the desktop -- Calibre matches an edition on an ISBN instantly and on a title badly --
-- so it is worth picking the best candidate rather than showing the raw field. ISBN-13 wins when
-- there is one, because that is what metadata sources key on.
--
-- Deliberately no check-digit validation. A wrong ISBN fails visibly in Calibre a second later,
-- whereas silently rejecting a valid one -- or one whose check digit the server got wrong --
-- hides the only field this whole feature exists to surface, and hides it invisibly.
local function normalizeIsbn(raw)
    if type(raw) ~= "string" then return nil end
    local best_10
    -- The trailing separator makes the last (or only) entry match the same pattern as the rest,
    -- so a field holding a bare ISBN with no separator in it is not skipped.
    for candidate in (raw .. ";"):gmatch("([^,;]*)[,;]") do
        -- Strip only what an ISBN is legitimately printed with. Stripping every non-digit instead
        -- would reduce "ASIN B00X57B4KE" to digits that were never an ISBN and accept it.
        local compact = candidate:gsub("[%s%-]", ""):upper()
        if #compact == 13 and compact:match("^97[89]%d+$") then
            return compact
        elseif not best_10 and #compact == 10 and compact:match("^%d%d%d%d%d%d%d%d%d[%dX]$") then
            best_10 = compact
        end
    end
    return best_10
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
        -- 0 means nobody has rated the book, the same as in the lists.
        if rating_num and rating_num > 0 then
            self.book.rating = string.format("%.1f", rating_num)
            table.insert(tech_parts, "\u{2605}\u{00A0}" .. self.book.rating)
        end
    end
    if self.book.format and self.book.format ~= "N/A" then 
        table.insert(tech_parts, self.book.format:upper()) 
    end
    if #tech_parts > 0 then table.insert(meta_lines, table.concat(tech_parts, " · ")) end

    return meta_lines
end

function BookDetailsDialog:_sanitizeBookData(raw)
    local book = {}
    book.id =raw.id
    book.hash = raw.hash
    book.title = type(raw.title) == "string" and raw.title or ""
    book.author = type(raw.author) == "string" and raw.author or ""
    book.publisher = type(raw.publisher) == "string" and raw.publisher or ""
    book.series = type(raw.series) == "string" and raw.series or ""
    -- This rebuild is what decides which server fields survive into the dialog, and `identifier`
    -- did not: the API has always returned the ISBN and the plugin has always dropped it here,
    -- leaving people to open the downloaded file on a desktop and read the number off its
    -- copyright page.
    book.isbn = normalizeIsbn(raw.identifier)
    -- Record an absent description as "", the way title/author/publisher/series above do. It used to
    -- substitute a "No Description" string, which made a missing description indistinguishable from
    -- a book whose description is literally those words -- and left callers no way to detect the
    -- absence and react to it.
    book.description = type(raw.description) == "string" and raw.description or ""
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

return BookDetailsDialog
