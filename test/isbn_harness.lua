-- Z-Library returns the ISBN with every book record and the plugin dropped it, so the number that
-- a desktop needs to identify an edition had to be dug out of the downloaded file by hand.
-- bookdetails_dialog.lua now picks one out of that field through a file-local normalizeIsbn; this
-- harness pulls that helper out of the source and checks it on the shapes the server actually
-- sends -- and, as much as it matters, on the junk it sometimes sends instead.
--
-- usage: luajit isbn_harness.lua <plugin-root> <luasocket-src>

local PLUGIN = assert(arg[1], "usage: luajit isbn_harness.lua <plugin-root> <luasocket-src>")
package.path = PLUGIN .. "/test/?.lua;" .. package.path
local support = require("support")

local normalizeIsbn = support.extract_function(
    PLUGIN .. "/zlibrary/bookdetails_dialog.lua", "normalizeIsbn",
    { type = type, string = string })

local r = support.reporter()

-- ---------------------------------------------------------------- what it should find
r.check("bare ISBN-13 with no separator in the field",
    normalizeIsbn("9780306406157") == "9780306406157",
    normalizeIsbn("9780306406157"))
r.check("hyphens stripped",
    normalizeIsbn("978-0-306-40615-7") == "9780306406157",
    normalizeIsbn("978-0-306-40615-7"))
r.check("spaces stripped",
    normalizeIsbn("978 0 306 40615 7") == "9780306406157",
    normalizeIsbn("978 0 306 40615 7"))
r.check("979 prefix accepted, not only 978",
    normalizeIsbn("9791234567896") == "9791234567896",
    normalizeIsbn("9791234567896"))
r.check("ISBN-10 when that is all there is",
    normalizeIsbn("0306406152") == "0306406152",
    normalizeIsbn("0306406152"))
r.check("ISBN-10 check digit X kept",
    normalizeIsbn("030640615X") == "030640615X",
    normalizeIsbn("030640615X"))
r.check("lowercase x upper-cased",
    normalizeIsbn("030640615x") == "030640615X",
    normalizeIsbn("030640615x"))

-- ---------------------------------------------------------------- which one it should prefer
-- Calibre's metadata sources key on the 13-digit form, so a record offering both must not hand
-- back whichever came first in the string.
r.check("ISBN-13 wins when listed second",
    normalizeIsbn("0306406152, 9780306406157") == "9780306406157",
    normalizeIsbn("0306406152, 9780306406157"))
r.check("ISBN-13 wins when listed first",
    normalizeIsbn("9780306406157, 0306406152") == "9780306406157",
    normalizeIsbn("9780306406157, 0306406152"))
r.check("semicolons separate as well as commas",
    normalizeIsbn("0306406152; 9780306406157") == "9780306406157",
    normalizeIsbn("0306406152; 9780306406157"))
r.check("first usable ISBN-10 wins over a later one",
    normalizeIsbn("0306406152, 030640615X") == "0306406152",
    normalizeIsbn("0306406152, 030640615X"))
r.check("an ISBN survives junk listed beside it",
    normalizeIsbn("B00X57B4KE, 9780306406157") == "9780306406157",
    normalizeIsbn("B00X57B4KE, 9780306406157"))

-- ---------------------------------------------------------------- what it must not invent
-- The failure that matters is not a missing ISBN -- the line simply does not appear -- but a
-- confident wrong one, which sends someone to the wrong edition in Calibre with no hint anything
-- went wrong.
r.check("absent field", normalizeIsbn(nil) == nil, normalizeIsbn(nil))
r.check("empty field", normalizeIsbn("") == nil, normalizeIsbn(""))
r.check("non-string field", normalizeIsbn(9780306406157) == nil, normalizeIsbn(9780306406157))
r.check("separators only", normalizeIsbn(" , ; ") == nil, normalizeIsbn(" , ; "))
r.check("ASIN is not an ISBN",
    normalizeIsbn("B00X57B4KE") == nil, normalizeIsbn("B00X57B4KE"))
r.check("13 digits that are not a Bookland prefix rejected",
    normalizeIsbn("1234567890123") == nil, normalizeIsbn("1234567890123"))
r.check("letters are not stripped to make a number fit",
    normalizeIsbn("ISBN 9780306406157") == nil, normalizeIsbn("ISBN 9780306406157"))
r.check("too short", normalizeIsbn("030640615") == nil, normalizeIsbn("030640615"))
r.check("too long", normalizeIsbn("97803064061577") == nil, normalizeIsbn("97803064061577"))
r.check("X only valid as the final ISBN-10 digit",
    normalizeIsbn("X306406152") == nil, normalizeIsbn("X306406152"))

r.finish()
