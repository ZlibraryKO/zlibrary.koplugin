-- Tapping a cover must not be able to take the UI down.
--
-- Ui.showCoverDialog guarded itself with util.fileExists(img_path), which cannot do the job: it
-- calls io.open, and io.open raises on nil rather than answering false. The one caller
-- (Zlibrary:downloadAndShowCover) passes whatever cover_cache:get returns, and that is nil
-- whenever the cover is not in the cache -- evicted by the LRU sweep since the download, or never
-- inserted because _safeCopy failed while downloadCover reported success anyway. The reader taps
-- a cover and the handler dies with "bad argument #1 to 'open' (string expected, got nil)".
--
-- Drives the real Ui.showCoverDialog with util.fileExists behaving exactly as KOReader's does.

local PLUGIN = assert(arg[1], "usage: luajit cover_dialog_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local shown
local existing_files = { ["/cache/covers/abc.jpg"] = true }

local env = {
    type = type,
    require = function(mod)
        assert(mod == "ui/widget/imageviewer", "unexpected require: " .. tostring(mod))
        return { new = function(_, spec) return spec end }
    end,
    logger = { warn = function() end },
    util = {
        -- KOReader's util.fileExists, faithfully: io.open raises on a nil path.
        fileExists = function(path)
            if path == nil then error("bad argument #1 to 'open' (string expected, got nil)", 2) end
            return existing_files[path] == true
        end,
    },
    _showAndTrackDialog = function(dialog) shown = dialog return dialog end,
}

local block = support.extract_block(PLUGIN .. "/zlibrary/ui.lua",
    "(\nfunction Ui%.showCoverDialog%(.-\nend\n)")
env.Ui = {}
local chunk = assert(loadstring(block, "=showCoverDialog"))
setfenv(chunk, env)
chunk()
local showCoverDialog = env.Ui.showCoverDialog

local function attempt(path)
    shown = nil
    local ok, err = pcall(showCoverDialog, "A Book", path)
    return ok, tostring(err)
end

-- The crash: a cover the cache no longer holds.
local ok, err = attempt(nil)
r.check("a nil cover path is refused instead of raising", ok, err)
r.check("and nothing is shown for it", shown == nil, "a dialog was opened for a cover with no file")

ok, err = attempt("")
r.check("an empty cover path is refused too", ok, err)

-- A path that simply is not there: already handled before this fix, and must stay handled.
ok = attempt("/cache/covers/gone.jpg")
r.check("a missing file is still refused quietly", ok and shown == nil,
        "a dialog was opened for a file that does not exist")

-- The case that must keep working.
ok, err = attempt("/cache/covers/abc.jpg")
r.check("a cover that exists is still shown", ok and type(shown) == "table"
        and shown.file == "/cache/covers/abc.jpg", err)

r.finish()
