-- OTA update safety: version comparison, asset-name sanitization, download cleanup, and
-- post-install verification.
--
-- Four defects lived here:
--
--   * isVersionOlder did table.insert(parts, tonumber(part)); a non-numeric component (a
--     hand-built "1.0.41-dev") inserted nil, and table.insert(t, nil) is a silent no-op in
--     Lua 5.1, leaving a hole: every component after it shifted DOWN an index and compared
--     against the wrong counterpart. The fix coerces to 0 in place instead.
--   * The server-controlled asset name became the temp ZIP filename and was interpolated into
--     a single-quoted os.execute unzip command: a quote broke out of the quoting, a slash
--     walked out of the cache dir.
--   * downloadUpdate only closed its file handle via the sink's terminating chunk; a
--     connect-time failure never called the sink, so os.remove ran on a still-open file.
--     The download now goes through Api.downloadToFile, shared with covers, and that is
--     checked in file_download_harness; this one checks only what downloadUpdate asks it for.
--   * installUpdate trusted unzip's exit status; an archive without the plugin tree still
--     exits 0 after partially overwriting the live plugin directory.
--
-- And then the install itself was replaced: it unzipped straight over the live plugin, so a
-- stopped extraction left a plugin half one release and half the next, and a file a release had
-- dropped stayed behind forever. It now extracts beside the live directory, checks what came out,
-- and swaps it in. That part runs the real installUpdate against real archives (built with zip)
-- in a temporary directory, since what is being checked is what ends up on disk.
--
-- Last, the check and the download run in a cancellable child (AsyncHelper.runCancellable) rather
-- than blocking the UI; the flow through startUpdateProcess is driven with that stubbed.
--
-- Drives the real functions out of zlibrary/ota.lua with stubbed KOReader modules.

local PLUGIN = assert(arg[1], "usage: luajit ota_update_harness.lua <plugin-root> <luasocket-src> <koreader-dir>")
local KOREADER = assert(arg[3], "usage: luajit ota_update_harness.lua <plugin-root> <luasocket-src> <koreader-dir>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local OTA = PLUGIN .. "/zlibrary/ota.lua"

-- ---------------------------------------------------------------- isVersionOlder
do
    local isVersionOlder = support.extract_function(OTA, "isVersionOlder", {
        string = string, table = table, math = math, tonumber = tonumber,
    })

    r.check("1.0.40 is older than 1.0.41", isVersionOlder("1.0.40", "1.0.41") == true)
    r.check("1.0.41 is not older than itself", isVersionOlder("1.0.41", "1.0.41") == false)
    r.check("1.0.42 is not older than 1.0.41", isVersionOlder("1.0.42", "1.0.41") == false)
    r.check("2.0 is not older than 1.9.9", isVersionOlder("2.0", "1.9.9") == false)
    -- A non-numeric component counts as 0 at its own index: "41-dev" becomes 0, so a dev
    -- build of 1.0.41 sorts as 1.0.0 -- older than any 1.0.x release.
    r.check("a dev-suffixed component counts as 0 in place",
            isVersionOlder("1.0.41-dev", "1.0.40") == true)
    -- Without `or 0` the nil insert is a no-op, leaving {1, 2}: the "2" shifts down an index
    -- and beats the 0 of "1.0.9", so a version with a dev suffix looked NEWER than a higher
    -- release. With the fix the components stay put: {1, 0, 2} against {1, 0, 9}.
    r.check("components after a dev suffix do not shift down",
            isVersionOlder("1.5-dev.2", "1.0.9") == true,
            "non-numeric component left a hole in the parts table")
    r.check("a missing version never compares older", isVersionOlder(nil, "1.0.41") == false
            and isVersionOlder("1.0.40", nil) == false)
end

-- ---------------------------------------------------------------- asset name sanitization
-- The exact line from startUpdateProcess, run against hostile release-asset names.
local sanitize_line = support.extract_block(OTA, "(\n    local asset_name = [^\n]*)")
local function sanitize_asset_name(name)
    local chunk = assert(loadstring(string.format(
        "local asset = { name = %q }\n%s\nreturn asset_name", name, sanitize_line), "=asset_name"))
    return chunk()
end

do
    r.check("a normal release name passes through untouched",
            sanitize_asset_name("zlibrary_plugin_v1.0.41.zip") == "zlibrary_plugin_v1.0.41.zip",
            sanitize_asset_name("zlibrary_plugin_v1.0.41.zip"))

    local hostile = sanitize_asset_name("x'; rm -rf /;'.zip")
    r.check("a quote-bearing name keeps no quote", not hostile:find("'", 1, true), hostile)
    r.check("a quote-bearing name keeps no shell metacharacters",
            hostile:match("^[%w._%-]+$") ~= nil, hostile)

    local traversal = sanitize_asset_name("../../../../etc/passwd")
    r.check("a traversal name keeps no slash", not traversal:find("/", 1, true), traversal)
end

-- ---------------------------------------------------------------- downloadUpdate
do
    local calls = {}
    local answer = { success = false, error = "Download HTTP Error: 404", status_code = 404 }
    local env = setmetatable({
        logger = { info = function() end, err = function() end, warn = function() end },
        Config = { getDownloadTimeout = function() return { 15, -1 } end },
        Api = { downloadToFile = function(...)
            table.insert(calls, { ... })
            return answer
        end },
    }, { __index = _G })

    local body = support.extract_block(OTA, "(\nfunction Ota%.downloadUpdate%(.-\n)end\n")
    local chunk = assert(loadstring("local Ota = {}\n" .. body .. "end\nreturn Ota", "=downloadUpdate"))
    setfenv(chunk, env)
    local Ota = chunk()

    local DEST = "/data/cache/zlibrary_plugin_v1.0.41.zip"
    local result = Ota.downloadUpdate("http://example/zip", DEST)
    local call = calls[1] or {}

    r.check("downloadUpdate downloads once, into the destination",
            #calls == 1 and call[1] == "http://example/zip" and call[2] == DEST)
    r.check("downloadUpdate sends a User-Agent GitHub accepts",
            type(call[3]) == "table" and call[3]["User-Agent"] == "KOReader-ZLibrary-Plugin")
    r.check("downloadUpdate uses the download timeout",
            type(call[4]) == "table" and call[4][1] == 15 and call[4][2] == -1)
    r.check("downloadUpdate returns the download's result", result == answer)
end

-- ---------------------------------------------------------------- installUpdate, on disk
package.cpath = KOREADER .. "/?.so;" .. package.cpath
local lfs = require("libs/libkoreader-lfs")
assert(os.execute("command -v zip >/dev/null && command -v unzip >/dev/null") == 0,
    "this harness needs zip and unzip on PATH")

local function sh(cmd) assert(os.execute(cmd) == 0, "command failed: " .. cmd) end
local function q(p) return "'" .. p .. "'" end
local function write(path, text)
    local f = assert(io.open(path, "wb")); f:write(text); f:close()
end
local function read(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local t = f:read("*a"); f:close(); return t
end
local function exists(path) return lfs.symlinkattributes(path, "mode") ~= nil end

local ROOT = os.tmpname()
os.remove(ROOT)
sh("mkdir -p " .. q(ROOT))

-- An archive shaped like the release's: plugins/zlibrary.koplugin/..., template credentials included.
local function build_zip(name, files)
    local src = ROOT .. "/zipsrc_" .. name
    sh("rm -rf " .. q(src))
    for rel, text in pairs(files) do
        local path = src .. "/" .. rel
        sh("mkdir -p " .. q(path:match("^(.*)/")))
        write(path, text)
    end
    local zip = ROOT .. "/" .. name .. ".zip"
    os.remove(zip)
    sh("cd " .. q(src) .. " && zip -qr " .. q(zip) .. " .")
    return zip
end

local P = "plugins/zlibrary.koplugin/"
local GOOD = {
    [P .. "_meta.lua"] = 'return { version = "1.0.2" }',
    [P .. "main.lua"] = "-- new main",
    [P .. "zlibrary/new_part.lua"] = "-- added in 1.0.2",
    [P .. "zlibrary_credentials.lua"] = "TEMPLATE",
}

-- A fresh data dir with 1.0.1 installed, and the reader's own credentials file in it.
local function install_old(opts)
    opts = opts or {}
    local data = ROOT .. "/data"
    sh("rm -rf " .. q(data))
    local live = data .. "/plugins/zlibrary.koplugin"
    local real_dir = opts.as_link and (ROOT .. "/checkout") or live
    sh("rm -rf " .. q(ROOT .. "/checkout"))
    sh("mkdir -p " .. q(real_dir .. "/zlibrary") .. " " .. q(data .. "/plugins"))
    write(real_dir .. "/_meta.lua", 'return { version = "1.0.1" }')
    write(real_dir .. "/main.lua", "-- old main")
    write(real_dir .. "/zlibrary/dropped_part.lua", "-- removed in 1.0.2")
    if opts.credentials ~= false then write(real_dir .. "/zlibrary_credentials.lua", "MINE") end
    if opts.as_link then sh("ln -s " .. q(real_dir) .. " " .. q(live)) end
    return data, live
end

local function newInstall(opts)
    opts = opts or {}
    local rig = { finals = {}, installed_dialogs = 0, renames = 0 }
    local wrapped_os = setmetatable({
        rename = function(from, to)
            rig.renames = rig.renames + 1
            if opts.fail_rename_to and to == opts.fail_rename_to and not rig.failed_once then
                rig.failed_once = true -- once: the restore that follows must still work
                return nil, "simulated rename failure"
            end
            return os.rename(from, to)
        end,
    }, { __index = os })
    local env = setmetatable({
        logger = { info = function() end, err = function() end, warn = function() end },
        T = function(s) return s end,
        lfs = lfs,
        os = wrapped_os,
        Config = { CREDENTIALS_FILENAME = "zlibrary_credentials.lua" },
        util = {
            directoryExists = function(p) return lfs.attributes(p, "mode") == "directory" end,
            fileExists = function(p) return lfs.attributes(p, "mode") == "file" end,
        },
        ffiUtil = { copyFile = function(from, to)
            local text = read(from)
            if not text then return "cannot read " .. from end
            local ok, err = pcall(write, to, text)
            if not ok then return err end
        end },
        _show_ota_status_loading = function() end,
        _show_ota_final_message = function(text, is_error)
            table.insert(rig.finals, { text = text, is_error = is_error })
        end,
        _close_current_ota_status_widget = function() end,
        Ui = { showUpdateInstalledDialog = function() rig.installed_dialogs = rig.installed_dialogs + 1 end },
    }, { __index = _G })
    local body = support.extract_block(OTA,
        "(\nlocal function _removeTree%(.-\nfunction Ota%.installUpdate%(.-\nend\n)")
    local chunk = assert(loadstring("local Ota = {}\n" .. body .. "return Ota", "=installUpdate"))
    setfenv(chunk, env)
    rig.Ota = chunk()
    return rig
end

local function untouched(live, label)
    r.check(label .. ": the installed release is untouched",
            read(live .. "/_meta.lua") == 'return { version = "1.0.1" }'
                and read(live .. "/zlibrary/dropped_part.lua") ~= nil
                and read(live .. "/zlibrary_credentials.lua") == "MINE",
            tostring(read(live .. "/_meta.lua")))
end
local function no_leftovers(data, label)
    r.check(label .. ": no staging or backup directory is left behind",
            not exists(data .. "/plugins/.zlibrary_update") and not exists(data .. "/plugins/.zlibrary_previous"))
end

-- A good archive.
do
    local zip = build_zip("good", GOOD)
    local data, live = install_old()
    local rig = newInstall()
    local result = rig.Ota.installUpdate(zip, live .. "/")
    r.check("good archive: installs", result.success == true and result.error == nil, tostring(result.error))
    r.check("good archive: the new release is live",
            read(live .. "/_meta.lua") == GOOD[P .. "_meta.lua"] and read(live .. "/zlibrary/new_part.lua") ~= nil)
    r.check("good archive: a file the release dropped is gone", not exists(live .. "/zlibrary/dropped_part.lua"))
    r.check("good archive: the reader's credentials file is carried over, not the template",
            read(live .. "/zlibrary_credentials.lua") == "MINE", tostring(read(live .. "/zlibrary_credentials.lua")))
    no_leftovers(data, "good archive")
    r.check("good archive: the ZIP is cleaned up", not exists(zip))
    r.check("good archive: the update-installed dialog is raised, and no error",
            rig.installed_dialogs == 1 and #rig.finals == 0)
end

-- A reader with no credentials file does not get the template.
do
    local zip = build_zip("good2", GOOD)
    local data, live = install_old({ credentials = false })
    local result = newInstall().Ota.installUpdate(zip, live)
    r.check("no credentials file: still none afterwards",
            result.success == true and not exists(live .. "/zlibrary_credentials.lua"))
end

-- Archives that must not replace anything.
local BAD = {
    { "no plugin tree", function() return build_zip("notree", { ["README.md"] = "x" }) end },
    { "a broken _meta.lua", function()
        local files = {}; for k, v in pairs(GOOD) do files[k] = v end
        files[P .. "_meta.lua"] = "return {{{"
        return build_zip("badmeta", files)
    end },
    { "no main.lua", function()
        local files = {}; for k, v in pairs(GOOD) do files[k] = v end
        files[P .. "main.lua"] = nil
        return build_zip("nomain", files)
    end },
    { "not a zip at all", function()
        local zip = ROOT .. "/garbage.zip"; write(zip, "this is not an archive"); return zip
    end },
    { "a truncated download", function()
        local good = read(build_zip("full", GOOD))
        local zip = ROOT .. "/truncated.zip"; write(zip, good:sub(1, math.floor(#good / 2))); return zip
    end },
}
for _, case in ipairs(BAD) do
    local label = case[1]
    local zip = case[2]()
    local data, live = install_old()
    local rig = newInstall()
    local result = rig.Ota.installUpdate(zip, live .. "/")
    r.check(label .. ": reports an error", result.error ~= nil and not result.success)
    r.check(label .. ": shows an error message", #rig.finals == 1 and rig.finals[1].is_error == true)
    untouched(live, label)
    no_leftovers(data, label)
    r.check(label .. ": leaves the ZIP for the caller", exists(zip))
end

-- An earlier attempt that died between steps.
do
    local zip = build_zip("good3", GOOD)
    local data, live = install_old()
    sh("mkdir -p " .. q(data .. "/plugins/.zlibrary_update/plugins/zlibrary.koplugin") .. " "
        .. q(data .. "/plugins/.zlibrary_previous/zlibrary"))
    write(data .. "/plugins/.zlibrary_update/plugins/zlibrary.koplugin/stale.lua", "stale")
    local result = newInstall().Ota.installUpdate(zip, live .. "/")
    r.check("leftovers from an earlier attempt: still installs cleanly",
            result.success == true and not exists(live .. "/stale.lua"), tostring(result.error))
    no_leftovers(data, "leftovers from an earlier attempt")
end

-- The second rename of the swap failing puts the installed release back.
do
    local zip = build_zip("good4", GOOD)
    local data, live = install_old()
    local rig = newInstall({ fail_rename_to = live })
    local result = rig.Ota.installUpdate(zip, live .. "/")
    r.check("swap fails half way: reports an error", result.error ~= nil and not result.success)
    untouched(live, "swap fails half way")
    no_leftovers(data, "swap fails half way")
end

-- A plugin directory that is a link to a checkout is not swapped, and the checkout survives.
do
    local zip = build_zip("good5", GOOD)
    local data, live = install_old({ as_link = true })
    local rig = newInstall()
    local result = rig.Ota.installUpdate(zip, live .. "/")
    r.check("linked install: refused", result.error ~= nil and rig.renames == 0)
    r.check("linked install: still the same link", lfs.symlinkattributes(live, "mode") == "link")
    r.check("linked install: the checkout behind it is untouched",
            read(ROOT .. "/checkout/_meta.lua") == 'return { version = "1.0.1" }'
                and read(ROOT .. "/checkout/zlibrary/dropped_part.lua") ~= nil)
end

-- _removeTree never follows a link out of the tree it removes.
do
    sh("rm -rf " .. q(ROOT .. "/tree") .. " " .. q(ROOT .. "/outside"))
    sh("mkdir -p " .. q(ROOT .. "/tree/sub") .. " " .. q(ROOT .. "/outside"))
    write(ROOT .. "/outside/keep.txt", "keep")
    sh("ln -s " .. q(ROOT .. "/outside") .. " " .. q(ROOT .. "/tree/sub/link"))
    local env = setmetatable({ lfs = lfs }, { __index = _G })
    local block = support.extract_block(OTA, "(\nlocal function _removeTree%(.-\nend\n)")
    local chunk = assert(loadstring(block .. "return _removeTree", "=_removeTree"))
    setfenv(chunk, env)
    local removeTree = chunk()
    r.check("_removeTree removes the tree", removeTree(ROOT .. "/tree") == true and not exists(ROOT .. "/tree"))
    r.check("but not what a link inside it points at", read(ROOT .. "/outside/keep.txt") == "keep")
end

sh("rm -rf " .. q(ROOT))

-- ---------------------------------------------------------------- the flow, off the UI thread
-- startUpdateProcess with the network, the dialogs and the child stubbed: what goes into each
-- runCancellable, what comes back out, and what happens on success, failure and cancel.
local function newFlow(opts)
    local rig = { runs = {}, finals = {}, shown = {}, installs = {}, removed = {}, loading = {} }
    local env = setmetatable({
        logger = { info = function() end, err = function() end, warn = function() end },
        T = function(s) return s end,
        NetworkMgr = { willRerunWhenOnline = function() return false end },
        DataStorage = { getDataDir = function() return "/data" end },
        util = { fileExists = function() return true end },
        os = setmetatable({ remove = function(p) table.insert(rig.removed, p) return true end }, { __index = os }),
        Ui = { showCancellableLoadingMessage = function(text)
            local w = { text = text }; table.insert(rig.loading, w); return w
        end },
        UIManager = { show = function(_, w) table.insert(rig.shown, w) end },
        ConfirmBox = { new = function(_, spec) return spec end },
        AsyncHelper = { runCancellable = function(task, on_success, on_error, loading, on_cancel)
            table.insert(rig.runs, { task = task, on_success = on_success, on_error = on_error,
                                     loading = loading, on_cancel = on_cancel })
        end },
        selectUpdateAsset = support.extract_function(OTA, "selectUpdateAsset", {
            type = type, ipairs = ipairs,
            -- The file-level constant it matches against, taken from the source as written.
            UPDATE_ASSET_NAME_PATTERN = assert(loadstring("return " .. support.extract_block(OTA,
                "\nlocal UPDATE_ASSET_NAME_PATTERN = (\"[^\n]-\")\n")))(),
        }),
        isVersionOlder = support.extract_function(OTA, "isVersionOlder", {
            string = string, table = table, math = math, tonumber = tonumber }),
        getCurrentPluginVersion = function() return "1.0.1" end,
        _show_ota_final_message = function(text, is_error)
            table.insert(rig.finals, { text = text, is_error = is_error })
        end,
        _close_current_ota_status_widget = function() end,
    }, { __index = _G })
    local body = support.extract_block(OTA, "(\nfunction Ota%.startUpdateProcess%(.-\n)return Ota")
    local chunk = assert(loadstring("local Ota = {}\n" .. body .. "return Ota", "=startUpdateProcess"))
    setfenv(chunk, env)
    rig.Ota = chunk()
    rig.Ota.installUpdate = function(zip, path)
        table.insert(rig.installs, { zip = zip, path = path })
        return opts and opts.install_result or { success = true }
    end
    return rig
end

-- json null decodes to a function sentinel without json.decode.simple, and a function cannot
-- cross the pipe. The release record GitHub returns has plenty of nulls.
local NULL = function() end
local RELEASE = {
    tag_name = "v1.0.2", body = NULL, author = { name = NULL },
    assets = {
        { name = "zlibrary_plugin_v1.0.2.zip", label = NULL,
          browser_download_url = "https://github.example/zlibrary_plugin_v1.0.2.zip" },
    },
}
local function has_function(v, seen)
    seen = seen or {}
    if type(v) == "function" then return true end
    if type(v) ~= "table" or seen[v] then return false end
    seen[v] = true
    for k, x in pairs(v) do if has_function(k, seen) or has_function(x, seen) then return true end end
    return false
end

do
    local rig = newFlow()
    rig.Ota.fetchLatestReleaseInfo = function() return { release_info = RELEASE } end
    rig.Ota.startUpdateProcess("/data/plugins/zlibrary.koplugin/")
    r.check("the check runs through runCancellable, with a cancellable message",
            #rig.runs == 1 and rig.runs[1].loading == rig.loading[1]
                and rig.loading[1].text == "Checking for updates...")
    local fetched = rig.runs[1].task()
    r.check("what the check's child returns can cross the pipe (no json nulls)",
            not has_function(fetched), "a function in the result")
    r.check("and keeps what the offer needs",
            fetched.release_info.tag_name == "v1.0.2"
                and fetched.release_info.assets[1].browser_download_url == RELEASE.assets[1].browser_download_url)

    rig.runs[1].on_success(fetched)
    local dialog = rig.shown[1]
    r.check("a newer release is offered", dialog and dialog.title == "Update available")

    dialog.ok_callback()
    local dl = rig.runs[2]
    r.check("the download runs through runCancellable too",
            dl ~= nil and rig.loading[2] and rig.loading[2].text == "Downloading update..."
                and dl.loading == rig.loading[2])
    local downloaded_to
    rig.Ota.downloadUpdate = function(url, dest) downloaded_to = dest; return { success = true } end
    dl.task()
    r.check("into the cache, under the sanitised asset name",
            downloaded_to == "/data/cache/zlibrary_plugin_v1.0.2.zip", tostring(downloaded_to))
    dl.on_success({ success = true })
    r.check("a finished download is installed",
            #rig.installs == 1 and rig.installs[1].zip == downloaded_to
                and rig.installs[1].path == "/data/plugins/zlibrary.koplugin/")
end

do
    local rig = newFlow()
    rig.Ota.startUpdateProcess("/data/plugins/zlibrary.koplugin/")
    rig.runs[1].on_success({ release_info = { tag_name = "v1.0.2", assets = RELEASE.assets } })
    rig.shown[1].ok_callback()
    rig.runs[2].on_cancel()
    r.check("a cancelled download removes the partial ZIP and installs nothing",
            #rig.installs == 0 and rig.removed[1] == "/data/cache/zlibrary_plugin_v1.0.2.zip",
            tostring(rig.removed[1]))

    local rig2 = newFlow()
    rig2.Ota.startUpdateProcess("/data/plugins/zlibrary.koplugin/")
    rig2.runs[1].on_success({ release_info = { tag_name = "v1.0.2", assets = RELEASE.assets } })
    rig2.shown[1].ok_callback()
    rig2.runs[2].on_error("Request timed out")
    r.check("a failed download says so, removes the ZIP and installs nothing",
            #rig2.installs == 0 and #rig2.removed == 1 and rig2.finals[1] and rig2.finals[1].is_error)
end

do
    local rig = newFlow()
    rig.Ota.fetchLatestReleaseInfo = function() return { error = "Request timed out" } end
    rig.Ota.startUpdateProcess("/data/plugins/zlibrary.koplugin/")
    local fetched = rig.runs[1].task()
    r.check("a failed check comes back as .error, for runCancellable's on_error", fetched.error == "Request timed out")
    rig.runs[1].on_error(fetched.error)
    r.check("and is reported, with nothing offered",
            #rig.finals == 1 and rig.finals[1].is_error and #rig.shown == 0)
end

do
    local rig = newFlow()
    rig.Ota.startUpdateProcess("/data/plugins/zlibrary.koplugin/")
    rig.runs[1].on_success({ release_info = { tag_name = "v1.0.1", assets = RELEASE.assets } })
    r.check("the same version is not offered",
            #rig.shown == 0 and #rig.finals == 1 and rig.finals[1].is_error == false)
end

r.finish()
