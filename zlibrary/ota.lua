local logger = require("logger")
local json = require("json")
local T = require("zlibrary.gettext")
local ConfirmBox = require("ui/widget/confirmbox")
local UIManager = require("ui/uimanager")
local util = require("util")
local NetworkMgr = require("ui/network/manager")
local Api = require("zlibrary.api")
local Config = require("zlibrary.config")
local Ui = require("zlibrary.ui")
local DataStorage = require("datastorage")
local AsyncHelper = require("zlibrary.async_helper")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")

local Ota = {}

local GITHUB_REPO = "ZlibraryKO/zlibrary.koplugin"
local LATEST_RELEASE_URL = "https://api.github.com/repos/" .. GITHUB_REPO .. "/releases/latest"

local current_ota_status_widget = nil

local function _close_current_ota_status_widget()
    if current_ota_status_widget then
        Ui.closeMessage(current_ota_status_widget)
        current_ota_status_widget = nil
    end
end

local function _show_ota_status_loading(text)
    _close_current_ota_status_widget()
    current_ota_status_widget = Ui.showLoadingMessage(text)
end

local function _show_ota_final_message(text, is_error)
    _close_current_ota_status_widget()
    if is_error then
        Ui.showErrorMessage(text)
    else
        Ui.showInfoMessage(text)
    end
end

local function getCurrentPluginVersion(plugin_base_path)
    local meta_file_full_path = plugin_base_path .. "_meta.lua"
    logger.info("Zlibrary:Ota.getCurrentPluginVersion - Attempting to load version via dofile from: " .. meta_file_full_path)

    local ok, result = pcall(dofile, meta_file_full_path)

    if not ok then
        logger.err("Zlibrary:Ota.getCurrentPluginVersion - Error executing _meta.lua: " .. tostring(result))
        return nil
    end

    if type(result) == "table" and result.version and type(result.version) == "string" then
        logger.info("Zlibrary:Ota.getCurrentPluginVersion - Found version: " .. result.version)
        return result.version
    else
        local details = "Unknown issue."
        if type(result) ~= "table" then
            details = "_meta.lua did not return a table. Returned type: " .. type(result) .. ", value: " .. tostring(result)
        elseif not result.version then
            details = "_meta.lua returned a table, but the 'version' key is missing."
        elseif type(result.version) ~= "string" then
            details = "_meta.lua returned a table, but 'version' is not a string. Type: " .. type(result.version)
        end
        logger.warn("Zlibrary:Ota.getCurrentPluginVersion - Version not found or invalid in _meta.lua. " .. details)
        return nil
    end
end

-- Exported so the About dialog shows the same version the updater compares against, instead of
-- reading _meta.lua a second way and being able to disagree with it.
Ota.getCurrentPluginVersion = getCurrentPluginVersion

-- The release workflow publishes zlibrary_plugin_v<version>.zip. Pick the update archive out of the
-- release by name: a release can carry more than one asset -- a second archive, a checksum, a
-- signature -- and the API does not promise any particular order, so taking the first one means a
-- future asset could silently redirect the updater at the wrong file. Fall back to any zip, so
-- renaming the artefact cannot strand everyone on an old version with no way to update.
local UPDATE_ASSET_NAME_PATTERN = "^zlibrary_plugin_.*%.zip$"

local function selectUpdateAsset(assets)
    if type(assets) ~= "table" then return nil end

    local first_zip
    for _, asset in ipairs(assets) do
        if type(asset) == "table" and type(asset.name) == "string"
                and type(asset.browser_download_url) == "string" then
            if asset.name:match(UPDATE_ASSET_NAME_PATTERN) then
                return asset
            end
            if not first_zip and asset.name:match("%.zip$") then
                first_zip = asset
            end
        end
    end
    return first_zip
end

local function isVersionOlder(version1, version2)
    if not version1 or not version2 then return false end

    -- `or 0` matters: table.insert(t, nil) is a silent no-op in Lua 5.1, so a non-numeric
    -- component (a hand-built "1.0.41-dev") would leave a hole that reads back as 0 at the
    -- wrong index, shifting every later component and misjudging the comparison.
    local v1_parts = {}
    for part in string.gmatch(version1, "([^%.]+)") do table.insert(v1_parts, tonumber(part) or 0) end
    local v2_parts = {}
    for part in string.gmatch(version2, "([^%.]+)") do table.insert(v2_parts, tonumber(part) or 0) end

    for i = 1, math.max(#v1_parts, #v2_parts) do
        local p1 = v1_parts[i] or 0
        local p2 = v2_parts[i] or 0
        if p1 < p2 then return true end
        if p1 > p2 then return false end
    end
    return false
end

function Ota.fetchLatestReleaseInfo()
    logger.info("Zlibrary:Ota.fetchLatestReleaseInfo - START")
    local result = { release_info = nil, error = nil }

    local http_options = {
        url = LATEST_RELEASE_URL,
        method = "GET",
        headers = {
            ["User-Agent"] = "KOReader-ZLibrary-Plugin",
            ["Accept"] = "application/vnd.github.v3+json",
        },
        timeout = 20,
        redirect = true,
    }

    local http_result = Api.makeHttpRequest(http_options)

    if http_result.error then
        result.error = "Network request failed: " .. http_result.error
        logger.err("Zlibrary:Ota.fetchLatestReleaseInfo - END (HTTP error from Api.makeHttpRequest) - Error: " .. result.error .. ", Status: " .. tostring(http_result.status_code))
        return result
    end

    if http_result.status_code ~= 200 then
        result.error = string.format("HTTP Error: %s. Body: %s", http_result.status_code, http_result.body or "N/A")
        logger.err("Zlibrary:Ota.fetchLatestReleaseInfo - END (HTTP status error) - Error: " .. result.error)
        return result
    end

    if not http_result.body then
        result.error = "No response body from GitHub API."
        logger.err("Zlibrary:Ota.fetchLatestReleaseInfo - END (No body error) - Error: " .. result.error)
        return result
    end

    local success, data = pcall(json.decode, http_result.body)
    if not success or not data then
        result.error = "Failed to decode JSON response: " .. tostring(data)
        logger.err("Zlibrary:Ota.fetchLatestReleaseInfo - END (JSON error) - Error: " .. result.error)
        return result
    end

    logger.info("Zlibrary:Ota.fetchLatestReleaseInfo - END (Success)")
    result.release_info = data
    return result
end

function Ota.downloadUpdate(url, destination_path)
    logger.info(string.format("Zlibrary:Ota.downloadUpdate - START - URL: %s, Dest: %s", url, destination_path))
    -- A bare number is not a budget: it becomes socketutil:set_timeout(300), and that does
    -- `total_timeout or 15`. So `timeout = 300` bought 300 seconds of tolerated SILENCE plus a 15s
    -- total nobody asked for. The pair matches Api.downloadBook: give up after 15s of no data, but
    -- let a healthy transfer take as long as it needs.
    local result = Api.downloadToFile(url, destination_path,
        { ["User-Agent"] = "KOReader-ZLibrary-Plugin" }, Config.getDownloadTimeout())
    if result.success then
        logger.info("Zlibrary:Ota.downloadUpdate - END (Success)")
    end
    return result
end

-- Remove a directory tree without following links out of it: a link is unlinked like a file. Not
-- ffiUtil.purgeDir, which stats with lfs.attributes and so recurses through a link to a
-- directory -- and a plugin directory linked in from a git checkout is how development installs
-- are set up. Returns true when the path is gone.
local function _removeTree(path)
    local mode = lfs.symlinkattributes(path, "mode")
    if mode == nil then return true end
    if mode == "directory" then
        local listed, iter, dir_obj = pcall(lfs.dir, path)
        if listed then
            for entry in iter, dir_obj do
                if entry ~= "." and entry ~= ".." then
                    _removeTree(path .. "/" .. entry)
                end
            end
        end
        return lfs.rmdir(path) and true or false
    end
    return os.remove(path) and true or false
end

-- The archive holds plugins/zlibrary.koplugin/...; these are paths inside it.
local ZIP_PLUGIN_DIR = "plugins/zlibrary.koplugin"
local CREDENTIALS_IN_ZIP = ZIP_PLUGIN_DIR .. "/zlibrary_credentials.lua"

-- Install the downloaded archive in place of the running plugin.
--
-- Extracted beside the live directory first, checked, and only then swapped in with two renames.
-- Unzipping straight over the live directory -- what this used to do -- left a plugin that was
-- part old release and part new if the extraction stopped half way (a full disk, the battery),
-- and it never removed a file a release had dropped, so a deleted module stayed loadable forever.
-- Now the live directory is either the old release, untouched, or the new one, whole.
--
-- The reader's zlibrary_credentials.lua is not in the new tree (the archive's template is left
-- out on extraction, as before) and is carried over from the live one.
function Ota.installUpdate(zip_filepath, plugin_base_path)
    logger.info("Zlibrary:Ota.installUpdate - START - File: " .. zip_filepath .. " Target Path: " .. tostring(plugin_base_path))

    if not plugin_base_path or not util.directoryExists(plugin_base_path) then
        local err_msg = "Invalid or missing plugin base path for installation: " .. tostring(plugin_base_path)
        logger.err("Zlibrary:Ota.installUpdate - " .. err_msg)
        _show_ota_final_message(T("Update failed: Could not determine where to install the plugin."), true)
        return { error = err_msg }
    end

    local live_dir = plugin_base_path:gsub("/+$", "")
    local parent_dir = live_dir:match("^(.*)/[^/]+$")
    if lfs.symlinkattributes(live_dir, "mode") ~= "directory" or not parent_dir then
        -- A link (a development install pointing at a checkout): swapping would replace the
        -- link with a copy and quietly cut the install off from where it points.
        local err_msg = "Plugin directory is a link or has no parent, not updating it: " .. live_dir
        logger.err("Zlibrary:Ota.installUpdate - " .. err_msg)
        _show_ota_final_message(T("Update installation failed."), true)
        return { error = err_msg }
    end

    _show_ota_status_loading(T("Installing update..."))

    -- Hidden names beside the live directory: the same filesystem, so the swap is a rename, and
    -- not *.koplugin, so KOReader never loads either of them as a plugin.
    local staging_dir = parent_dir .. "/.zlibrary_update"
    local backup_dir = parent_dir .. "/.zlibrary_previous"
    local new_dir = staging_dir .. "/" .. ZIP_PLUGIN_DIR
    -- Whatever an earlier attempt left behind.
    _removeTree(staging_dir)
    _removeTree(backup_dir)

    local function fail(detail, user_text)
        logger.err("Zlibrary:Ota.installUpdate - " .. detail)
        _removeTree(staging_dir)
        _show_ota_final_message(user_text or T("Update installation failed."), true)
        return { error = detail }
    end

    if not lfs.mkdir(staging_dir) then
        return fail("Could not create " .. staging_dir)
    end

    local unzip_command = string.format("unzip -o '%s' -d '%s' -x '%s'", zip_filepath, staging_dir, CREDENTIALS_IN_ZIP)
    logger.info("Zlibrary:Ota.installUpdate - Executing: " .. unzip_command)

    -- LuaJIT keeps Lua 5.1's os.execute: it returns the raw system() status as a single number and
    -- nothing else, so the extra return values were always nil and, worse, 0 is truthy in Lua --
    -- `if not ok` could never fire. Compare against 0, as KOReader does at every other call site.
    local exec_status = os.execute(unzip_command)
    if exec_status ~= 0 then
        return fail("Failed to extract update package: unzip status: " .. tostring(exec_status))
    end

    -- unzip's exit status only says the archive was readable. Check that what came out is a
    -- plugin, and a whole one: its entry point, and a _meta.lua that runs and names a version.
    local meta_ok, meta = pcall(dofile, new_dir .. "/_meta.lua")
    if not (meta_ok and type(meta) == "table" and type(meta.version) == "string"
            and util.fileExists(new_dir .. "/main.lua")) then
        return fail("Extracted update package is missing the plugin tree or its _meta.lua is broken.")
    end

    local credentials = live_dir .. "/" .. Config.CREDENTIALS_FILENAME
    if util.fileExists(credentials) then
        local copy_err = ffiUtil.copyFile(credentials, new_dir .. "/" .. Config.CREDENTIALS_FILENAME)
        if copy_err then
            return fail("Could not carry over " .. Config.CREDENTIALS_FILENAME .. ": " .. tostring(copy_err))
        end
    end

    -- The swap. Between the two renames there is no plugin directory at all, so the second one
    -- failing puts the old one straight back.
    local moved_aside, aside_err = os.rename(live_dir, backup_dir)
    if not moved_aside then
        return fail("Could not move the installed plugin aside: " .. tostring(aside_err))
    end
    local moved_in, in_err = os.rename(new_dir, live_dir)
    if not moved_in then
        local restored = os.rename(backup_dir, live_dir)
        logger.err("Zlibrary:Ota.installUpdate - could not move the new release in: " .. tostring(in_err)
            .. (restored and "; the installed plugin was put back" or "; RESTORING THE INSTALLED PLUGIN FAILED, it is at " .. backup_dir))
        return fail("Could not move the new release into place: " .. tostring(in_err))
    end

    _removeTree(backup_dir)
    _removeTree(staging_dir)
    logger.info("Zlibrary:Ota.installUpdate - Installed " .. meta.version)

    local rm_ok, rm_err = os.remove(zip_filepath)
    if not rm_ok then
        logger.warn("Zlibrary:Ota.installUpdate - Could not remove downloaded ZIP file: " .. zip_filepath .. " Error: " .. tostring(rm_err))
    else
        logger.info("Zlibrary:Ota.installUpdate - Cleaned up ZIP file: " .. zip_filepath)
    end

    -- Not _show_ota_final_message: that shows a notice that times out in three seconds, which is
    -- short for an instruction to restart, and it has no room for anything else. The dialog waits
    -- to be dismissed and carries the plugin's one other mention of support -- see
    -- Ui.showUpdateInstalledDialog for why this moment and no other.
    _close_current_ota_status_widget()
    Ui.showUpdateInstalledDialog()
    return { success = true, message = "Update installed successfully." }
end

function Ota.startUpdateProcess(plugin_path_from_main)
    logger.info("Zlibrary:Ota.startUpdateProcess - Initiated by user. Plugin path: " .. tostring(plugin_path_from_main))

    if NetworkMgr:willRerunWhenOnline(function()
        Ota.startUpdateProcess(plugin_path_from_main)
    end) then
        return
    end

    if not plugin_path_from_main then
        logger.err("Zlibrary:Ota.startUpdateProcess - Plugin path not provided.")
        _show_ota_final_message(T("Update check failed: Could not determine plugin location."), true)
        return
    end

    if not string.match(plugin_path_from_main, "plugins/zlibrary.koplugin/?$") then
        local err_msg = string.format(T("Unsupported plugin path for OTA update: %s. Only 'plugins/zlibrary.koplugin' is supported."), plugin_path_from_main)
        logger.err("Zlibrary:Ota.startUpdateProcess - " .. err_msg)
        _show_ota_final_message(err_msg, true)
        return
    end

    -- In a forked child, like every other request, so the reader can tap the check away instead
    -- of waiting out a stalled GitHub with the UI frozen. Only the fields used below come back:
    -- the full release record carries json nulls, which do not survive the pipe.
    _close_current_ota_status_widget()
    current_ota_status_widget = Ui.showCancellableLoadingMessage(T("Checking for updates..."))
    AsyncHelper.runCancellable(function()
        local fetched = Ota.fetchLatestReleaseInfo()
        if fetched.error or type(fetched.release_info) ~= "table" then
            return { error = fetched.error or "release_info is nil" }
        end
        local info = fetched.release_info
        local assets = {}
        if type(info.assets) == "table" then
            for _, a in ipairs(info.assets) do
                if type(a) == "table" then
                    assets[#assets + 1] = {
                        name = type(a.name) == "string" and a.name or nil,
                        browser_download_url = type(a.browser_download_url) == "string" and a.browser_download_url or nil,
                    }
                end
            end
        end
        return { release_info = {
            tag_name = type(info.tag_name) == "string" and info.tag_name or nil,
            assets = assets,
        } }
    end, function(fetched)
        Ota._offerUpdate(plugin_path_from_main, fetched.release_info)
    end, function(err)
        current_ota_status_widget = nil -- runCancellable has closed it
        logger.err("Zlibrary:Ota.startUpdateProcess - Failed to fetch release info: " .. tostring(err))
        _show_ota_final_message(T("Failed to check for updates. Please check your internet connection."), true)
    end, current_ota_status_widget, function()
        current_ota_status_widget = nil
    end)
end

-- The rest of the check, once the release is known: compare versions and ask.
function Ota._offerUpdate(plugin_path_from_main, release_info)
    -- runCancellable closed the checking message itself.
    current_ota_status_widget = nil
    if not release_info or type(release_info) ~= "table" then
        logger.err("Zlibrary:Ota.startUpdateProcess - Invalid release_info structure received.")
        _show_ota_final_message(T("Could not find update information (invalid data format)."), true)
        return
    end

    local latest_version_tag = release_info.tag_name
    local assets = release_info.assets

    if not latest_version_tag or type(latest_version_tag) ~= "string" or #latest_version_tag == 0 then
        logger.warn("Zlibrary:Ota.startUpdateProcess - Invalid or missing latest_version_tag in release information.")
        _show_ota_final_message(T("Could not find update version information."), true)
        return
    end

    local normalized_latest_version = string.match(latest_version_tag, "v?([%d%.]+)")
    if not normalized_latest_version then
        logger.warn("Zlibrary:Ota.startUpdateProcess - Could not normalize latest_version_tag: " .. latest_version_tag)
        _show_ota_final_message(T("Could not understand the update version format."), true)
        return
    end
    logger.info("Zlibrary:Ota.startUpdateProcess - GitHub tag: " .. latest_version_tag .. ", Normalized latest version: " .. normalized_latest_version)

    if not assets or type(assets) ~= "table" or #assets == 0 then
        logger.warn("Zlibrary:Ota.startUpdateProcess - Invalid or missing assets in release information.")
        _show_ota_final_message(T("Could not find update files."), true)
        return
    end

    local asset = selectUpdateAsset(assets)
    if not asset then
        logger.warn("Zlibrary:Ota.startUpdateProcess - No update archive among the release assets.")
        _show_ota_final_message(T("Could not find a download link for the update."), true)
        return
    end

    local download_url = asset.browser_download_url
    -- The asset name is server-controlled and becomes the temp ZIP's filename, which
    -- installUpdate interpolates into a single-quoted os.execute command: a quote would break
    -- out of the quoting, a slash would walk the path out of the cache dir. Keep only
    -- characters that are safe in both a filename and a single-quoted shell word.
    local asset_name = asset.name:gsub("[^%w._%-]", "")
    logger.info("Zlibrary:Ota.startUpdateProcess - Selected release asset: " .. asset_name)

    local current_version = getCurrentPluginVersion(plugin_path_from_main)
    if not current_version then
        logger.warn("Zlibrary:Ota.startUpdateProcess - Could not determine current plugin version. Proceeding with update check, but comparison might be skipped.")
    end

    logger.info(string.format("Zlibrary:Ota.startUpdateProcess - Latest version from GitHub (normalized): %s, Current installed version: %s", normalized_latest_version, current_version or "Unknown"))

    if not isVersionOlder(current_version, normalized_latest_version) then
        local message
        if current_version then
            message = string.format(T("You are already on the latest version (%s) or newer."), current_version)
        else
            message = string.format(T("Could not determine your current version, but the latest is %s. If you recently updated, you might be up-to-date."), normalized_latest_version)
        end
        _show_ota_final_message(message, false)
        logger.info("Zlibrary:Ota.startUpdateProcess - No new update needed. Current: " .. (current_version or "Unknown") .. ", Latest (normalized): " .. normalized_latest_version)
        return
    end

    local confirmation_message = string.format(T([[New version available: %s (you have %s). Download and install?]]),
        normalized_latest_version,
        current_version or T("an older version")
    )

    local confirm_dialog = ConfirmBox:new{
        title = T("Update available"),
        text = confirmation_message,
        ok_text = T("Update"),
        cancel_text = T("Cancel"),
        ok_callback = function()
            local temp_path_base = DataStorage:getDataDir() .. "/cache"
            local temp_zip_path = temp_path_base .. "/" .. asset_name
            logger.info("Zlibrary:Ota.startUpdateProcess - Temporary download path: " .. temp_zip_path)

            local function discardZip()
                if util.fileExists(temp_zip_path) then os.remove(temp_zip_path) end
            end

            -- Forked and cancellable, like the check above: a release archive on a slow
            -- connection takes long enough that a frozen screen reads as a hang.
            _close_current_ota_status_widget()
            current_ota_status_widget = Ui.showCancellableLoadingMessage(T("Downloading update..."))
            AsyncHelper.runCancellable(function()
                return Ota.downloadUpdate(download_url, temp_zip_path)
            end, function()
                current_ota_status_widget = nil
                logger.info("Zlibrary:Ota.startUpdateProcess - Download successful: " .. temp_zip_path)
                local install_result = Ota.installUpdate(temp_zip_path, plugin_path_from_main)
                if install_result.error then
                    logger.err("Zlibrary:Ota.startUpdateProcess - Installation failed: " .. install_result.error)
                    discardZip()
                else
                    logger.info("Zlibrary:Ota.startUpdateProcess - Installation successful.")
                end
            end, function(err)
                current_ota_status_widget = nil
                logger.err("Zlibrary:Ota.startUpdateProcess - Download failed: " .. tostring(err))
                _show_ota_final_message(T("Download failed. Please try again later."), true)
                discardZip()
            end, current_ota_status_widget, function()
                current_ota_status_widget = nil
                discardZip()
            end)
        end,
        cancel_callback = function()
            _close_current_ota_status_widget()
            logger.info("Zlibrary:Ota.startUpdateProcess - User cancelled update.")
        end
    }
    -- Every other exit from the update check goes through _show_ota_final_message, which closes the
    -- status widget for us. This one does not, so "Checking for updates..." would sit behind the
    -- dialog for as long as the user takes to answer -- still claiming to be checking.
    _close_current_ota_status_widget()
    UIManager:show(confirm_dialog)
end

return Ota
