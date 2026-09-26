-- Does "the cover is cached" mean the cover is cached?
--
-- ApiHelper.downloadCover fetches a cover, renders it once to prove it is a real image, and moves
-- it into the cover cache. It used to ignore what that last step answered and return true either
-- way, so a cache that could not take the file -- unwritable or full directory, a rename and a
-- copy that both failed -- was reported as a hit. Two callers believed it: menu.lua re-checks the
-- cache before refreshing a row, found nothing and left a blank slot that nothing ever retries,
-- and Zlibrary:downloadAndShowCover read the same nil back and passed it to showCoverDialog.
--
-- Drives the real function against a cover cache whose insert can be made to fail, so the whole
-- contract -- what is downloaded, what is deleted, and what is claimed -- is checked where it runs.

local PLUGIN = assert(arg[1], "usage: luajit cover_cache_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local rig
local function reset(opts)
    opts = opts or {}
    rig = {
        cached = opts.cached,              -- what the cache already holds for this hash
        insert_ok = opts.insert_ok ~= false,
        download = opts.download or { success = true },
        render_ok = opts.render_ok ~= false,
        files = opts.files or {},          -- paths that exist on disk
        downloads = 0, inserts = 0, removed = {}, freed = 0,
    }
end

local env = {
    type = type,
    pcall = pcall,
    logger = { err = function() end, warn = function() end, dbg = function() end },
    util = {
        fileExists = function(path) return rig.files[path] == true end,
        removeFile = function(path)
            rig.removed[#rig.removed + 1] = path
            rig.files[path] = nil
        end,
    },
    Cache = {
        new = function()
            return {
                get = function() return rig.cached end,
                getTempPath = function(_, hash) return "/cache/covers/" .. hash .. ".jpg.downloading" end,
                insert = function()
                    rig.inserts = rig.inserts + 1
                    -- The real CoverCache answers with the cached path, or false when the move failed.
                    return rig.insert_ok and "/cache/covers/abc.jpg" or false
                end,
            }
        end,
    },
    Api = {
        downloadBookCover = function(_, target)
            rig.downloads = rig.downloads + 1
            if rig.download.success then rig.files[target] = true end
            return rig.download
        end,
    },
    RenderImage = {
        renderImageFile = function()
            if not rig.render_ok then error("corrupt image") end
            return { free = function() rig.freed = rig.freed + 1 end }
        end,
    },
}

local block = support.extract_block(PLUGIN .. "/zlibrary/preloader.lua",
    "(\nfunction ApiHelper%.downloadCover%(.-\nend\n)")
env.ApiHelper = {}
local chunk = assert(loadstring(block, "=downloadCover"))
setfenv(chunk, env)
chunk()
local downloadCover = env.ApiHelper.downloadCover

local TEMP = "/cache/covers/abc.jpg.downloading"
local function was_removed(path)
    for _, p in ipairs(rig.removed) do if p == path then return true end end
    return false
end

-- ---------------------------------------------------------------- the bug
reset{ insert_ok = false }
local ok = downloadCover("https://cdn.example/c.jpg", "abc")
r.check("a cover the cache would not take is reported as a failure", ok == false,
        "it claimed the cover was cached")
-- Asserted on the file, not on the fact that removeFile was called: downloadCover clears a stale
-- temp file BEFORE downloading too, so counting calls would pass whether or not the failed insert
-- cleans up after itself.
r.check("and its temp file is not left behind", rig.files[TEMP] == nil,
        "the .downloading file stayed on disk")

-- ---------------------------------------------------------------- the ordinary path
reset{}
ok = downloadCover("https://cdn.example/c.jpg", "abc")
r.check("a cover that lands in the cache is reported as cached",
        ok == true and rig.inserts == 1 and rig.downloads == 1,
        string.format("ok=%s inserts=%d downloads=%d", tostring(ok), rig.inserts, rig.downloads))
r.check("and the rendered image is freed rather than leaked", rig.freed == 1,
        rig.freed .. " free(s)")

-- ---------------------------------------------------------------- paths that were already right
reset{ cached = "/cache/covers/abc.jpg" }
ok = downloadCover("https://cdn.example/c.jpg", "abc")
r.check("an already-cached cover costs no download", ok == true and rig.downloads == 0,
        rig.downloads .. " download(s) for a cover already in the cache")

reset{ download = { success = false, error = "HTTP Error: 404" } }
ok = downloadCover("https://cdn.example/c.jpg", "abc")
r.check("a failed download is a failure, and nothing is inserted",
        ok == false and rig.inserts == 0, "inserts = " .. rig.inserts)

reset{ render_ok = false }
ok = downloadCover("https://cdn.example/c.jpg", "abc")
r.check("a body that is not a real image is a failure, and is deleted",
        ok == false and rig.inserts == 0 and rig.files[TEMP] == nil,
        "a corrupt cover was kept or cached")

-- skip_conflicts is how the preloader avoids unlinking a .downloading file that the menu's own
-- workers are writing at that moment.
reset{ files = { [TEMP] = true } }
ok = downloadCover("https://cdn.example/c.jpg", "abc", true)
r.check("a temp file another worker is writing is left alone",
        ok == false and rig.downloads == 0 and not was_removed(TEMP),
        "the concurrent download's temp file was touched")

reset{}
ok = downloadCover(nil, "abc")
r.check("a missing url or hash is refused before anything is touched",
        ok == false and rig.downloads == 0 and downloadCover("https://cdn.example/c.jpg", nil) == false,
        "a bad argument got past the guard")

r.finish()
