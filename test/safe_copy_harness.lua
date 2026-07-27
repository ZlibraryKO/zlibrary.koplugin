-- Does a failed cover copy still destroy the original?
--
-- It used to. ffiUtil.copyFile reports failure by RETURNING an error string and returns nil on
-- success; it never raises (base/ffi/util.lua). _safeCopy wrapped the call in pcall and read
-- pcall's own success as the copy's success, so a copy that failed -- the target directory
-- vanished, the storage filled up -- still led to util.removeFile(from), and CoverCache:insert
-- reported the cover cached. The reader had deleted the only copy of a file it never stored.
--
-- Drives the real BaseCache:_safeCopy, since which return value means what is the whole question.

local PLUGIN = assert(arg[1], "usage: luajit safe_copy_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

-- _safeCopy is a method, so extract_function (which only knows `local function`) does not
-- apply. Pull the block and give it a table to hang off, as first_run_login_harness does.
local body = support.extract_block(PLUGIN .. "/zlibrary/cache.lua",
    "(\nfunction BaseCache:_safeCopy%(.-\n)end\n")

-- One rig per scenario: os.rename, ffiUtil.copyFile and util.removeFile are all controllable,
-- and every call is recorded so the test can say exactly what happened to the source file.
local function newRig(opts)
    opts = opts or {}
    local rig = {
        renamed = nil,          -- os.rename's answer
        removed = {},           -- paths handed to util.removeFile
        copy_calls = 0,         -- how often the copy fallback ran
        warnings = 0,
    }

    local env = {
        tostring = tostring,
        pcall = pcall,
        os = { rename = function(from, to)
            rig.renamed = { from = from, to = to }
            return opts.rename_ok or nil
        end },
        ffiUtil = { copyFile = function(from, to)
            rig.copy_calls = rig.copy_calls + 1
            if opts.copy_raises then error("simulated copy crash") end
            return opts.copy_result -- nil on success, an error string on failure
        end },
        util = { removeFile = function(path)
            table.insert(rig.removed, path)
            return true
        end },
        logger = { warn = function() rig.warnings = rig.warnings + 1 end },
    }

    local chunk = assert(loadstring("local BaseCache = {}\n" .. body .. "end\nreturn BaseCache",
                                    "=_safeCopy"))
    setfenv(chunk, env)
    rig.cache = chunk()
    return rig
end

local FROM = "/cache/zlibrary/covers/abc123.jpg.downloading"
local TO = "/cache/zlibrary/covers/abc123.jpg"

-- ---------------------------------------------------------------- the copy fails
-- copyFile returning an error string is its failure signal, not a Lua error.
do
    local rig = newRig({ rename_ok = false, copy_result = "No space left on device" })
    local ok = rig.cache:_safeCopy(FROM, TO)

    r.check("a failed copy makes _safeCopy report failure", ok == false,
            "returned " .. tostring(ok))
    r.check("a failed copy leaves the source file alone", #rig.removed == 0,
            "removed " .. table.concat(rig.removed, ", "))
    r.check("a failed copy is logged", rig.warnings == 1,
            "warned " .. rig.warnings .. " times")
end

-- A copy that genuinely raises must be treated the same: the source stays put.
do
    local rig = newRig({ rename_ok = false, copy_raises = true })
    local ok = rig.cache:_safeCopy(FROM, TO)

    r.check("a raising copy makes _safeCopy report failure", ok == false,
            "returned " .. tostring(ok))
    r.check("a raising copy leaves the source file alone", #rig.removed == 0,
            "removed " .. table.concat(rig.removed, ", "))
end

-- ---------------------------------------------------------------- the copy works
-- copyFile's success signal is a nil return.
do
    local rig = newRig({ rename_ok = false, copy_result = nil })
    local ok = rig.cache:_safeCopy(FROM, TO)

    r.check("a successful copy makes _safeCopy report success", ok == true,
            "returned " .. tostring(ok))
    r.check("a successful copy removes exactly the source file",
            #rig.removed == 1 and rig.removed[1] == FROM,
            "removed " .. table.concat(rig.removed, ", "))
end

-- ---------------------------------------------------------------- the rename works
-- The common path: a rename inside one filesystem never touches copyFile at all.
do
    local rig = newRig({ rename_ok = true })
    local ok = rig.cache:_safeCopy(FROM, TO)

    r.check("a successful rename makes _safeCopy report success", ok == true,
            "returned " .. tostring(ok))
    r.check("a successful rename never calls the copy fallback", rig.copy_calls == 0,
            "copyFile ran " .. rig.copy_calls .. " times")
    r.check("a successful rename removes nothing itself", #rig.removed == 0,
            "removed " .. table.concat(rig.removed, ", "))
end

r.finish()
