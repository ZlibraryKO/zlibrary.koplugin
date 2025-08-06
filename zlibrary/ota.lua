local logger = require("logger")
local ltn12 = require("ltn12")
local json = require("json")
local T = require("zlibrary.gettext")
local ConfirmBox = require("ui/widget/confirmbox")
local UIManager = require("ui/uimanager")
local util = require("util")
local NetworkMgr = require("ui/network/manager")
local Api = require("zlibrary.api")
local Ui = require("zlibrary.ui")
local DataStorage = require("datastorage")

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

local function isVersionOlder(version1, version2)
    if not version1 or not version2 then return false end

    local v1_parts = {}
    for part in string.gmatch(version1, "([^%.]+)") do table.insert(v1_parts, tonumber(part)) end
    local v2_parts = {}
    for part in string.gmatch(version2, "([^%.]+)") do table.insert(v2_parts, tonumber(part)) end

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
    local result = { success = false, error = nil }

    local file, err_open = io.open(destination_path, "wb")
    if not file then
        result.error = "Failed to open target file for download: " .. (err_open or "Unknown error")
        logger.err("Zlibrary:Ota.downloadUpdate - END (File open error) - " .. result.error)
        return result
    end

    local sink = ltn12.sink.file(file)
    local http_options = {
        url = url,
        method = "GET",
        headers = { ["User-Agent"] = "KOReader-ZLibrary-Plugin" },
        sink = sink,
        timeout = 300,
    }

    local http_result = Api.makeHttpRequest(http_options)

    if http_result.error then
        result.error = "Download network request failed: " .. http_result.error
        pcall(os.remove, destination_path)
        logger.err("Zlibrary:Ota.downloadUpdate - END (HTTP error from Api.makeHttpRequest) - Error: " .. result.error .. ", Status: " .. tostring(http_result.status_code))
        return result
    end

    if http_result.status_code ~= 200 then
        result.error = string.format("Download HTTP Error: %s", http_result.status_code)
        pcall(os.remove, destination_path)
        logger.err("Zlibrary:Ota.downloadUpdate - END (HTTP status error) - Error: " .. result.error)
        return result
    end

    logger.info("Zlibrary:Ota.downloadUpdate - END (Success)")
    result.success = true
    return result
end

function Ota.installUpdate(zip_filepath, plugin_base_path)
    logger.info("Zlibrary:Ota.installUpdate - START - File: " .. zip_filepath .. " Target Path: " .. plugin_base_path)

    if not plugin_base_path or not util.directoryExists(plugin_base_path) then
        local err_msg = "Invalid or missing plugin base path for installation: " .. tostring(plugin_base_path)
        logger.err("Zlibrary:Ota.installUpdate - " .. err_msg)
        _show_ota_final_message(T("Update failed: Could not determine where to install the plugin."), true)
        return { error = err_msg }
    end

    _show_ota_status_loading(T("Installing update..."))

    local target_unzip_dir = DataStorage:getDataDir()
    local excluded_file_path_in_zip = "plugins/zlibrary.koplugin/zlibrary_credentials.lua"

    local unzip_command = string.format("unzip -o '%s' -d '%s' -x '%s'", zip_filepath, target_unzip_dir, excluded_file_path_in_zip)
    logger.info("Zlibrary:Ota.installUpdate - Executing: " .. unzip_command)

    local ok, err_code, err_msg_os = os.execute(unzip_command)

    if not ok then
        local error_detail = "Unknown error"
        if type(err_code) == "number" then
            error_detail = "Exit code: " .. err_code
        elseif type(err_msg_os) == "string" then
            error_detail = err_msg_os
        end
        logger.err("Zlibrary:Ota.installUpdate - Failed to extract ZIP: " .. error_detail .. " Command: " .. unzip_command)
        _show_ota_final_message(T("Update installation failed."), true)
        return { error = "Failed to extract update package: " .. error_detail }
    end

    logger.info("Zlibrary:Ota.installUpdate - ZIP extracted successfully.")

    local rm_ok, rm_err = os.remove(zip_filepath)
    if not rm_ok then
        logger.warn("Zlibrary:Ota.installUpdate - Could not remove downloaded ZIP file: " .. zip_filepath .. " Error: " .. tostring(rm_err))
    else
        logger.info("Zlibrary:Ota.installUpdate - Cleaned up ZIP file: " .. zip_filepath)
    end

    _show_ota_final_message(T([[Update installed successfully. Please restart KOReader for changes to take effect.]]), false)
    return { success = true, message = "Update installed successfully." }
end

function Ota.startUpdateProcess(plugin_path_from_main)
    logger.info("Zlibrary:Ota.startUpdateProcess - Initiated by user. Plugin path: " .. tostring(plugin_path_from_main))

    if not NetworkMgr:isOnline() then
        logger.warn("Zlibrary:Ota.startUpdateProcess - No internet connection.")
        _show_ota_final_message(T("No internet connection detected. Please connect to the internet and try again."), true)
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

    _show_ota_status_loading(T("Checking for updates..."))

    local fetch_result = Ota.fetchLatestReleaseInfo()

    if fetch_result.error or not fetch_result.release_info then
        logger.err("Zlibrary:Ota.startUpdateProcess - Failed to fetch release info: " .. (fetch_result.error or "Unknown error - release_info is nil"))
        _show_ota_final_message(T("Failed to check for updates. Please check your internet connection."), true)
        return
    end

    local release_info = fetch_result.release_info
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

    if not assets[1] or type(assets[1]) ~= "table" or not assets[1].browser_download_url then
        logger.warn("Zlibrary:Ota.startUpdateProcess - No download URL found in the first release asset.")
        _show_ota_final_message(T("Could not find a download link for the update."), true)
        return
    end

    local download_url = assets[1].browser_download_url
    local asset_name = assets[1].name or "zlibrary_plugin_update.zip"

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
            _show_ota_status_loading(T("Downloading update..."))
            local temp_path_base = DataStorage:getDataDir() .. "/cache"
            local temp_zip_path = temp_path_base .. "/" .. asset_name

            logger.info("Zlibrary:Ota.startUpdateProcess - Temporary download path: " .. temp_zip_path)

            local download_result = Ota.downloadUpdate(download_url, temp_zip_path)

            if download_result.error or not download_result.success then
                logger.err("Zlibrary:Ota.startUpdateProcess - Download failed: " .. (download_result.error or "Unknown error"))
                _show_ota_final_message(T("Download failed. Please try again later."), true)
                if util.fileExists(temp_zip_path) then
                    os.remove(temp_zip_path)
                end
                return
            end

            logger.info("Zlibrary:Ota.startUpdateProcess - Download successful: " .. temp_zip_path)
            local install_result = Ota.installUpdate(temp_zip_path, plugin_path_from_main)

            if install_result.error then
                logger.err("Zlibrary:Ota.startUpdateProcess - Installation failed: " .. install_result.error)
            else
                logger.info("Zlibrary:Ota.startUpdateProcess - Installation successful.")
            end

            if util.fileExists(temp_zip_path) and (install_result.error or not install_result.success) then
                local rm_ok, rm_err = os.remove(temp_zip_path)
                if not rm_ok then
                    logger.warn("Zlibrary:Ota.startUpdateProcess - Could not remove temp ZIP after failed/partial install: " .. temp_zip_path .. " Error: " .. tostring(rm_err))
                end
            end
        end,
        cancel_callback = function()
            _close_current_ota_status_widget()
            logger.info("Zlibrary:Ota.startUpdateProcess - User cancelled update.")
        end
    }
    UIManager:show(confirm_dialog)
end

return Ota
