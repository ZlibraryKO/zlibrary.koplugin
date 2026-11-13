-- Getting a file onto the device: the download link, the book itself (through a temp file that only
-- replaces the target once complete), and covers. Part of the Api facade; see api_core.lua.

local Config = require("zlibrary.config")
local logger = require("logger")
local json = require("json")
local socketutil = require("socketutil")
local T = require("zlibrary.gettext")
local Api = require("zlibrary.api_core")
local Shared = require("zlibrary.api_shared")
local _sessionCookie = Shared._sessionCookie
local _authedHeaders = Shared._authedHeaders
local _loggableUrl = Shared._loggableUrl

-- A URL with its query removed, for logging. Public because download.lua logs the resolved
-- download link too, and that link's query is its signature; see _loggableUrl in api_shared.
Api.loggableUrl = _loggableUrl

-- The file Api.downloadBook writes into before renaming it onto the target. Exposed so a caller that
-- kills the download -- which skips downloadBook's own cleanup -- can sweep what it left behind, and so
-- a progress watcher can stat it. Keeps the suffix in one place.
function Api.getDownloadTempPath(target_filepath)
    if type(target_filepath) ~= "string" then return nil end
    return target_filepath .. ".downloading"
end

function Api.discardDownloadTempFile(target_filepath)
    local temp_filepath = Api.getDownloadTempPath(target_filepath)
    if temp_filepath then
        pcall(os.remove, temp_filepath)
    end
end

function Api.downloadBook(download_url, target_filepath, user_id, user_key, referer_url, progress_callback)
    logger.info(string.format("Zlibrary:Api.downloadBook - START - URL: %s, Target: %s", _loggableUrl(download_url), target_filepath))

    local result = { success = false, error = nil }

    -- Download into a sibling temp file and rename onto target_filepath only once the whole body has
    -- arrived. Opening target_filepath directly would truncate an existing book before the first byte
    -- is fetched, and every failure below would then delete it -- so a quota-blocked re-download of a
    -- book the user already owns would destroy their copy. CoverCache does the same thing for covers.
    local temp_filepath = Api.getDownloadTempPath(target_filepath)
    local file, err_open = io.open(temp_filepath, "wb")
    if not file then
        result.error = T("Failed to open target file") .. ": " .. (err_open or T("Unknown error"))
        logger.err(string.format("Zlibrary:Api.downloadBook - END (File open error) - Error: %s", result.error))
        return result
    end

    -- The sink closes the handle at end of stream, but not when the request fails before it is ever
    -- called, so close defensively; a double close is harmless here.
    local function discardTempFile()
        pcall(function() file:close() end)
        pcall(os.remove, temp_filepath)
    end

    local headers = { ["User-Agent"] = Config.getUserAgent() }
    headers["Cookie"] = _sessionCookie(user_id, user_key)
    if referer_url then
        headers["Referer"] = referer_url
    end

    local handle = socketutil.file_sink(file)
    if type(progress_callback) == "function" and type(socketutil.chainSinkWithProgressCallback) == "function" then
        handle = socketutil.chainSinkWithProgressCallback(handle, progress_callback)
    end

    local http_result = Api.makeHttpRequest{
        url = download_url,
        method = "GET",
        headers = headers,
        sink = handle,
        timeout = Config.getDownloadTimeout(),
        redirect = true,
    }

    if http_result.error and not (http_result.status_code and http_result.headers) then
        result.error = http_result.error
        discardTempFile()
        logger.err(string.format("Zlibrary:Api.downloadBook - END (Request error) - Error: %s", result.error))
        return result
    end

    local content_type = http_result.headers and http_result.headers["content-type"]
    if content_type and string.find(string.lower(content_type), "text/html") then
        result.error = Api.DOWNLOAD_LIMIT_HTML_TEXT
        discardTempFile()
        logger.warn(string.format("Zlibrary:Api.downloadBook - END (HTML content detected) - URL: %s, Status: %s, Content-Type: %s", _loggableUrl(download_url), tostring(http_result.status_code), content_type))
        return result
    end

    if http_result.error or (http_result.status_code and http_result.status_code ~= 200) then
        result.error = http_result.error or string.format("%s: %s", T("HTTP Error"), http_result.status_code)
        discardTempFile()
        logger.err(string.format("Zlibrary:Api.downloadBook - END (Download error) - Error: %s, Status: %s", result.error, tostring(http_result.status_code)))
        return result
    else
        pcall(function() file:close() end)

        -- A 200 with nothing in it is not a book. These mirrors answer with empty bodies often
        -- enough (the same servers hand out 502s and challenge interstitials), and renaming that
        -- into place would report a successful download, hand the reader a file that opens in
        -- nothing, and -- worst of it -- replace a complete copy of a book they already had.
        if (http_result.bytes_received or 0) == 0 then
            result.error = T("Download failed: the server sent an empty file")
            discardTempFile()
            logger.err(string.format(
                "Zlibrary:Api.downloadBook - END (Empty body) - Status: %s, Content-Type: %s",
                tostring(http_result.status_code), tostring(content_type)))
            return result
        end

        -- Same directory, so this is an atomic replace; the user's copy is only ever replaced by a
        -- complete download.
        local renamed, err_rename = os.rename(temp_filepath, target_filepath)
        if not renamed then
            result.error = T("Failed to save downloaded file") .. ": " .. tostring(err_rename or T("Unknown error"))
            discardTempFile()
            logger.err(string.format("Zlibrary:Api.downloadBook - END (Rename error) - Error: %s", result.error))
            return result
        end
        result.success = true
        logger.info(string.format("Zlibrary:Api.downloadBook - END (Success) - Target: %s", target_filepath))
        return result
    end
end

-- GET a URL straight into a file, for covers and the OTA update archive. Not for books: those go
-- through a temp file and a progress sink, and have the quota answer to read (see downloadBook).
-- Returns { success = true } or { error = ..., status_code = ... }, with status_code only when the
-- server answered: the cover preloader stops retrying a book on 404 and 410. Callers log their own
-- START and success; failures are logged here.
function Api.downloadToFile(download_url, target_filepath, headers, timeout)
    local result = { success = false, error = nil }
    local file, err_open = io.open(target_filepath, "wb")
    if not file then
        result.error = T("Failed to open target file") .. ": " .. (err_open or T("Unknown error"))
        logger.err(string.format("Zlibrary:Api.downloadToFile - END (File open error) - Error: %s", result.error))
        return result
    end

    -- As in downloadBook: the sink closes the handle at end of stream, but not when the request
    -- fails before it is ever called, so close defensively; a double close is harmless here.
    local function discardPartialFile()
        pcall(function() file:close() end)
        pcall(os.remove, target_filepath)
    end

    local http_result = Api.makeHttpRequest{
        url = download_url,
        method = "GET",
        headers = headers,
        sink = socketutil.file_sink(file),
        timeout = timeout,
        redirect = true,
    }

    if http_result.error and not (http_result.status_code and http_result.headers) then
        result.error = http_result.error
        discardPartialFile()
        logger.err(string.format("Zlibrary:Api.downloadToFile - END (Request error) - Error: %s", result.error))
        return result
    end

    if http_result.error then
        result.error = http_result.error
        result.status_code = http_result.status_code
        discardPartialFile()
        logger.err("Zlibrary:Api.downloadToFile - END (HTTP error from Api.makeHttpRequest) - Error: " .. result.error .. ", Status: " .. tostring(http_result.status_code))
        return result
    end

    if http_result.status_code ~= 200 then
        result.error = string.format("%s: %s", T("Download HTTP Error"), http_result.status_code)
        result.status_code = http_result.status_code
        discardPartialFile()
        logger.err("Zlibrary:Api.downloadToFile - END (HTTP status error) - Error: " .. result.error)
        return result
    end

    result.success = true
    return result
end

function Api.downloadBookCover(download_url, target_filepath)
    -- dbg, not info: a page of results fetches dozens of covers, and a START/END pair each buried
    -- everything else in the log. Api.makeHttpRequest already logs its own START at dbg, so this
    -- matches. Failures stay at err, in downloadToFile, and are the part worth seeing.
    logger.dbg(string.format("Zlibrary:Api.downloadBookCover - START - URL: %s, Target: %s", _loggableUrl(download_url), target_filepath))
    local result = Api.downloadToFile(download_url, target_filepath,
        { ["User-Agent"] = Config.getUserAgent() }, Config.getCoverTimeout())
    if result.success then
        logger.dbg("Zlibrary:Api.downloadBookCover - END (Success)")
    end
    return result
end

function Api.getDownloadLink(user_id, user_key, book_id, book_hash)
    local url = Config.getDownloadLinkUrl(book_id, book_hash)
    if not url then
        logger.warn("Api.getDownloadLink - URL could not be constructed. Base URL configured? Book ID/Hash provided?")
        return { error = T("Z-library server URL not configured or book identifiers missing.") }
    end

    local headers = _authedHeaders(user_id, user_key)

    local http_result = Api.makeHttpRequest{
        url = url,
        method = "GET",
        headers = headers,
        timeout = Config.getBookDetailsTimeout(),
        retry_on_stall = true,
        onRedirect = function()
            return Config.getDownloadLinkUrl(book_id, book_hash)
        end,
    }

    if http_result.error then
        logger.warn("Api.getDownloadLink - HTTP request error: ", http_result.error)
        return { error = http_result.error }
    end

    if not http_result.body then
        logger.warn("Api.getDownloadLink - No response body")
        return { error = T("Failed to fetch download link (no response body).") }
    end

    local success, data = pcall(json.decode, http_result.body, json.decode.simple)
    if not success or not data then
        logger.warn("Api.getDownloadLink - Failed to decode JSON: ", http_result.body)
        return { error = T("Failed to parse download link response.") }
    end

    if data.success ~= 1 or not data.file then
        logger.warn("Api.getDownloadLink - API error: ", http_result.body)
        return { error = data.message or T("API returned an error for download link.") }
    end

    local file_data = data.file
    local download_link = file_data.downloadLink

    if not download_link then
        -- The endpoint answers 200 with success=1 and the file record, but no link, when the account
        -- may not download right now -- an exhausted daily quota being the usual reason. Its own
        -- disallowDownloadMessage explains why and names the reset time, but it is HTML and only ever
        -- English, so it stays in the log and the user gets the translated message instead.
        logger.warn("Api.getDownloadLink - No download link in response: ", http_result.body)
        if file_data.allowDownload == false then
            return { error = T("Download limit reached. Please try again later or check your account.") }
        end
        return { error = T("No download link provided in API response.") }
    end

    return {
        download_link = download_link,
        description = file_data.description,
        author = file_data.author,
        extension = file_data.extension,
        allow_download = file_data.allowDownload,
    }
end

return Api
