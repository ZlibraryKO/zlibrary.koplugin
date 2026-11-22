-- Author folders: which folder a finished download is filed into, and what the author folder is
-- called.
--
-- Two file-local functions in download.lua:
--
--   * _authorFolderName turns the author text from the server into one safe folder segment, or
--     nil for no author folder. The text is not the user's, so it must never yield "..", "." or
--     "", which would put the book outside the download folder or in it under another name. It
--     must also survive FAT: no trailing dots or spaces, a length cap, and a cut that never
--     lands inside a UTF-8 character.
--   * _filingDestDir combines the chosen category (if any) with the author folder (if any):
--     category first, author below it. With no author it must give exactly what category
--     filing gave before, so the setting being off changes nothing.
--
-- Drives the real functions extracted from download.lua.

local PLUGIN = assert(arg[1], "usage: luajit author_folder_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local DOWNLOAD = PLUGIN .. "/zlibrary/download.lua"

-- The same rule as Config.sanitizeCategoryName (pinned by categories_harness): trim, then replace
-- the characters a folder name cannot hold.
local function sanitize(name)
    if type(name) ~= "string" then return "" end
    return (name:gsub("^%s*(.-)%s*$", "%1"):gsub("[/\\?%*:|\"<>%c]", "_"))
end
local Config = { sanitizeCategoryName = sanitize }

local function is_valid_utf8(s)
    local i, n = 1, #s
    while i <= n do
        local c = s:byte(i)
        local len = c < 0x80 and 1 or (c >= 0xF0 and 4) or (c >= 0xE0 and 3) or (c >= 0xC0 and 2)
        if not len then return false end
        for j = i + 1, i + len - 1 do
            local b = s:byte(j)
            if not b or b < 0x80 or b >= 0xC0 then return false end
        end
        i = i + len
    end
    return true
end

-- ---------------------------------------------------------------- _authorFolderName
local name_of = support.extract_function(DOWNLOAD, "_authorFolderName", {
    Config = Config, type = type,
    AUTHOR_FOLDER_MAX_BYTES = 100,
})

local function same(label, input, want)
    local got = name_of(input)
    r.check(label, got == want, string.format("%q -> %q, want %q", tostring(input), tostring(got), tostring(want)))
end

same("a plain name is kept", "Frank Herbert", "Frank Herbert")
same("co-authors stay one folder", "Terry Pratchett, Neil Gaiman", "Terry Pratchett, Neil Gaiman")
same("whitespace runs and newlines collapse to one space", "  Frank\n\tHerbert  ", "Frank Herbert")
same("unsafe characters become _", "AC/DC: Live ", "AC_DC_ Live")
same("quotes and question marks become _", 'Who "Is" It?', "Who _Is_ It_")
same("a trailing dot is dropped", "Tolkien, J. R. R.", "Tolkien, J. R. R")
same("trailing dots and spaces are dropped together", "Anon . . ", "Anon")
same("non-ASCII names are kept", "Фёдор Достоевский", "Фёдор Достоевский")
same("nil -> no folder", nil, nil)
same("a non-string -> no folder", 42, nil)
same("empty -> no folder", "", nil)
same("blank -> no folder", "   ", nil)
same("the unknown-author placeholder -> no folder", "Unknown Author", nil)
same("the placeholder with spaces -> no folder", "  Unknown Author ", nil)
same("'.' -> no folder", ".", nil)
same("'..' -> no folder (no way out of the download folder)", "..", nil)
same("'...' -> no folder", "...", nil)
same("a slash path becomes one plain folder name", "../..", ".._")

do
    -- 2-byte characters starting at an odd offset, so byte 100 falls inside one.
    local long = "x" .. string.rep("é", 150)
    local got = name_of(long)
    r.check("a long name is cut to at most 100 bytes", got and #got <= 100, "got " .. tostring(got and #got))
    r.check("the cut does not split a UTF-8 character", got and is_valid_utf8(got), "got " .. tostring(got))
    r.check("the cut keeps as much as fits", got and #got == 99, "got " .. tostring(got and #got))

    local three = string.rep("漢", 40) -- 120 bytes, 3 per character
    got = name_of(three)
    r.check("3-byte characters: cut between characters", got == string.rep("漢", 33), "got " .. tostring(got and #got))

    local spaced = string.rep("a", 98) .. " .bcd"
    got = name_of(spaced)
    r.check("no trailing dot or space after the cut", got == string.rep("a", 98), "got " .. tostring(got))
end

-- ---------------------------------------------------------------- _filingDestDir
do
    local category_dir = support.extract_function(DOWNLOAD, "_categoryDestDir", { Config = Config })
    local dest = support.extract_function(DOWNLOAD, "_filingDestDir", { _categoryDestDir = category_dir })

    local function case(label, target, author, want_dir, want_label)
        local dir, lbl = dest("/dl", target, author)
        r.check(label, dir == want_dir and lbl == want_label,
            string.format("got %s / %s, want %s / %s", tostring(dir), tostring(lbl),
                tostring(want_dir), tostring(want_label)))
    end

    case("no category, no author -> nil (the book stays put)", nil, nil, nil, nil)
    case("category only -> the category folder, as before",
        { name = "Fiction", sub = "Sci-fi" }, nil, "/dl/Fiction/Sci-fi", "Fiction › Sci-fi")
    case("top-level category only", { name = "Fiction" }, nil, "/dl/Fiction", "Fiction")
    case("author only -> <download>/<author>", nil, "Frank Herbert", "/dl/Frank Herbert", "Frank Herbert")
    case("category and author -> author below the category",
        { name = "Fiction", sub = "Sci-fi" }, "Frank Herbert",
        "/dl/Fiction/Sci-fi/Frank Herbert", "Fiction › Sci-fi › Frank Herbert")
    case("a category that sanitises away, with an author -> <download>/<author>",
        { name = "   " }, "Frank Herbert", "/dl/Frank Herbert", "Frank Herbert")
    case("a category that sanitises away, no author -> nil", { name = "   " }, nil, nil, nil)
end

r.finish()
