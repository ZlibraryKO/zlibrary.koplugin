-- What a book row says. A score of 0 means nobody rated the book, and the row used to print it as
-- "Rating: 0", which reads as a verdict. A size can arrive as bare bytes, which says nothing.

local PLUGIN = assert(arg[1], "usage: luajit book_row_harness.lua <plugin-root>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()
local BookRow = dofile(PLUGIN .. "/zlibrary/book_row.lua")

local function details(book, hide_format) return BookRow.details(book, hide_format) end

r.check("year, format, size and rating, in that order",
    details({ year = "2000", format = "EPUB", size = "1.77 MB", rating = "4.5" }) == "2000 · EPUB · 1.77 MB · \u{2605}\u{00A0}4.5",
    details({ year = "2000", format = "EPUB", size = "1.77 MB", rating = "4.5" }))
r.check("a rating of 0 is left out", details({ rating = "0" }) == "", details({ rating = "0" }))
r.check("a rating of 0.0 is left out", details({ rating = "0.0" }) == "", details({ rating = "0.0" }))
r.check("a numeric 0 rating is left out", details({ rating = 0 }) == "", details({ rating = 0 }))
r.check("N/A fields are left out", details({ year = "N/A", format = "N/A", size = "N/A", rating = "N/A" }) == "", "not empty")
r.check("a year of 0 is left out", details({ year = 0, size = "1 MB" }) == "1 MB", details({ year = 0, size = "1 MB" }))
r.check("a size in bare bytes is left out", details({ size = 1853761 }) == "", details({ size = 1853761 }))
r.check("the format can be hidden", details({ format = "EPUB", size = "1 MB" }, true) == "1 MB", details({ format = "EPUB", size = "1 MB" }, true))

local row = BookRow.new("Dune", "Frank Herbert", { year = "1965" })
r.check("the title is bold on its own line, author and details below",
    BookRow.text(row) == "\u{FFF1}\u{FFF2}Dune\u{FFF3}\nFrank Herbert · 1965", BookRow.text(row))
local bare = BookRow.new("Dune", "Frank Herbert", {})
r.check("no details means no trailing separator",
    BookRow.text(bare) == "\u{FFF1}\u{FFF2}Dune\u{FFF3}\nFrank Herbert", BookRow.text(bare))

r.finish()
