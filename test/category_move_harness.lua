-- Filing a finished download into a category folder: does the book survive every way it can go
-- wrong, and does it never overwrite another book?
--
-- Three small functions in download.lua do the work, and each has a way to lose or clobber a file
-- if it is written carelessly:
--
--   * _categoryDestDir turns a chosen target into a folder under the download dir. A name that
--     sanitises away to nothing must yield nil (keep the book where it is), not "<dir>/".
--   * _uniqueDestPath must never return a path that already exists, or the move overwrites a book
--     the user already had. The maintainer asked for "keep both" -- (2), (3), ...
--   * _safeMove must report failure honestly. os.rename cannot cross filesystems, so it falls back
--     to copy-then-remove; if the copy fails it must NOT remove the source (that is the safe_copy
--     bug, here in a second place), and if it raises it must still be treated as a failure.
--
-- Drives the real functions extracted from download.lua, since the whole point is which value means
-- what.

local PLUGIN = assert(arg[1], "usage: luajit category_move_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local function extract(name, env)
    return support.extract_function(PLUGIN .. "/zlibrary/download.lua", name, env)
end

-- The sanitiser _categoryDestDir leans on. The same rule as Config.sanitizeCategoryName, whose own
-- correctness categories_harness pins; here it only has to behave so the join can be checked.
local function sanitize(name)
    if type(name) ~= "string" then return "" end
    return (name:gsub("^%s*(.-)%s*$", "%1"):gsub("[/\\?%*:|\"<>%c]", "_"))
end

-- ---------------------------------------------------------------- _categoryDestDir
do
    local destDir = extract("_categoryDestDir", { Config = { sanitizeCategoryName = sanitize } })

    r.check("no target -> nil, so the book stays in the download folder",
            destDir("/dl", nil) == nil, "got " .. tostring(destDir("/dl", nil)))
    r.check("a top-level category -> <download>/<name>",
            destDir("/dl", { name = "Fiction" }) == "/dl/Fiction",
            "got " .. tostring(destDir("/dl", { name = "Fiction" })))
    r.check("a sub-category -> <download>/<name>/<sub>",
            destDir("/dl", { name = "Fiction", sub = "Romance" }) == "/dl/Fiction/Romance",
            "got " .. tostring(destDir("/dl", { name = "Fiction", sub = "Romance" })))
    r.check("names are sanitised into the path (no traversal, no illegal chars)",
            destDir("/dl", { name = "Sci/Fi", sub = "A:B" }) == "/dl/Sci_Fi/A_B",
            "got " .. tostring(destDir("/dl", { name = "Sci/Fi", sub = "A:B" })))
    r.check("a name that sanitises to nothing -> nil (not \"<dir>/\")",
            destDir("/dl", { name = "   " }) == nil,
            "got " .. tostring(destDir("/dl", { name = "   " })))
    r.check("a sub that sanitises to nothing falls back to the parent folder",
            destDir("/dl", { name = "Fiction", sub = "   " }) == "/dl/Fiction",
            "got " .. tostring(destDir("/dl", { name = "Fiction", sub = "   " })))
end

-- ---------------------------------------------------------------- _uniqueDestPath
do
    -- existing[path] = true marks a file already on disk. Reassigned per case; the closure below
    -- reads the variable, so a fresh table takes effect without rebuilding the function.
    local existing = {}
    local env = {
        string = string,
        util = {
            fileExists = function(p) return existing[p] == true end,
            -- Mirror util.splitFileNameSuffix: split at the LAST dot; no dot -> whole name, "".
            splitFileNameSuffix = function(file)
                if file == nil or file == "" then return "", "" end
                if file:find("%.") == nil then return file, "" end
                return file:match("(.*)%.(.*)")
            end,
        },
    }
    local uniq = extract("_uniqueDestPath", env)

    existing = {}
    r.check("no clash -> the plain path",
            uniq("/dl/Fiction", "Dune - Herbert.epub") == "/dl/Fiction/Dune - Herbert.epub",
            "got " .. tostring(uniq("/dl/Fiction", "Dune - Herbert.epub")))

    existing = { ["/dl/Fiction/Dune - Herbert.epub"] = true }
    r.check("a clash appends (2) before the extension",
            uniq("/dl/Fiction", "Dune - Herbert.epub") == "/dl/Fiction/Dune - Herbert (2).epub",
            "got " .. tostring(uniq("/dl/Fiction", "Dune - Herbert.epub")))

    existing = {
        ["/dl/Fiction/Dune - Herbert.epub"] = true,
        ["/dl/Fiction/Dune - Herbert (2).epub"] = true,
    }
    r.check("successive clashes count up to (3)",
            uniq("/dl/Fiction", "Dune - Herbert.epub") == "/dl/Fiction/Dune - Herbert (3).epub",
            "got " .. tostring(uniq("/dl/Fiction", "Dune - Herbert.epub")))

    existing = { ["/dl/x/README"] = true }
    r.check("an extensionless name gets the suffix at the end",
            uniq("/dl/x", "README") == "/dl/x/README (2)",
            "got " .. tostring(uniq("/dl/x", "README")))
end

-- ---------------------------------------------------------------- _safeMove
local FROM = "/dl/Dune - Herbert.epub.downloading"
local TO = "/dl/Fiction/Dune - Herbert.epub"

local function newMoveRig(opts)
    opts = opts or {}
    local rig = { renamed = nil, removed = {}, copy_calls = 0, warnings = 0 }
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
    rig.move = extract("_safeMove", env)
    return rig
end

-- The common path: a rename inside one filesystem never touches copyFile.
do
    local rig = newMoveRig({ rename_ok = true })
    local ok = rig.move(FROM, TO)
    r.check("a successful rename reports success", ok == true, "returned " .. tostring(ok))
    r.check("a successful rename never calls the copy fallback", rig.copy_calls == 0,
            "copyFile ran " .. rig.copy_calls .. " times")
    r.check("a successful rename removes nothing itself", #rig.removed == 0,
            "removed " .. table.concat(rig.removed, ", "))
end

-- A category folder on another mount: rename fails, copy succeeds, source is removed.
do
    local rig = newMoveRig({ rename_ok = false, copy_result = nil })
    local ok = rig.move(FROM, TO)
    r.check("a cross-filesystem move falls back to copy", ok == true and rig.copy_calls == 1,
            "returned " .. tostring(ok) .. ", copied " .. rig.copy_calls .. " times")
    r.check("the source is removed only after a successful copy",
            #rig.removed == 1 and rig.removed[1] == FROM,
            "removed " .. table.concat(rig.removed, ", "))
end

-- The dangerous case: rename fails AND copy fails. The source must survive.
do
    local rig = newMoveRig({ rename_ok = false, copy_result = "No space left on device" })
    local ok = rig.move(FROM, TO)
    r.check("a failed copy reports failure", ok == false, "returned " .. tostring(ok))
    r.check("a failed copy leaves the source file alone", #rig.removed == 0,
            "removed " .. table.concat(rig.removed, ", "))
    r.check("a failed copy is logged", rig.warnings == 1, "warned " .. rig.warnings .. " times")
end

-- A copy that raises must be treated the same as one that returns an error: source stays put.
do
    local rig = newMoveRig({ rename_ok = false, copy_raises = true })
    local ok = rig.move(FROM, TO)
    r.check("a raising copy reports failure", ok == false, "returned " .. tostring(ok))
    r.check("a raising copy leaves the source file alone", #rig.removed == 0,
            "removed " .. table.concat(rig.removed, ", "))
end

r.finish()
