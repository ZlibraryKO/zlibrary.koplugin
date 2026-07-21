-- Is the downloaded file's name safe to write?
--
-- It was not. Browse-list rows are stubs: they carry an id, a hash and a title, and the file
-- extension only arrives with the full book details. Missing, the API's placeholder "N/A" came
-- through as the extension -- truthy, so the `or "unknown"` fallback never fired -- and the
-- slash inside it turned
--
--     /books/_Unsorted/The 48 Laws of Power - Robert Greene.N/A.downloading
--
-- into a directory that does not exist. The download failed at the open, reporting a path
-- nobody had asked for. Title and author were both sanitised; the extension was not.
--
-- Drives the real _usableFormat, since what counts as a usable extension is the whole question.

local PLUGIN = assert(arg[1], "usage: luajit download_filename_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local usableFormat = support.extract_function(PLUGIN .. "/zlibrary/download.lua", "_usableFormat", {
    type = type,
    util = { trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end },
})

-- ---------------------------------------------------------------- what is not an extension
local unusable = {
    { "N/A", "the API's placeholder for an unknown type -- the one that shipped a broken path" },
    { "", "empty" },
    { "   ", "whitespace only" },
    { "/", "a bare separator" },
    { "a/b", "contains a separator" },
    { "..", "would climb out of the download directory" },
    { "\\\\", "a Windows separator" },
    { ":", "a drive separator" },
}
for _, case in ipairs(unusable) do
    local value, why = case[1], case[2]
    local got = usableFormat(value)
    r.check(string.format("%q is refused (%s)", value, why), got == nil,
            "returned " .. tostring(got))
end

r.check("a non-string is refused", usableFormat(nil) == nil and usableFormat(42) == nil,
        "a missing or numeric format was accepted")

-- ---------------------------------------------------------------- what is
local usable = { epub = "epub", pdf = "pdf", mobi = "mobi", azw3 = "azw3", djvu = "djvu" }
for value, want in pairs(usable) do
    r.check(string.format("%q is kept as %q", value, want), usableFormat(value) == want,
            "returned " .. tostring(usableFormat(value)))
end
r.check("surrounding whitespace is trimmed", usableFormat("  epub  ") == "epub",
        "returned " .. tostring(usableFormat("  epub  ")))

-- Anything that survives must be safe to paste into a path. This is the property that was
-- missing, so assert it directly rather than only on the cases listed above.
local hostile = { "e/pub", "e\\\\pub", "e:pub", "e*pub", "e?pub", "e|pub", "e<pub", "e>pub", 'e"pub' }
for _, value in ipairs(hostile) do
    local got = usableFormat(value)
    if got ~= nil then
        r.check("what survives cannot break a path: " .. value,
                not got:find("[/\\\\?%*:|\"<>]"), "returned " .. got)
    else
        r.check("what survives cannot break a path: " .. value, true)
    end
end

-- ---------------------------------------------------------------- and the wiring
-- Downloading moved out of main.lua into its own module; the filename is built there now.
local main_src = (function()
    local fh = assert(io.open(PLUGIN .. "/zlibrary/download.lua"))
    local s = fh:read("*a"); fh:close(); return s
end)()

-- The filename must be built from the checked value, not the raw field.
r.check("the filename uses the checked extension",
        main_src:find('string.format("%s - %s.%s", safe_title, safe_author, book_format)', 1, true) ~= nil,
        "the filename is still built from book.format directly")
r.check("the raw format is no longer pasted into a filename",
        main_src:find('safe_author, book.format', 1, true) == nil,
        "book.format still reaches the filename unchecked")

-- An unusable extension must send the caller to fetch details rather than guess one: a file
-- saved under the wrong extension opens in nothing.
-- The call goes back through the plugin method rather than straight to the module function:
-- the body moved verbatim, and that is what keeps it verbatim.
r.check("an unknown extension fetches the details first",
        main_src:find("self:_fetchDetailsThenDownload(book)", 1, true) ~= nil,
        "nothing recovers a missing extension")
r.check("the fetch checks the extension it got back",
        main_src:match("fetchDetailsThenDownload.-_usableFormat%(api_result%.book%.format%)") ~= nil,
        "the fetched details are used without checking the extension arrived")

r.finish()
