local RenderImage = require("ui/renderimage")
local NetworkMgr = require("ui/network/manager")
local util = require("util")
local logger = require("logger")
local Config = require("zlibrary.config")
local Api = require("zlibrary.api")
local Cache = require("zlibrary.cache")
local AsyncHelper = require("zlibrary.async_helper")

local ApiHelper = {}
-- Signs in with Api.login directly, and returns the original response when no credentials are
-- stored. Both are deliberate and load-bearing: this runs as background cache warming, and
-- Zlibrary:login opens a credentials dialog when nothing is stored. Routing this through the
-- plugin's login "to share the retry logic" would throw a modal at a reader who is reading.
function ApiHelper.fetchWithAuth(api_method, ...)
    local session = Config.getUserSession() or {}
    local res = api_method(session.user_id, session.user_key, ...)
    if type(res) ~= "table" or not Api.isAuthenticationError(res.error) then return res end
    local email = Config.getSetting(Config.SETTINGS_USERNAME_KEY)
    local password = Config.getSetting(Config.SETTINGS_PASSWORD_KEY)
    if not email or email == "" or not password or password == "" then return res end
    local login_res = Api.login(email, password)
    if type(login_res) ~= "table" or login_res.error then return res end
    local retried = api_method(login_res.user_id, login_res.user_key, ...)
    -- Every caller of this runs it in a forked child, where saving the session would write the
    -- settings file from a fork-time snapshot and never reach the parent regardless
    -- (Config.disableSubprocessWrites drops that write). Hand the session back with the result
    -- instead and let the parent keep it -- _adoptRenewedSession below. Without that, the parent
    -- goes on using the session the server just rejected, and every background task that meets it
    -- signs in again for nothing.
    if type(retried) == "table" then
        retried.renewed_session = { user_id = login_res.user_id, user_key = login_res.user_key }
    end
    return retried
end
function ApiHelper.downloadCover(url, book_hash, skip_conflicts)
    if type(url) ~= "string" or type(book_hash) ~= "string" then return false end
    local cover_cache = Cache:new{ type="cover" }
    local cache_path = cover_cache:get(book_hash)
    if cache_path then return true end
    local temp_path = cover_cache:getTempPath(book_hash)
    -- nil when the server's hash is not usable as a path component; util.fileExists would raise on it
    if not temp_path then return false end
    if util.fileExists(temp_path) and skip_conflicts then return false end
    util.removeFile(temp_path)
    local res = Api.downloadBookCover(url, temp_path)
    if not res or res.error or not res.success then
        util.removeFile(temp_path)
        return false
    end
    local ok, cover_bb = pcall(RenderImage.renderImageFile, RenderImage, temp_path, false, nil, nil)
    if not ok or not cover_bb then
        logger.err("[downloadCover] Image rendering failed or corrupted, deleted:", url)
        util.removeFile(temp_path)
        return false
    end
    if cover_bb.free then cover_bb:free() end
    -- insert moves the file into the cache and answers false when it could not -- an unwritable or
    -- full cache directory, or a rename and a copy that both failed. Returning true regardless
    -- told every caller the cover was cached when nothing was: the menu re-checked the cache,
    -- found nothing and skipped its refresh, leaving a blank slot that nothing retries, and
    -- downloadAndShowCover read that same nil back and tried to open a dialog on it. Report the
    -- failure instead, so the caller's retry budget applies and the temp file does not linger.
    if not cover_cache:insert(book_hash, temp_path) then
        logger.err("[downloadCover] could not move the cover into the cache:", book_hash)
        util.removeFile(temp_path)
        return false
    end
    return true
end

local Preloader ={
        channel  = AsyncHelper:createChannel("Preloader",  2)
}
local function getSafeCallback(callback)
    return type(callback) == "function" and callback or function() end
end

-- Keep a session a task had to mint for us. It was minted in a forked child, which cannot persist
-- anything (see Config.disableSubprocessWrites), so fetchWithAuth sends it back with the result
-- and this is the parent side that stores it.
local function _adoptRenewedSession(res)
    if type(res) ~= "table" then return res end
    local session = res.renewed_session
    if type(session) == "table" and session.user_id and session.user_key then
        logger.info("Preloader: adopting the session a background task renewed")
        Config.saveUserSession(session.user_id, session.user_key)
    end
    res.renewed_session = nil
    return res
end

-- Every task here goes through this rather than pushTask directly, so no call site can be added
-- that forgets the adoption above.
local function _pushTask(task, callback)
    Preloader.channel:pushTask(task, function(success, res)
        callback(success, _adoptRenewedSession(res))
    end)
end

function  Preloader.getDownloadQuotaStatus(callback)
        local wrap_callback = getSafeCallback(callback)
        local quota_status = Config.getConfigRuntimeCache():get("download_quota_status", 1800)
        if type(quota_status) == "table" and next(quota_status) then return wrap_callback(true) end
        if not NetworkMgr:isConnected() then return wrap_callback(false) end
        local task = function() return ApiHelper.fetchWithAuth(Api.getDownloadQuotaStatus) end
        _pushTask(task, function(success, res)
                local is_ok = false
                -- The account may have been cleared while the fetch ran; caching its quota now
                -- would show it to whoever signs in next.
                if success and Config.hasCredentials() and type(res) == "table" and type(res.quota_status) == "table" then
                        Config.getConfigRuntimeCache():insert("download_quota_status", res.quota_status)
                        is_ok = true
                end
                wrap_callback(is_ok)
        end)
end
function  Preloader.getFavoriteBookIds(callback)
        local wrap_callback = getSafeCallback(callback)
        local cached_ids = Config.getConfigRuntimeCache():get("favorite_book_ids", 1800)
        if type(cached_ids) == "table" and next(cached_ids) then return wrap_callback(true) end
        if not NetworkMgr:isConnected() then return wrap_callback(false) end
        local task = function() return ApiHelper.fetchWithAuth(Api.getFavoriteBookIds) end
        _pushTask(task, function(success, res)
                local is_ok = false
                -- Same guard as the quota warmer above: credentials cleared mid-fetch means
                -- these ids belong to an account that is gone, not to the next one.
                if success and Config.hasCredentials() and type(res) == "table" and type(res.books) == "table" then
                        local book_ids = {}
                        for _, book in ipairs(res.books) do
                                book_ids[tostring(book.id)] = true
                        end
                        Config.getConfigRuntimeCache():insert("favorite_book_ids", book_ids)
                        is_ok = true
                end
                wrap_callback (is_ok)
        end)
end
function  Preloader.getBookDetails(book_id, book_hash, callback)
        local wrap_callback = getSafeCallback(callback)
        if not (book_id and book_hash) then return wrap_callback(false) end
        local book_cache = Cache:new{ type="bookinfo" }
        local book_details_cache = book_cache:get(book_hash, 604800)
        if type(book_details_cache) == "table" and book_details_cache.title then return wrap_callback(true) end
        if not NetworkMgr:isConnected() then return wrap_callback(false) end
        local task = function() return ApiHelper.fetchWithAuth(Api.getBookDetails, book_id, book_hash) end
        _pushTask(task, function(success, res)
                if success and type(res) == "table" and type(res.book) == "table" then
                        book_cache:insert(book_hash, res.book)
                         wrap_callback(true)
                else
                        wrap_callback(false)
                end
        end)
end
function  Preloader.getBookComments(book_id, book_hash, callback)
        local wrap_callback = getSafeCallback(callback)
        if not (book_id and book_hash) then return wrap_callback(false) end
        local book_cache = Cache:new{ type="bookinfo" }
        local comments_key = string.format("%s_comments", book_hash)
        local book_comments_cache = book_cache:get(comments_key, 604800)
        if type(book_comments_cache) == "table" then return wrap_callback(true) end
        if not NetworkMgr:isConnected() then return wrap_callback(false) end
        local task = function() return ApiHelper.fetchWithAuth(Api.getBookComments, book_id) end
        _pushTask(task, function(success, res)
                local is_ok = false
                -- not have res.comments[1]  there are zero comments.
                if success and type(res) == "table" and type(res.comments) == "table"  then
                        book_cache:insert(comments_key, res.comments)
                        is_ok = true
                end
                wrap_callback(is_ok)
        end)
end
function  Preloader.getMostPopularBooks(callback)
        local wrap_callback = getSafeCallback(callback)
        local cache = Config.getMultiSearchCache()
        local cache_key = "popular"
        local has_cache = cache:get(cache_key, 1840000)
        if type(has_cache) == "table" then return wrap_callback(true) end
        if not NetworkMgr:isConnected() then return wrap_callback(false) end
        -- Deliberately not routed through fetchWithAuth: most-popular is the same list for
        -- every account (main.lua marks it requires_auth = false), so there is no session
        -- to attach and nothing to re-login for.
        local task = function() return Api.getMostPopularBooks() end
        _pushTask(task, function(success, res)
                local is_ok = false
                if success and type(res) == "table" and type(res.books) == "table" then
                        cache:insert(cache_key, res.books)
                        is_ok = true
                end
                wrap_callback(is_ok)
        end)
end
function  Preloader.getRecommendedBooks(callback)
        local wrap_callback = getSafeCallback(callback)
        local cache = Config.getMultiSearchCache()
        local cache_key = "recommended"
        local has_cache = cache:get(cache_key, 1840000)
        if type(has_cache) == "table" then return wrap_callback(true) end
        if not NetworkMgr:isConnected() then return wrap_callback(false) end
        -- Unlike most-popular above, recommended is per-account (requires_auth = true in
        -- main.lua), so it goes through fetchWithAuth for the session cookie and re-login.
        local task = function() return ApiHelper.fetchWithAuth(Api.getRecommendedBooks) end
        _pushTask(task, function(success, res)
                local is_ok = false
                if success and type(res) == "table" and type(res.books) == "table" then
                        cache:insert(cache_key, res.books)
                        is_ok = true
                end
                wrap_callback(is_ok)
        end)
end
function  Preloader.getBookCover(url, book_hash, callback)
        local wrap_callback = getSafeCallback(callback)
        if not (url and book_hash) then return wrap_callback(false) end
         local cover_cache = Cache:new{ type="cover" }
        local cache_path = cover_cache:get(book_hash)
        if cache_path then return wrap_callback(true) end
        if not NetworkMgr:isConnected() then return wrap_callback(false) end
        -- skip_conflicts = true: the Menu_Covers channel downloads the same covers with its
        -- own workers, and the unconditional temp-file cleanup without it could unlink the
        -- .downloading path out from under a concurrent subprocess.
        local task = function() return ApiHelper.downloadCover(url, book_hash, true) end
        _pushTask(task, function(success, res)
                wrap_callback(success and res ==true)
        end)
end

return {Preloader=Preloader, helper =ApiHelper}
