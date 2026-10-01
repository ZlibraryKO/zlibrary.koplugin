-- What is allowed to become a book on disk.
--
-- Api.downloadBook writes the body to <target>.downloading and renames it onto the target only
-- once the whole thing has arrived -- so a failure never destroys a copy the reader already has.
-- The rename was reached on any 200 that was not HTML, however, including a 200 with nothing in
-- it. These mirrors answer with empty bodies often enough (the same servers hand out 502s and
-- challenge pages), and a 0-byte file renamed into place is reported as a finished download,
-- offered to the reader, opens in nothing -- and replaces the book if they already owned it.
--
-- Drives the real Api.downloadBook with io and os stubbed, so nothing is written anywhere.

local PLUGIN = assert(arg[1], "usage: luajit download_integrity_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local TARGET = "/books/A Book.epub"
local TEMP = TARGET .. ".downloading"

local rig
local function reset(response)
    rig = {
        response = response,
        opened = {}, closed = 0, removed = {}, renamed = nil, rename_ok = true,
    }
end

local env = {
    type = type, tostring = tostring, string = string, pcall = pcall,
    T = function(s) return s end,
    logger = { info = function() end, warn = function() end, err = function() end, dbg = function() end },
    Config = {
        getUserAgent = function() return "UA" end,
        getDownloadTimeout = function() return { 15, -1 } end,
    },
    socketutil = { file_sink = function(f) return f end },
    io = {
        open = function(path, mode)
            table.insert(rig.opened, { path = path, mode = mode })
            return { close = function() rig.closed = rig.closed + 1 end }
        end,
    },
    os = {
        remove = function(path) table.insert(rig.removed, path) return true end,
        rename = function(from, to)
            if not rig.rename_ok then return nil, "Read-only file system" end
            rig.renamed = { from = from, to = to }
            return true
        end,
    },
}
env.Api = {
    getDownloadTempPath = function(target) return target .. ".downloading" end,
    makeHttpRequest = function() return rig.response end,
}

-- The real one, not a copy: downloadBook builds its Cookie header with it, and a stand-in here
-- would stop telling the truth the moment the session format changed.
env._sessionCookie = support.extract_function(PLUGIN .. "/zlibrary/api.lua", "_sessionCookie",
    { string = string })

local block = support.extract_block(PLUGIN .. "/zlibrary/api.lua",
    "(\nfunction Api%.downloadBook%(.-\nend\n)")
local chunk = assert(loadstring(block, "=downloadBook"))
setfenv(chunk, env)
chunk()
local downloadBook = env.Api.downloadBook

local function was_removed(path)
    for _, p in ipairs(rig.removed) do if p == path then return true end end
    return false
end
local function download()
    return downloadBook("https://cdn.example/book", TARGET, "1", "key", nil, nil)
end

-- ---------------------------------------------------------------- the bug
reset{ status_code = 200, headers = { ["content-type"] = "application/epub+zip" }, bytes_received = 0 }
local res = download()
r.check("a 200 that carried no bytes is not a download", res.success ~= true and res.error ~= nil,
        "an empty body was reported as a finished book")
r.check("and nothing is renamed onto the target", rig.renamed == nil,
        "a 0-byte file was moved onto the reader's copy")
r.check("and the temp file is cleaned up", was_removed(TEMP), "the .downloading file was left behind")

-- ---------------------------------------------------------------- a real book
reset{ status_code = 200, headers = { ["content-type"] = "application/epub+zip" }, bytes_received = 41231 }
res = download()
r.check("a body that arrived is renamed onto the target",
        res.success == true and rig.renamed ~= nil and rig.renamed.from == TEMP and rig.renamed.to == TARGET,
        "error = " .. tostring(res.error))
r.check("and the temp file is not deleted afterwards", not was_removed(TEMP),
        "the finished download was removed")

-- ---------------------------------------------------------------- failures that already worked
reset{ status_code = 200, headers = { ["content-type"] = "text/html; charset=utf-8" }, bytes_received = 5000 }
res = download()
r.check("an HTML page is still refused rather than saved as a book",
        res.success ~= true and rig.renamed == nil and was_removed(TEMP),
        "error = " .. tostring(res.error))

reset{ status_code = 402, headers = {}, bytes_received = 120 }
res = download()
r.check("a non-200 is still refused", res.success ~= true and rig.renamed == nil,
        "error = " .. tostring(res.error))

reset{ status_code = 200, headers = { ["content-type"] = "application/epub+zip" }, bytes_received = 41231 }
rig.rename_ok = false
res = download()
r.check("a rename that fails is reported, not silently swallowed",
        res.success ~= true and res.error ~= nil and was_removed(TEMP),
        "error = " .. tostring(res.error))

r.finish()
