-- After a download, does the FileManager get refreshed so the new book shows without a manual
-- reload -- and only when there is a FileManager to refresh?
--
-- The reported problem: a reader sitting in the folder a book downloads into does not see it appear,
-- and reads that as a failed download. The fix refreshes the current folder. Two things have to hold:
--
--   * when the FileManager is open (its instance is set), its listing is refreshed exactly once
--   * when it is not (a book is open, so the instance is nil), nothing happens and nothing crashes --
--     indexing a nil instance would throw
--
-- Drives the real _refreshFileManagerListing extracted from download.lua, with the FileManager module
-- and UIManager:nextTick stubbed so the deferred refresh runs synchronously and is observable.

local PLUGIN = assert(arg[1], "usage: luajit filemanager_refresh_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local DOWNLOAD = PLUGIN .. "/zlibrary/download.lua"

-- Build the function against a fake FileManager module (returned by the stubbed require) and a
-- UIManager whose nextTick fires immediately, so the refresh is synchronous and countable.
local function build(instance)
    local rec = { refreshes = 0, ticks = 0 }
    local fm = { instance = instance }
    if instance then
        instance.onRefresh = function() rec.refreshes = rec.refreshes + 1 end
    end
    local env = {
        UIManager = {
            nextTick = function(_, fn) rec.ticks = rec.ticks + 1; fn() end,
            setDirty = function() rec.dirtied = (rec.dirtied or 0) + 1 end,
        },
        require = function(name) rec.required = name; return fm end,
    }
    rec.fn = support.extract_function(DOWNLOAD, "_refreshFileManagerListing", env)
    return rec
end

-- ---------------------------------------------------------------- FileManager open
do
    local rec = build({})
    rec.fn()
    r.check("the refresh is deferred to the next tick", rec.ticks == 1,
            "nextTick called " .. rec.ticks .. " times")
    r.check("it asks for the FileManager module", rec.required == "apps/filemanager/filemanager",
            "required " .. tostring(rec.required))
    r.check("the current folder is refreshed exactly once", rec.refreshes == 1,
            "onRefresh called " .. rec.refreshes .. " times")
    r.check("the FileManager is marked dirty so the new file actually repaints",
            rec.dirtied == 1, "setDirty called " .. tostring(rec.dirtied) .. " times")
end

-- ---------------------------------------------------------------- FileManager not open (reading)
do
    local rec = build(nil)
    local ok, err = pcall(rec.fn)
    r.check("it does not crash when no FileManager is open", ok,
            "raised: " .. tostring(err))
    r.check("and it refreshes nothing", rec.refreshes == 0,
            "onRefresh ran " .. rec.refreshes .. " times")
    r.check("and it marks nothing dirty", (rec.dirtied or 0) == 0,
            "setDirty ran " .. tostring(rec.dirtied) .. " times")
end

-- ---------------------------------------------------------------- wiring
local function slurp(path)
    local fh = assert(io.open(path)); local s = fh:read("*a"); fh:close(); return s
end
local src = slurp(DOWNLOAD)
r.check("the download flow calls the refresh after a finished download",
        src:find("_refreshFileManagerListing()", 1, true) ~= nil,
        "download.lua never invokes the refresh")
r.check("the refresh is guarded on FileManager.instance",
        src:find("FileManager.instance", 1, true) ~= nil,
        "the instance guard is missing -- a nil instance would crash")

r.finish()
