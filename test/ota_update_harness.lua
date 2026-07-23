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
--   * installUpdate trusted unzip's exit status; an archive without the plugin tree still
--     exits 0 after partially overwriting the live plugin directory.
--
-- Drives the real functions out of zlibrary/ota.lua with stubbed KOReader modules.

local PLUGIN = assert(arg[1], "usage: luajit ota_update_harness.lua <plugin-root> <luasocket-src>")

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
local function newDownloadRig(http_result)
    local rig = { events = {} }
    local env = setmetatable({
        logger = { info = function() end, err = function() end, warn = function() end },
        socketutil = { file_sink = function() return function() end end },
        Config = { getDownloadTimeout = function() return 30 end },
        Api = { makeHttpRequest = function() return http_result end },
        io = { open = function()
            return { close = function() table.insert(rig.events, "close") end }
        end },
        os = { remove = function(path)
            table.insert(rig.events, "remove " .. path)
            return true
        end },
    }, { __index = _G })

    local body = support.extract_block(OTA, "(\nfunction Ota%.downloadUpdate%(.-\n)end\n")
    local chunk = assert(loadstring("local Ota = {}\n" .. body .. "end\nreturn Ota", "=downloadUpdate"))
    setfenv(chunk, env)
    rig.Ota = chunk()
    return rig
end

local DEST = "/data/cache/zlibrary_plugin_v1.0.41.zip"

-- A connect-time failure never calls the sink, so the handle is still open when the partial
-- file is deleted. The close has to happen first.
do
    local rig = newDownloadRig({ error = "connection refused" })
    local result = rig.Ota.downloadUpdate("http://example/zip", DEST)

    r.check("a connect-time failure reports an error", result.error ~= nil and not result.success)
    r.check("a connect-time failure closes the handle before removing the file",
            rig.events[1] == "close" and rig.events[2] == "remove " .. DEST and #rig.events == 2,
            table.concat(rig.events, ", "))
end

-- Same on the HTTP-status error path: a 404 page may never terminate the sink either.
do
    local rig = newDownloadRig({ status_code = 404 })
    local result = rig.Ota.downloadUpdate("http://example/zip", DEST)

    r.check("an HTTP error reports an error", result.error ~= nil and not result.success)
    r.check("an HTTP error closes the handle before removing the file",
            rig.events[1] == "close" and rig.events[2] == "remove " .. DEST and #rig.events == 2,
            table.concat(rig.events, ", "))
end

-- A healthy transfer removes nothing and reports success.
do
    local rig = newDownloadRig({ status_code = 200 })
    local result = rig.Ota.downloadUpdate("http://example/zip", DEST)

    r.check("a successful download reports success", result.success == true and result.error == nil)
    r.check("a successful download removes nothing", #rig.events == 0,
            table.concat(rig.events, ", "))
end

-- ---------------------------------------------------------------- installUpdate
local function newInstallRig(opts)
    local rig = { removed = {}, finals = {}, checked_paths = {} }
    local env = setmetatable({
        logger = { info = function() end, err = function() end, warn = function() end },
        T = function(s) return s end,
        DataStorage = { getDataDir = function() return "/data" end },
        util = {
            directoryExists = function() return true end,
            fileExists = function(path)
                table.insert(rig.checked_paths, path)
                return opts.meta_exists or false
            end,
        },
        os = {
            execute = function() return opts.exec_status or 0 end,
            remove = function(path)
                table.insert(rig.removed, path)
                return true
            end,
        },
        _show_ota_status_loading = function() end,
        _show_ota_final_message = function(text, is_error)
            table.insert(rig.finals, { text = text, is_error = is_error })
        end,
    }, { __index = _G })

    local body = support.extract_block(OTA, "(\nfunction Ota%.installUpdate%(.-\n)end\n")
    local chunk = assert(loadstring("local Ota = {}\n" .. body .. "end\nreturn Ota", "=installUpdate"))
    setfenv(chunk, env)
    rig.Ota = chunk()
    return rig
end

local ZIP = "/data/cache/zlibrary_plugin_v1.0.41.zip"
local META = "/data/plugins/zlibrary.koplugin/_meta.lua"

-- unzip failing outright: report the failure, keep the ZIP for the caller to clean up.
do
    local rig = newInstallRig({ exec_status = 256 })
    local result = rig.Ota.installUpdate(ZIP, "/data/plugins/zlibrary.koplugin/")

    r.check("a failed unzip reports an error", result.error ~= nil and not result.success)
    r.check("a failed unzip shows an error message",
            #rig.finals == 1 and rig.finals[1].is_error == true)
    r.check("a failed unzip removes nothing", #rig.removed == 0,
            table.concat(rig.removed, ", "))
end

-- unzip exiting 0 without producing the plugin tree: that is NOT a success -- the live plugin
-- directory may have been partially overwritten by whatever the archive did contain.
do
    local rig = newInstallRig({ exec_status = 0, meta_exists = false })
    local result = rig.Ota.installUpdate(ZIP, "/data/plugins/zlibrary.koplugin/")

    r.check("an archive without the plugin tree reports an error",
            result.error ~= nil and not result.success,
            "returned success")
    r.check("the extracted plugin tree is verified at _meta.lua",
            rig.checked_paths[1] == META, tostring(rig.checked_paths[1]))
    r.check("an archive without the plugin tree shows an error message",
            #rig.finals == 1 and rig.finals[1].is_error == true)
    r.check("an archive without the plugin tree removes nothing", #rig.removed == 0,
            table.concat(rig.removed, ", "))
end

-- A good archive: verified, ZIP cleaned up, success reported.
do
    local rig = newInstallRig({ exec_status = 0, meta_exists = true })
    local result = rig.Ota.installUpdate(ZIP, "/data/plugins/zlibrary.koplugin/")

    r.check("a good archive installs successfully", result.success == true and result.error == nil)
    r.check("a good archive is verified at _meta.lua",
            rig.checked_paths[1] == META, tostring(rig.checked_paths[1]))
    r.check("a good archive cleans up the ZIP",
            #rig.removed == 1 and rig.removed[1] == ZIP, table.concat(rig.removed, ", "))
    r.check("a good archive shows a success message",
            #rig.finals == 1 and rig.finals[1].is_error == false)
end

r.finish()
