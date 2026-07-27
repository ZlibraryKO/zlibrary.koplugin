-- Comment replies whose parent_id points at a comment missing from the fetched page used to be
-- dropped silently: the "flatten if parent not found" fallback only fired when NO root comment
-- existed at all, so with at least one root present the orphan replies sat in the children map
-- forever and were never rendered. _renderComments now appends such orphans at the end as
-- top-level comments.
--
-- This harness compiles the real _renderComments out of bookdetails_dialog.lua and checks that
-- threaded replies, orphans, and the flatten fallback all render exactly once.
--
-- usage: luajit bookdetails_orphans_harness.lua <plugin-root> <luasocket-src>

local PLUGIN = assert(arg[1], "usage: luajit bookdetails_orphans_harness.lua <plugin-root> <luasocket-src>")
package.path = PLUGIN .. "/test/?.lua;" .. package.path
local support = require("support")

-- support.extract_function only handles file-local `local function`s; _renderComments is a
-- method. Same uniqueness rule as support.extract_function, for the same reason.
local function extract_method(path, name)
    local fh = assert(io.open(path), "cannot open " .. path)
    local src = "\n" .. fh:read("*a")
    fh:close()
    local anchor = "\nfunction BookDetailsDialog:" .. name
    local n, pos = 0, 1
    while true do
        local s, e = string.find(src, anchor, pos, true)
        if not s then break end
        n = n + 1
        pos = e + 1
    end
    assert(n == 1, string.format("'%s' appears %d times in %s -- refusing to guess which one is live",
        anchor, n, path))
    -- Every `end` inside the method is indented; its own `end` is the first one at line start.
    local body = src:match("(" .. anchor:gsub("(%W)", "%%%1") .. ".-\nend\n)")
    assert(body, "could not delimit the end of " .. name)
    return body
end

local htmlEscape = support.extract_function(
    PLUGIN .. "/zlibrary/bookdetails_dialog.lua", "htmlEscape",
    { tostring = tostring, string = string })

local BookDetailsDialog = {}
local chunk = assert(loadstring(
    extract_method(PLUGIN .. "/zlibrary/bookdetails_dialog.lua", "_renderComments"),
    "=bookdetails_orphans"))
setfenv(chunk, {
    BookDetailsDialog = BookDetailsDialog,
    table = table, string = string, type = type, ipairs = ipairs, pairs = pairs,
    tostring = tostring, T = function(s) return s end,
    htmlEscape = htmlEscape,
})
chunk()
local render = BookDetailsDialog._renderComments

local function count_occurrences(haystack, needle)
    local n, pos = 0, 1
    while true do
        local s, e = string.find(haystack, needle, pos, true)
        if not s then break end
        n = n + 1
        pos = e + 1
    end
    return n
end

local function comment(id, parent_id, text)
    return { id = id, parent_id = parent_id, text = text, user = { name = "u" .. id } }
end

local r = support.reporter()

-- A root, its proper reply, an orphan (parent 999 missing), and the orphan's own child. The
-- comments list arrives newest first; _renderComments collects roots in reverse.
local comments = {
    comment(4, 3, "GRANDCHILD-D"),
    comment(3, 999, "ORPHAN-C"),
    comment(2, 1, "CHILD-B"),
    comment(1, nil, "ROOT-A"),
}
local html = render({}, comments)

for _, text in ipairs({ "ROOT-A", "CHILD-B", "ORPHAN-C", "GRANDCHILD-D" }) do
    r.check(text .. " rendered exactly once",
        count_occurrences(html, text) == 1,
        string.format("found %d", count_occurrences(html, text)))
end

local pos_root = string.find(html, "ROOT-A", 1, true)
local pos_child = string.find(html, "CHILD-B", 1, true)
local pos_orphan = string.find(html, "ORPHAN-C", 1, true)
local pos_grandchild = string.find(html, "GRANDCHILD-D", 1, true)
r.check("proper reply renders under its root", pos_child > pos_root,
    string.format("root=%d child=%d", pos_root or -1, pos_child or -1))
r.check("orphan renders after the threaded comments",
    pos_orphan > pos_child, string.format("child=%d orphan=%d", pos_child or -1, pos_orphan or -1))
r.check("orphan's own child renders with it", pos_grandchild > pos_orphan,
    string.format("orphan=%d grandchild=%d", pos_orphan or -1, pos_grandchild or -1))

-- The orphan is appended as a TOP-LEVEL comment, not indented like a reply.
local last_node_start, scan = nil, 1
while true do
    local s = string.find(html, "comment-node", scan, true)
    if not s or s >= pos_orphan then break end
    last_node_start = s
    scan = s + 1
end
local orphan_opening = html:sub(last_node_start, pos_orphan)
r.check("orphan not indented as a reply",
    not string.find(orphan_opening, "margin-left", 1, true),
    orphan_opening)

-- The flatten fallback (no root at all) still renders every comment, and the orphan pass must
-- not render them a second time.
html = render({}, { comment(10, 999, "LONE-E") })
r.check("flatten fallback renders the comment exactly once",
    count_occurrences(html, "LONE-E") == 1,
    string.format("found %d", count_occurrences(html, "LONE-E")))

-- A fully threaded page appends nothing: one node per comment, no duplicates.
html = render({}, { comment(2, 1, "CHILD-B"), comment(1, nil, "ROOT-A") })
r.check("fully threaded page renders one node per comment",
    count_occurrences(html, "comment-node") == 2,
    string.format("found %d", count_occurrences(html, "comment-node")))

r.finish()
