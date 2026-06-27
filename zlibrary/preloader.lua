local RenderImage = require("ui/renderimage")
local NetworkMgr = require("ui/network/manager")
local util = require("util")
local logger = require("logger")
local Config = require("zlibrary.config")
local Api = require("zlibrary.api")
local Cache = require("zlibrary.cache")
local AsyncHelper = require("zlibrary.async_helper")

local ApiHelper = {}
function ApiHelper.fetchWithAuth(api_method, ...)
    local session = Config.getUserSession() or {}
    local res = api_method(session.user_id, session.user_key, ...)
    if type(res) ~= "table" or not Api.isAuthenticationError(res.error) then return res end
    local email = Config.getSetting(Config.SETTINGS_USERNAME_KEY)
    local password = Config.getSetting(Config.SETTINGS_PASSWORD_KEY)
    if not email or email == "" or not password or password == "" then return res end
    local login_res = Api.login(email, password)
    if type(login_res) ~= "table" or login_res.error then return res end
    Config.saveUserSession(login_res.user_id, login_res.user_key)
    return api_method(login_res.user_id, login_res.user_key, ...)
end
function ApiHelper.downloadCover(url, book_hash, skip_conflicts)
    if type(url) ~= "string" or type(book_hash) ~= "string" then return false end
    local cover_cache = Cache:new{ type="cover" }
    local cache_path = cover_cache:get(book_hash)
    if cache_path then return true end
    local temp_path = cover_cache:getTempPath(book_hash)
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
    cover_cache:insert(book_hash, temp_path)
    return true
end

local Preloader ={
        channel  = AsyncHelper:createChannel("Preloader",  2)
}
local function getSafeCallback(callback)
    return type(callback) == "function" and callback or function() end
end
function  Preloader.getDownloadQuotaStatus(callback)
        local wrap_callback = getSafeCallback(callback)
        local quota_status = Config.getConfigRuntimeCache():get("download_quota_status")
        if type(quota_status) == "table" and next(quota_status) then return wrap_callback(true) end
        if not NetworkMgr:isConnected() then return wrap_callback(false) end
        local task = function() return ApiHelper.fetchWithAuth(Api.getDownloadQuotaStatus) end
        Preloader.channel:pushTask(task, function(success, res)
                local is_ok = false
                if success and type(res) == "table" and type(res.quota_status) == "table" then
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
        Preloader.channel:pushTask(task, function(success, res)
                local is_ok = false
                if success and type(res) == "table" and type(res.books) == "table" then
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
        Preloader.channel:pushTask(task, function(success, res)
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
        Preloader.channel:pushTask(task, function(success, res)
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
        local cache = Cache:new{ name = "multi_search"}
        local cache_key = "popular"
        local has_cache = cache:get(cache_key, 1840000)
        if type(has_cache) == "table" then return wrap_callback(true) end
        if not NetworkMgr:isConnected() then return wrap_callback(false) end
        local task = function() return Api.getMostPopularBooks() end
        Preloader.channel:pushTask(task, function(success, res)
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
        local cache = Cache:new{ name = "multi_search"}
        local cache_key = "recommended"
        local has_cache = cache:get(cache_key, 1840000)
        if type(has_cache) == "table" then return wrap_callback(true) end
        if not NetworkMgr:isConnected() then return wrap_callback(false) end
        local task = function() return Api.getRecommendedBooks() end
        Preloader.channel:pushTask(task, function(success, res)
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
        local task = function() return ApiHelper.downloadCover(url, book_hash) end
        Preloader.channel:pushTask(task, function(success, res)
                wrap_callback(success and res ==true)
        end)
end

return {Preloader=Preloader, helper =ApiHelper}
