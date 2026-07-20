-- Getting a book onto the device.
--
-- Lifted out of main.lua unchanged: 308 lines across three functions, of which downloadBook
-- alone was 244 -- the largest thing left in that file after discovery moved out.
--
-- The parameters really are named `self`, which is why the bodies below are byte-for-byte what
-- they were. The plugin methods they call -- login, resetDownloadQuotaCache, and each other --
-- resolve on the instance exactly as before, so a move that changes no line changes no
-- behaviour. main.lua keeps two one-line methods delegating here, because bookdetails_dialog
-- calls downloadBook on the plugin instance and the retry paths recurse through it.

local Api = require("zlibrary.api")
local AsyncHelper = require("zlibrary.async_helper")
local Config = require("zlibrary.config")
local Device = require("device")
local NetworkMgr = require("ui/network/manager")
local ReaderUI = require("apps/reader/readerui")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local Ui = require("zlibrary.ui")
local T = require("zlibrary.gettext")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local Download = {}

local function _usableFormat(format)
    if type(format) ~= "string" then
        return nil
    end
    local trimmed = util.trim(format)
    if trimmed == "" or trimmed == "N/A" then
        return nil
    end
    -- Accept only what looks like an extension rather than stripping what does not. Stripping
    -- turns "a/b" into "ab" -- safe to write, but an invented type that opens in nothing --
    -- whereas refusing it sends the caller to fetch the real one. Letters and digits only, and
    -- short: every format this plugin handles is epub, pdf, mobi, azw3, djvu or fb2.
    if not trimmed:match("^%w+$") or #trimmed > 8 then
        return nil
    end
    return trimmed
end

function Download.fetchDetailsThenDownload(self, book_stub)
    local function attempt()
        local user_session = Config.getUserSession()
        local loading_msg = Ui.showLoadingMessage(T("Fetching book details..."))

        local task = function()
            return Api.getBookDetails(user_session and user_session.user_id,
                user_session and user_session.user_key, book_stub.id, book_stub.hash)
        end

        local on_success = function(api_result)
            Ui.closeMessage(loading_msg)
            if api_result.error then
                Ui.showErrorMessage(Ui.colonConcat(T("Failed to fetch book details"),
                    tostring(api_result.error)))
                return
            end
            if not api_result.book then
                Ui.showErrorMessage(T("Could not retrieve book details."))
                return
            end
            if not _usableFormat(api_result.book.format) then
                -- Say so rather than inventing an extension: a file saved under the wrong one
                -- opens in nothing.
                Ui.showErrorMessage(T("This book's file type is unknown, so it cannot be downloaded."))
                return
            end
            self:downloadBook(api_result.book)
        end

        local on_error_handler = function(err_msg)
            Ui.showRetryErrorDialog(err_msg, T("Book details"), function()
                attempt()
            end, function() end, loading_msg, "book_details")
        end

        AsyncHelper.run(task, on_success, on_error_handler, loading_msg)
    end

    attempt()
end

function Download.run(self, book)
    if NetworkMgr:willRerunWhenOnline(function()
        self:downloadBook(book)
    end) then
        return
    end

    if not book.id or not book.hash then
        Ui.showErrorMessage(T("Book identifiers missing. Cannot download."))
        return
    end

    -- Downloading straight from a browse list means the extension has not been fetched yet.
    -- Get the details first and come back, which is what opening the book would have done.
    local book_format = _usableFormat(book.format)
    if not book_format then
        self:_fetchDetailsThenDownload(book)
        return
    end

    local safe_title = util.trim(book.title or "Unknown Title"):gsub("[/\\?%*:|\"<>%c]", "_")
    local safe_author = util.trim(book.author or "Unknown Author"):gsub("[/\\?%*:|\"<>%c]", "_")
    local filename = string.format("%s - %s.%s", safe_title, safe_author, book_format)
    logger.info(string.format("Zlibrary:downloadBook - Proposed filename: %s", filename))

    local target_dir = Config.getDownloadDir()

    if not target_dir then
        target_dir = Config.DEFAULT_DOWNLOAD_DIR_FALLBACK
        logger.warn(string.format("Zlibrary:downloadBook - Download directory setting not found, using fallback: %s", target_dir))
    else
        logger.info(string.format("Zlibrary:downloadBook - Using configured download directory: %s", target_dir))
    end

    if lfs.attributes(target_dir, "mode") ~= "directory" then
        local ok, err_mkdir = lfs.mkdir(target_dir)
        if not ok then
            Ui.showErrorMessage(string.format(T("Cannot create downloads directory: %s"), err_mkdir or "Unknown error"))
            return
        end
        logger.info(string.format("Zlibrary:downloadBook - Created downloads directory: %s", target_dir))
    end

    local target_filepath = target_dir .. "/" .. filename
    logger.info(string.format("Zlibrary:downloadBook - Target filepath: %s", target_filepath))

    local attemptDownload

    -- The child owns the socket, so it cannot drive the parent's progress bar. It does not need to:
    -- it is already writing the bytes to a file we know the name of. Watch that instead. Legal only
    -- because the dismissable run yields while it waits, so UIManager is live to run this.
    -- Not via Trapper's pipe: any byte readable there is taken as the child's final result, which
    -- would both corrupt it and re-block the parent until the child exits.
    local function startProgressPoll(target_filepath, progress_callback, progress_max)
        if not progress_callback or not progress_max then return function() end end
        local temp_filepath = Api.getDownloadTempPath(target_filepath)
        local stopped = false
        local poll
        poll = function()
            if stopped then return end
            local size = lfs.attributes(temp_filepath, "size")
            -- nil while the link is still being resolved, and again once the child has renamed the
            -- file onto the target: neither is a reset to zero. Clamp because the reported size is
            -- catalogue metadata and the body can overrun it; setPercentage does not clamp itself.
            if size then progress_callback(math.min(size, progress_max)) end
            UIManager:scheduleIn(1, poll)
        end
        UIManager:scheduleIn(1, poll)
        return function()
            stopped = true
            UIManager:unschedule(poll)
        end
    end

    -- Resolving the link and fetching the body both block for as long as the network takes. Run them in
    -- a forked child so the UI loop keeps running and the user can tap to cancel: the child cannot yield
    -- out of socket.http (it sits behind socket.protect's C frame), but it does not need to -- blocking
    -- is fine over there, and Trapper yields in the parent while it waits.
    local function runDownloadInSubprocess(user_session, referer_url)
        return Trapper:dismissableRunInSubprocess(function()
            -- This process exists only to return a result table, and it shares the cache file with the
            -- parent. Nothing it writes there can help, and some of it would destroy the parent's copy.
            Config.disableRuntimeCacheWrites()

            logger.info(string.format("Zlibrary:downloadBook - Fetching download link from endpoint for book ID: %s", book.id))
            local link_result = Api.getDownloadLink(user_session and user_session.user_id,
                user_session and user_session.user_key, book.id, book.hash)

            if link_result.error then
                return { success = false, error = link_result.error }
            end

            logger.info(string.format("Zlibrary:downloadBook - Got download link from endpoint: %s", link_result.download_link))

            -- No progress callback: it would run in this process and could not reach the parent's
            -- dialog. The parent watches the temp file instead.
            return Api.downloadBook(link_result.download_link, target_filepath,
                user_session and user_session.user_id, user_session and user_session.user_key,
                referer_url, nil)
        end, false) -- false: an invisible trap widget that swallows the dismissing tap
    end

    attemptDownload = function(retry_on_auth_error, progress_title)
        retry_on_auth_error = retry_on_auth_error == nil and true or retry_on_auth_error

        local user_session = Config.getUserSession()
        local referer_url = book.href and Config.getBookUrl(book.href) or nil
        local loading_msg

        -- The wrap below routes any result carrying .error to on_error_download, so api_result never
        -- has one here; on_error_download owns every failure, including the auth retry.
        local function on_success_download(api_result)
            Ui.closeMessage(loading_msg)
            if api_result and api_result.success then

                -- reset download quota cache
                self:resetDownloadQuotaCache()

                local has_wifi_toggle = Device:hasWifiToggle()
                local default_turn_off_wifi = Config.getTurnOffWifiAfterDownload()

                Ui.confirmOpenBook(filename, has_wifi_toggle, default_turn_off_wifi, function(should_turn_off_wifi)
                    if should_turn_off_wifi then
                        NetworkMgr:disableWifi(function()
                            logger.info("Zlibrary:downloadBook - Wi-Fi disabled after download as requested by user")
                        end)
                    end

                    if ReaderUI then
                        logger.info("Zlibrary:downloadBook - Cleaning up dialogs before opening reader")
                        self.dialog_manager:closeAllDialogs()
                        ReaderUI:showReader(target_filepath)
                    else
                        Ui.showErrorMessage(T("Could not open reader UI."))
                        logger.warn("Zlibrary:downloadBook - ReaderUI not available.")
                    end
                end,
                function(should_turn_off_wifi)
                    if should_turn_off_wifi then
                        NetworkMgr:disableWifi(function()
                            logger.info("Zlibrary:downloadBook - Wi-Fi disabled after download as requested by user")
                        end)
                        logger.info("Zlibrary:downloadBook - Cleaning up dialogs cause wifi is turned off")
                        self.dialog_manager:closeAllDialogs()
                    end
                end
            )
            else
                -- Only reachable when the task returned no result at all; a result carrying .error
                -- went to on_error_download instead.
                Ui.showErrorMessage((api_result and api_result.message) or T("Download failed: Unknown error"))
            end
        end

        local function on_error_download(err_msg)
            if retry_on_auth_error and Api.isAuthenticationError(err_msg) then
                Ui.closeMessage(loading_msg)
                self:login(function(login_ok)
                    if login_ok then
                        attemptDownload(false)
                    end
                end)
                return
            end
            
            local error_string = tostring(err_msg)
            if string.find(error_string, "Download limit reached or file is an HTML page", 1, true) then
                Ui.closeMessage(loading_msg)
                Ui.showErrorMessage(T("Download limit reached. Please try again later or check your account."))
                return
            end
            
            -- Use retry dialog for timeout and network errors
            Ui.showRetryErrorDialog(err_msg, T("Book download"), function()
                -- Retry callback. Re-enter attemptDownload so the retry gets its own wrap: this runs
                -- from a fresh event, outside any coroutine, and an unwrapped dismissable run silently
                -- falls back to blocking in-process.
                attemptDownload(retry_on_auth_error, T("Retrying download… (tap to cancel)"))
            end, function(final_err_msg)
                -- Cancel callback - user already knows about the error. Nothing to clean up:
                -- Api.downloadBook discards its own temp file, and this path is also reached when
                -- Api.getDownloadLink failed and no file was ever created.
            end, loading_msg, "download")
        end

        Trapper:wrap(function()
            -- A previous download that was killed never got to clean up after itself.
            Api.discardDownloadTempFile(target_filepath)

            local progress_callback
            loading_msg, progress_callback = Ui.showBookDownloadProgress(book, progress_title)

            -- Trapper polls the child at up to one second, so a cancel can land after the child has
            -- already renamed the finished book into place. Remember what was there first, so that
            -- case is reported as the success it is instead of stranding a complete book.
            local target_before = lfs.attributes(target_filepath, "modification")

            -- Trapper returns false both for "user dismissed" and for "fork failed". A dismiss cannot
            -- happen without at least one yield, and a fork failure never reaches the poll loop, so
            -- this tells the two apart.
            local yielded = false
            UIManager:nextTick(function() yielded = true end)

            local stop_poll = startProgressPoll(target_filepath, progress_callback, book.filesize)
            local ok, completed, api_result = pcall(runDownloadInSubprocess, user_session, referer_url)
            -- After the pcall, so a throw cannot leave the poll rescheduling against a closed dialog.
            stop_poll()

            if not ok then
                logger.err("Zlibrary:downloadBook - Download failed: " .. tostring(completed))
                Ui.closeMessage(loading_msg)
                Ui.showErrorMessage(T("Download failed: Unknown error"))
                return
            end

            if not completed then
                if lfs.attributes(target_filepath, "modification") ~= target_before then
                    -- The rename beat the kill; the book is whole.
                    return on_success_download({ success = true })
                end
                Api.discardDownloadTempFile(target_filepath)
                Ui.closeMessage(loading_msg)
                Ui.showInfoMessage(yielded and T("Download cancelled.")
                    or T("Download failed: Unknown error"))
                return
            end

            if not api_result then
                Ui.closeMessage(loading_msg)
                Ui.showErrorMessage(T("Download failed: Unknown error"))
                return
            end
            if api_result.error then
                return on_error_download(api_result.error)
            end
            on_success_download(api_result)
        end)
    end

    Ui.confirmDownload(filename, function()
        attemptDownload()
    end)
end

return Download
