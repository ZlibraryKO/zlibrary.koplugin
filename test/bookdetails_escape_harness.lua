-- Comment author names, comment text and relative dates come from the Z-Library server and are
-- interpolated into the HTML handed to ScrollHtmlWidget. Without escaping, a "<" or "&" in any
-- of them corrupts the layout or injects markup. bookdetails_dialog.lua escapes them through a
-- file-local htmlEscape helper; this harness pulls that helper out of the source and checks it
-- neutralises exactly the characters that matter to an HTML attribute/text context.
--
-- usage: luajit bookdetails_escape_harness.lua <plugin-root> <luasocket-src>

local PLUGIN = assert(arg[1], "usage: luajit bookdetails_escape_harness.lua <plugin-root> <luasocket-src>")
package.path = PLUGIN .. "/test/?.lua;" .. package.path
local support = require("support")

local htmlEscape = support.extract_function(
    PLUGIN .. "/zlibrary/bookdetails_dialog.lua", "htmlEscape",
    { tostring = tostring, string = string })

local r = support.reporter()

r.check("angle brackets escaped",
    htmlEscape("<b>bold</b>") == "&lt;b&gt;bold&lt;/b&gt;",
    htmlEscape("<b>bold</b>"))
r.check("ampersand escaped before anything else",
    htmlEscape("a & b < c") == "a &amp; b &lt; c",
    htmlEscape("a & b < c"))
r.check("existing entity not double-escaped",
    htmlEscape("&lt;") == "&amp;lt;",
    htmlEscape("&lt;"))
r.check("quotes escaped",
    htmlEscape([["it's"]]) == "&quot;it&#39;s&quot;",
    htmlEscape([["it's"]]))
r.check("plain text passes through unchanged",
    htmlEscape("Great book, 5 stars!") == "Great book, 5 stars!",
    htmlEscape("Great book, 5 stars!"))

r.finish()
