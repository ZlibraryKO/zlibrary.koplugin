-- The cover cache used to sit at <data>/cache/zlibrary/covers, and on Android that is inside
-- SHARED storage: Android indexed every cover as media, and a reader's whole search history
-- appeared as a wall of book covers in the phone's file manager. Whatever they had been reading
-- was on display to anyone who picked the phone up.
--
-- The directory is hidden now (a leading dot: skipped by MediaStore, hidden by default in every
-- mainstream Android file manager) with a .nomedia inside it as well. What this harness is really
-- for is the other half -- that an install which ALREADY has the visible directory ends up with
-- nothing left in it. Redirecting new writes while leaving the old files in place would fix the
-- problem for nobody who has it.
--
-- usage: luajit cache_hidden_dir_harness.lua <plugin-root> <luasocket-src>

local PLUGIN = assert(arg[1], "usage: luajit cache_hidden_dir_harness.lua <plugin-root> <luasocket-src>")
package.path = PLUGIN .. "/test/?.lua;" .. package.path
local support = require("support")
local r = support.reporter()

local LEGACY = "/data/cache/zlibrary"
local HIDDEN = "/data/cache/.zlibrary"

-- A filesystem as a flat path -> "file"|"directory" table. lfs.dir hands back an iterator AND a
-- directory object, and the iterator here REFUSES a nil state, so a caller that drops the second
-- return value fails loudly instead of silently listing nothing.
local function newFs(nodes)
    local fs = { nodes = {}, links = {}, removed = {}, rmdirs = {}, written = {}, rename = nil }
    for path, kind in pairs(nodes or {}) do fs.nodes[path] = kind end

    local function children(dir)
        local out, prefix = {}, dir .. "/"
        for path in pairs(fs.nodes) do
            local rest = path:sub(#prefix + 1)
            if path:sub(1, #prefix) == prefix and rest ~= "" and not rest:find("/") then
                out[#out + 1] = rest
            end
        end
        table.sort(out)
        return out
    end

    fs.lfs = {
        attributes = function(path, what)
            assert(what == "mode", "harness only models the mode attribute")
            return fs.nodes[path]
        end,
        symlinkattributes = function(path, what)
            assert(what == "mode", "harness only models the mode attribute")
            if fs.links[path] then return "link" end
            return fs.nodes[path]
        end,
        dir = function(path)
            local state = { names = children(path), i = 0 }
            table.insert(state.names, 1, "..")
            table.insert(state.names, 1, ".")
            return function(s)
                assert(s ~= nil, "lfs.dir's iterator was called without its directory object")
                s.i = s.i + 1
                return s.names[s.i]
            end, state
        end,
        rmdir = function(path)
            if fs.nodes[path] ~= "directory" then return nil end
            fs.rmdirs[#fs.rmdirs + 1] = path
            fs.nodes[path] = nil
            return true
        end,
    }
    fs.os = {
        remove = function(path)
            if fs.nodes[path] == nil then return nil end
            fs.removed[#fs.removed + 1] = path
            fs.nodes[path] = nil
            return true
        end,
        rename = function(from, to)
            if fs.rename == false then return nil end
            fs.renamed = { from = from, to = to }
            local moved = {}
            for path, kind in pairs(fs.nodes) do
                if path == from or path:sub(1, #from + 1) == from .. "/" then
                    moved[to .. path:sub(#from + 1)] = kind
                    fs.nodes[path] = nil
                end
            end
            for path, kind in pairs(moved) do fs.nodes[path] = kind end
            return true
        end,
    }
    function fs:leftUnder(dir)
        local n = 0
        for path in pairs(self.nodes) do
            if path == dir or path:sub(1, #dir + 1) == dir .. "/" then n = n + 1 end
        end
        return n
    end
    return fs
end

local function populated()
    return newFs({
        ["/data/cache/zlibrary"] = "directory",
        ["/data/cache/zlibrary/covers"] = "directory",
        ["/data/cache/zlibrary/covers/242ff1.jpg"] = "file",
        ["/data/cache/zlibrary/covers/4ab742.jpg"] = "file",
        ["/data/cache/zlibrary/bookinfos"] = "directory",
        ["/data/cache/zlibrary/bookinfos/242ff1_info.lua"] = "file",
        ["/data/cache/zlibrary/_domains_cache.lua"] = "file",
    })
end

local SRC = PLUGIN .. "/zlibrary/cache.lua"
local function migrator(fs)
    local removeTree = support.extract_function(SRC, "_removeCacheTree", {
        lfs = fs.lfs, os = fs.os, pcall = pcall,
    })
    return support.extract_function(SRC, "_migrateLegacyCacheDir", {
        lfs = fs.lfs, os = fs.os,
        logger = { info = function() end, warn = function() end },
        LEGACY_CACHE_DIR = LEGACY, BASE_CACHE_DIR = HIDDEN,
        _removeCacheTree = removeTree,
    }), removeTree
end

-- ---------------------------------------------------------------- the path itself
local function slurp(p) local fh = assert(io.open(p)); local s = fh:read("*a"); fh:close(); return s end
local src = slurp(SRC)
r.check("the cache directory is hidden",
        src:find('BASE_CACHE_DIR = DataStorage:getDataDir%(%) %.%. "/cache/%.zlibrary"') ~= nil,
        "BASE_CACHE_DIR is not the dot directory")

-- ---------------------------------------------------------------- the clean move
local fs = populated()
local migrate = migrator(fs)
r.check("an existing cache is moved, not deleted", migrate() == "moved", "wrong outcome")
r.check("it lands in the hidden directory",
        fs.nodes["/data/cache/.zlibrary/covers/242ff1.jpg"] == "file",
        "cover missing after the move")
r.check("and nothing is left at the visible path", fs:leftUnder(LEGACY) == 0,
        fs:leftUnder(LEGACY) .. " entries still under " .. LEGACY)
r.check("a move deletes nothing", #fs.removed == 0, table.concat(fs.removed, ", "))

-- ---------------------------------------------------------------- nothing to do
fs = newFs({ ["/data/cache/.zlibrary"] = "directory" })
migrate = migrator(fs)
r.check("no legacy directory is not an error", migrate() == "none", "wrong outcome")
r.check("and nothing is touched", fs.renamed == nil and #fs.removed == 0, "something moved")

-- ---------------------------------------------------------------- when the move cannot happen
-- The point of the whole change is that the old directory ends up empty. A cache is replaceable;
-- what was reported is not.
for _, case in ipairs({
    { name = "the rename fails", setup = function(f) f.rename = false end },
    { name = "the hidden directory already exists",
      setup = function(f) f.nodes["/data/cache/.zlibrary"] = "directory" end },
}) do
    fs = populated()
    case.setup(fs)
    migrate = migrator(fs)
    r.check(case.name .. ": falls back to removing it", migrate() == "removed", "wrong outcome")
    r.check(case.name .. ": leaves nothing at the visible path", fs:leftUnder(LEGACY) == 0,
            fs:leftUnder(LEGACY) .. " entries still under " .. LEGACY)
end

-- ---------------------------------------------------------------- the rails on a delete
fs = populated()
fs.nodes["/data/cache/zlibrary/covers/elsewhere"] = "directory"
fs.links["/data/cache/zlibrary/covers/elsewhere"] = true
fs.nodes["/data/cache/zlibrary/covers/elsewhere/precious.jpg"] = "file"
local _, removeTree = migrator(fs)
removeTree(LEGACY, 0)
r.check("a symlinked directory is unlinked, not descended into",
        fs.nodes["/data/cache/zlibrary/covers/elsewhere/precious.jpg"] == "file",
        "followed a link out of the cache and deleted what was there")

fs = populated()
_, removeTree = migrator(fs)
r.check("the depth limit refuses rather than recursing forever",
        removeTree(LEGACY, 3) == false, "descended past the limit")

-- ---------------------------------------------------------------- .nomedia
local function nomediaRig(existing)
    local fs2 = newFs(existing)
    local made = {}
    local ensureNoMedia = support.extract_function(SRC, "_ensureNoMedia", {
        _nomedia_checked = {},
        util = { fileExists = function(p) return fs2.nodes[p] == "file" end },
        io = { open = function(p) made[#made + 1] = p return { close = function() end } end },
    })
    return ensureNoMedia, made, fs2
end

local ensureNoMedia, made = nomediaRig({})
ensureNoMedia("/data/cache/.zlibrary/covers")
r.check("a .nomedia is written into the cache directory",
        made[1] == "/data/cache/.zlibrary/covers/.nomedia", table.concat(made, ", "))

ensureNoMedia("/data/cache/.zlibrary/covers")
r.check("and is not rewritten on every cache write", #made == 1, #made .. " writes")

ensureNoMedia, made = nomediaRig({ ["/data/cache/.zlibrary/covers/.nomedia"] = "file" })
ensureNoMedia("/data/cache/.zlibrary/covers")
r.check("an existing marker is left alone", #made == 0, table.concat(made, ", "))

-- The upgrade case: the directories are already there, so a marker written only at creation time
-- would never reach the installs that need it.
local ensured = {}
local ensurePath = loadstring(
    support.extract_block(SRC, "(\nfunction BaseCache:_ensurePath%(dir%).-\n)end\n")
    .. "end\nreturn BaseCache._ensurePath")
setfenv(ensurePath, {
    util = { directoryExists = function() return true end, makePath = function() end },
    ffiUtil = { execute = function() end },
    _ensureNoMedia = function(d) ensured[#ensured + 1] = d end,
    BASE_CACHE_DIR = HIDDEN,
    BaseCache = {},
})
ensurePath()({}, "/data/cache/.zlibrary/covers")
r.check("an already-created directory still gets its marker checked",
        ensured[1] == "/data/cache/.zlibrary/covers", table.concat(ensured, ", "))

r.finish()
