-- Getting a book onto the device.
--
-- Extracted from main.lua in 7e5f3c3: 308 lines across three functions, of which downloadBook
-- alone was 244 -- the largest thing left in that file after discovery moved out. At that
-- commit the move was byte-for-byte: the parameters really are named `self`, and the plugin
-- methods they call -- login, resetDownloadQuotaCache, and each other -- resolve on the
-- instance exactly as before, so a move that changes no line changes no behaviour. It no
-- longer is: 1b3bd89 added the Config.hasCredentials gate and the login resume to
-- Download.run, and later edits have landed since. Diff against history, not this header.
--
-- main.lua keeps two one-line methods delegating here, because bookdetails_dialog calls
-- downloadBook on the plugin instance and the retry paths recurse through it.

local Api = require("zlibrary.api")
local AsyncHelper = require("zlibrary.async_helper")
local Config = require("zlibrary.config")
local Device = require("device")
local ffiUtil = require("ffi/util")
local NetworkMgr = require("ui/network/manager")
local ReaderUI = require("apps/reader/readerui")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local Ui = require("zlibrary.ui")
local T = require("zlibrary.gettext")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local socket_url = require("socket.url")
local util = require("util")

local Download = {}

-- scheme://host[:port]/path of a url, without the query: a resolved download link carries its
-- signature in the query, which is credential-equivalent and must not land in crash.log.
local function _loggableUrl(url)
    local parsed = socket_url.parse(url or "")
    if not (parsed and parsed.scheme and parsed.host) then
        return "<unparsable>"
    end
    return socket_url.build({
        scheme = parsed.scheme,
        host = parsed.host,
        port = parsed.port,
        path = parsed.path,
    })
end

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

-- Filing a finished download into a category folder --------------------------------------------
-- A category is only a name; its folder is <download dir>/<name>, and a sub-category nests one
-- level deeper. Names double as folder segments, so they are sanitised again here (they already
-- were at storage) as defence against a hand-edited settings file. Everything below is written so
-- that any failure -- an uncreatable folder, a move that does not go through -- leaves the book in
-- the download folder: the book is never lost to a filing attempt.

-- The folder a chosen target maps to, relative to the download directory. nil when there is no
-- target (the book stays in download_dir) or the name sanitises away to nothing.
local function _categoryDestDir(download_dir, target)
    if not target then return nil end
    local name = Config.sanitizeCategoryName(target.name)
    if name == "" then return nil end
    local dir = download_dir .. "/" .. name
    if target.sub then
        local sub = Config.sanitizeCategoryName(target.sub)
        if sub ~= "" then
            dir = dir .. "/" .. sub
        end
    end
    return dir
end

-- A path in dir for filename that does not clash: "Book.epub", then "Book (2).epub",
-- "Book (3).epub"... Filing keeps both copies rather than overwriting an existing book.
local function _uniqueDestPath(dir, filename)
    local candidate = dir .. "/" .. filename
    if not util.fileExists(candidate) then return candidate end
    local base, ext = util.splitFileNameSuffix(filename)
    local n = 2
    while true do
        local name = ext ~= "" and string.format("%s (%d).%s", base, n, ext)
                               or string.format("%s (%d)", base, n)
        candidate = dir .. "/" .. name
        if not util.fileExists(candidate) then return candidate end
        n = n + 1
    end
end

-- Move a downloaded file, tolerating a category folder that turns out to be on another mount:
-- os.rename cannot cross filesystems, so fall back to copy-then-remove -- the shape
-- BaseCache:_safeCopy uses. Returns true only when the file ends up at `to`.
local function _safeMove(from, to)
    if os.rename(from, to) then return true end
    -- ffiUtil.copyFile returns an error string on failure and nil on success, and never raises;
    -- wrap it in pcall anyway so an unexpected error still counts as a failed move rather than
    -- propagating out and skipping the "book kept in the download folder" fallback.
    local copy_ok, copy_err = pcall(ffiUtil.copyFile, from, to)
    if copy_ok and copy_err == nil then
        util.removeFile(from)
        return true
    end
    logger.warn("Zlibrary:downloadBook - failed to move " .. tostring(from) .. " -> " .. tostring(to))
    return false
end

-- After a download the FileManager, if the reader is sitting in it, does not notice the new (or
-- moved) file on its own -- so a book saved into the folder on screen only appears after a manual
-- refresh, which reads as a failed download. Refresh the current folder for them. Deferred to the
-- next tick so it runs once the download dialog has closed and the FileManager is the view on
-- screen; guarded because FileManager.instance is nil whenever a book is open, in which case there
-- is nothing to refresh and KOReader re-reads the folder on its own when the reader is closed. The
-- require is lazy: FileManager pulls in much of the app and is only needed at this instant.
local function _refreshFileManagerListing()
    UIManager:nextTick(function()
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance then
            FileManager.instance:onRefresh()
            UIManager:setDirty(FileManager.instance, "ui")
        end
    end)
end

function Download.fetchDetailsThenDownload(self, book_stub)
    local function attempt()
        local user_session = Config.getUserSession()
        local loading_msg = Ui.showCancellableLoadingMessage(T("Fetching book details..."))

        local task = function()
            return Api.getBookDetails(user_session and user_session.user_id,
                user_session and user_session.user_key, book_stub.id, book_stub.hash)
        end

        local on_success = function(api_result)
            Ui.closeMessage(loading_msg)
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

        AsyncHelper.runCancellable(task, on_success, on_error_handler, loading_msg)
    end

    attempt()
end

function Download.run(self, book)
    -- A download always needs an account -- it counts against a quota. Ask before the radio and
    -- before the request, rather than after the server rejects it: searching works signed out,
    -- so this is the first point where a fresh install actually needs credentials.
    if not Config.hasCredentials() then
        self:login(function(login_ok)
            if login_ok then self:downloadBook(book) end
        end)
        return
    end

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

            logger.info(string.format("Zlibrary:downloadBook - Got download link from endpoint: %s", _loggableUrl(link_result.download_link)))

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

                -- Move the finished book into the category the user picked in the dialog, returning
                -- the path it ends up at. On no choice, or any failure, this is target_filepath --
                -- so whatever we hand to the reader below is always a file that exists.
                local function fileInto(target)
                    if not target then return target_filepath end
                    local label = target.sub and (target.name .. " › " .. target.sub) or target.name
                    local dest_dir = _categoryDestDir(target_dir, target)
                    if not dest_dir then return target_filepath end
                    if not util.directoryExists(dest_dir) then
                        util.makePath(dest_dir)
                    end
                    if not util.directoryExists(dest_dir) then
                        Ui.showInfoMessage(string.format(
                            T("Couldn't create the folder for \"%s\". The book is in the download folder."), label))
                        return target_filepath
                    end
                    local dest = _uniqueDestPath(dest_dir, filename)
                    if _safeMove(target_filepath, dest) then
                        Ui.showInfoMessage(string.format(T("Moved to \"%s\"."), label))
                        return dest
                    end
                    Ui.showInfoMessage(string.format(
                        T("Couldn't move the book into \"%s\". It's in the download folder."), label))
                    return target_filepath
                end

                Ui.confirmOpenBook(filename, has_wifi_toggle, default_turn_off_wifi, function(should_turn_off_wifi, chosen_target)
                    if should_turn_off_wifi then
                        NetworkMgr:disableWifi(function()
                            logger.info("Zlibrary:downloadBook - Wi-Fi disabled after download as requested by user")
                        end)
                    end

                    local final_filepath = fileInto(chosen_target)

                    if ReaderUI then
                        logger.info("Zlibrary:downloadBook - Cleaning up dialogs before opening reader")
                        self.dialog_manager:closeAllDialogs()
                        ReaderUI:showReader(final_filepath)
                    else
                        Ui.showErrorMessage(T("Could not open reader UI."))
                        logger.warn("Zlibrary:downloadBook - ReaderUI not available.")
                    end
                end,
                function(should_turn_off_wifi, chosen_target)
                    -- "Close" still files the book: where it goes is independent of opening it now.
                    fileInto(chosen_target)
                    if should_turn_off_wifi then
                        NetworkMgr:disableWifi(function()
                            logger.info("Zlibrary:downloadBook - Wi-Fi disabled after download as requested by user")
                        end)
                        logger.info("Zlibrary:downloadBook - Cleaning up dialogs cause wifi is turned off")
                        self.dialog_manager:closeAllDialogs()
                    end
                    -- The reader stays where it was (typically the FileManager); show the new book
                    -- without making them leave and re-enter the folder. This runs on both "Close"
                    -- and the skip-the-prompt path (which calls this with no filing choice). The
                    -- open path does not need it: opening the book replaces the FileManager, and
                    -- KOReader re-reads the folder when the reader is closed.
                    _refreshFileManagerListing()
                end,
                Config.getCategories()
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

            -- book.filesize is raw server JSON; a non-numeric value would make math.min throw
            -- inside the scheduled poll, so only poll against a real number.
            local stop_poll = startProgressPoll(target_filepath, progress_callback, tonumber(book.filesize))
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
