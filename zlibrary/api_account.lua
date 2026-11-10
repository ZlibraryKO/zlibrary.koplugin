-- The signed-in reader's lists and actions: downloaded, favourites, booklists, the download quota,
-- and adding/removing favourites and downloaded entries. Part of the Api facade; see api_core.lua.

local Config = require("zlibrary.config")
local logger = require("logger")
local json = require("json")
local T = require("zlibrary.gettext")
local Api = require("zlibrary.api_core")
local Shared = require("zlibrary.api_shared")
local _safeTrim = Shared._safeTrim
local _authedHeaders = Shared._authedHeaders
local _transformApiBookData = Shared._transformApiBookData
local _extractErrorFromJsonBody = Shared._extractErrorFromJsonBody

function Api.getDownloadedBooks(user_id, user_key, page, order)

    page = page or 1

    local url = Config.getDownloadedBooksUrl(page, order)
    if not url then
        logger.warn("Api.getDownloadedBooks - Base URL not configured")
        return { error = T("Z-library server URL not configured.") }
    end

    local headers = _authedHeaders(user_id, user_key)

    local http_result = Api.makeHttpRequest{
        url = url,
        method = "GET",
        headers = headers,
        timeout = Config.getPopularTimeout(),
        onRedirect = function()
            return Config.getDownloadedBooksUrl(page, order)
        end,
    }

    if http_result.error then
        logger.warn("Api.getDownloadedBooks - HTTP request error: ", http_result.error)
        return { error = http_result.error }
    end

    if not http_result.body then
        logger.warn("Api.getDownloadedBooks - No response body")
        return { error = T("Failed to fetch downloaded books (no response body).") }
    end

    -- Get nil instead of functions for 'null' by using JSON.decode.simple
    local success, data = pcall(json.decode, http_result.body, json.decode.simple)
    if not success or not data then
        logger.warn("Api.getDownloadedBooks - Failed to decode JSON: ", http_result.body)
        return { error = T("Failed to parse downloaded books response.") }
    end
     
    if not (data.success == 1 and data.books and type(data.pagination) == "table") then
        logger.warn("Api.getDownloadedBooks - API error: ", http_result.body)
        return { error = data.message or T("API returned an error for downloaded books.") }
    end

    local pagination = data.pagination
    local has_more_results = type(data.books) == "table" and #data.books > 0 
    and pagination.total_pages and pagination.current 
    and page == pagination.current and pagination.current < pagination.total_pages

    local transformed_books = _transformApiBookData(data.books)
    return { has_more_results = has_more_results, books = transformed_books }
end

function Api.getFavoriteBooks(user_id, user_key, page, order)

    page = page or 1
    
    local url = Config.getFavoriteBooksUrl(page, order)
    if not url then
        logger.warn("Api.getFavoriteBooks - Base URL not configured")
        return { error = T("Z-library server URL not configured.") }
    end

    local headers = _authedHeaders(user_id, user_key)

    local http_result = Api.makeHttpRequest{
        url = url,
        method = "GET",
        headers = headers,
        timeout = Config.getPopularTimeout(),
        onRedirect = function()
            return Config.getFavoriteBooksUrl(page, order)
        end,
    }
    
    if http_result.error then
        logger.warn("Api.getFavoriteBooks - HTTP request error: ", http_result.error)
        return { error = http_result.error }
    end

    if not http_result.body then
        logger.warn("Api.getFavoriteBooks - No response body")
        return { error = T("Failed to fetch favorite books (no response body).") }
    end

    local success, data = pcall(json.decode, http_result.body, json.decode.simple)
    if not success or not data then
        logger.warn("Api.getFavoriteBooks - Failed to decode JSON: ", http_result.body)
        return { error = T("Failed to parse favorite books response.") }
    end

    if not (data.success == 1 and data.books and data.pagination) then
        logger.warn("Api.getFavoriteBooks - API error: ", http_result.body)
        return { error = data.message or T("API returned an error for favorite books.") }
    end
    
    local pagination = data.pagination
    local has_more_results = type(data.books) == "table" and #data.books > 0 
    and pagination.total_pages and pagination.current 
    and page == pagination.current and pagination.current < pagination.total_pages

    local transformed_books = _transformApiBookData(data.books)
    return { has_more_results = has_more_results, books = transformed_books }
end

function Api.getBooklists(user_id, user_key)
    local url = Config.getBooklistsUrl()
    if not url then
        logger.warn("Api.getBooklists - Base URL not configured")
        return { error = T("Z-library server URL not configured.") }
    end

    local http_result = Api.makeHttpRequest{
        url = url,
        method = "GET",
        headers = _authedHeaders(user_id, user_key),
        timeout = Config.getPopularTimeout(),
        onRedirect = function()
            return Config.getBooklistsUrl()
        end,
    }

    -- Passed through unchanged: Api.isAuthenticationError matches "Please login" in it to re-login.
    if http_result.error then
        logger.warn("Api.getBooklists - HTTP request error: ", http_result.error)
        return { error = http_result.error }
    end

    if not http_result.body then
        logger.warn("Api.getBooklists - No response body")
        return { error = T("Failed to fetch booklists (no response body).") }
    end

    local success, data = pcall(json.decode, http_result.body, json.decode.simple)
    if not success or type(data) ~= "table" then
        logger.warn("Api.getBooklists - Failed to decode JSON: ", http_result.body)
        return { error = T("Failed to parse booklists response.") }
    end

    if data.success ~= 1 or type(data.list) ~= "table" then
        logger.warn("Api.getBooklists - API error: ", http_result.body)
        return { error = _extractErrorFromJsonBody(http_result.body) or T("API returned an error for booklists.") }
    end

    local booklists = {}
    for _, entry in ipairs(data.list) do
        local id = type(entry) == "table" and tonumber(entry.id)
        if id then
            table.insert(booklists, {
                id = id,
                name = _safeTrim(entry.title, T("Untitled")),
                count = tonumber(entry.books_count),
            })
        end
    end
    return { booklists = booklists }
end

function Api.getBooklistBooks(user_id, user_key, booklist_id, page, is_redir_callback)
    page = page or 1

    local url = Config.getBooklistBooksUrl(booklist_id, page)
    if not url then
        logger.warn("Api.getBooklistBooks - Base URL or booklist id missing")
        return { error = T("Z-library server URL not configured.") }
    end

    local headers = _authedHeaders(user_id, user_key)
    headers["Content-Length"] = "0"

    -- A function, not a URL: a 301/302/303 turns the POST into a GET (_applyRedirectMethod).
    local http_result = Api.makeHttpRequest{
        url = url,
        method = "POST",
        headers = headers,
        timeout = Config.getPopularTimeout(),
        onRedirect = (not is_redir_callback) and function()
            return function() return Api.getBooklistBooks(user_id, user_key, booklist_id, page, true) end
        end,
    }

    if is_redir_callback then return http_result end
    if http_result.error then
        logger.warn("Api.getBooklistBooks - HTTP request error: ", http_result.error)
        return { error = http_result.error }
    end

    if not http_result.body then
        logger.warn("Api.getBooklistBooks - No response body")
        return { error = T("Failed to fetch booklist books (no response body).") }
    end

    local success, data = pcall(json.decode, http_result.body, json.decode.simple)
    if not success or type(data) ~= "table" then
        logger.warn("Api.getBooklistBooks - Failed to decode JSON: ", http_result.body)
        return { error = T("Failed to parse booklist books response.") }
    end

    if data.success ~= 1 or type(data.books) ~= "table" then
        logger.warn("Api.getBooklistBooks - API error: ", http_result.body)
        return { error = _extractErrorFromJsonBody(http_result.body) or T("API returned an error for booklist books.") }
    end

    local books = {}
    for _, entry in ipairs(data.books) do
        if type(entry) == "table" and type(entry.book) == "table" then
            table.insert(books, entry.book)
        end
    end

    local has_more
    local pagination = data.pagination
    if type(pagination) == "table" and tonumber(pagination.total_pages) then
        has_more = (tonumber(pagination.current) or page) < tonumber(pagination.total_pages)
    else
        has_more = #data.books >= Config.BOOKLIST_PAGE_SIZE
    end

    return { books = _transformApiBookData(books), has_more_results = has_more }
end

-- Removes the book from the account's download history on the server. The list under My Books is that
-- history, so there is nothing local to delete here -- the entry may well have been downloaded on
-- another device. Same shape as unfavoriteBook: a GET that answers with success = 1.
function Api.deleteDownloadedBook(user_id, user_key, book_stub)
    local url = type(book_stub) == "table" and Config.getDeleteDownloadedUrl(book_stub.id) or nil
    if not url then
        logger.warn("Api.deleteDownloadedBook - Base URL not configured or book id missing")
        return { error = T("Z-library server URL not configured.") }
    end

    local headers = _authedHeaders(user_id, user_key)

    local http_result = Api.makeHttpRequest{
        url = url,
        method = "GET",
        headers = headers,
        timeout = Config.getPopularTimeout(),
        onRedirect = function()
            return Config.getDeleteDownloadedUrl(book_stub.id)
        end,
    }

    if http_result.error then
        logger.warn("Api.deleteDownloadedBook - HTTP request error: ", http_result.error)
        return { error = http_result.error }
    end

    if not http_result.body then
        logger.warn("Api.deleteDownloadedBook - No response body")
        return { error = T("Failed to remove the book from downloaded (no response body).") }
    end

    local success, data = pcall(json.decode, http_result.body, json.decode.simple)
    if not success or type(data) ~= "table" then
        logger.warn("Api.deleteDownloadedBook - Failed to decode JSON: ", http_result.body)
        return { error = T("Failed to parse the remove from downloaded response.") }
    end

    if data.success ~= 1 then
        logger.warn("Api.deleteDownloadedBook - API error: ", http_result.body)
        return { error = data.message or T("API returned an error for remove from downloaded.") }
    end

    return { success = true }
end

function Api.unfavoriteBook(user_id, user_key, book_stub)
    local url = Config.getUnFavoriteUrl(book_stub.id)
    if not url then
        logger.warn("Api.unfavoriteBook - Base URL not configured")
        return { error = T("Z-library server URL not configured.") }
    end

    local headers = _authedHeaders(user_id, user_key)

    local http_result = Api.makeHttpRequest{
        url = url,
        method = "GET",
        headers = headers,
        timeout = Config.getPopularTimeout(),
        onRedirect = function()
            return Config.getUnFavoriteUrl(book_stub.id)
        end,
    }

    if http_result.error then
        logger.warn("Api.unfavoriteBook - HTTP request error: ", http_result.error)
        return { error = http_result.error }
    end

    if not http_result.body then
        logger.warn("Api.unfavoriteBook - No response body")
        return { error = T("Failed to fetch unfavorite book (no response body).") }
    end

    local success, data = pcall(json.decode, http_result.body, json.decode.simple)
    if not success or not data then
        logger.warn("Api.unfavoriteBook - Failed to decode JSON: ", http_result.body)
        return { error = T("Failed to parse unfavorite book response.") }
    end

    if data.success ~= 1 then
        logger.warn("Api.unfavoriteBook - API error: ", http_result.body)
        return { error = data.message or T("API returned an error for unfavorite book.") }
    end

    return { success = true }
end

function Api.getDownloadQuotaStatus(user_id, user_key)
    local url = Config.getDownloadQuotaUrl()
    if not url then
        logger.warn("Api.getDownloadQuotaStatus - Base URL not configured")
        return { error = T("Z-library server URL not configured.") }
    end

    local headers = _authedHeaders(user_id, user_key)

    local http_result = Api.makeHttpRequest{
        url = url,
        method = "GET",
        headers = headers,
        timeout = Config.getPopularTimeout(),
        onRedirect = Config.getDownloadQuotaUrl,
    }

    if http_result.error then
        logger.warn("Api.getDownloadQuotaStatus - HTTP request error: ", http_result.error)
        return { error = http_result.error }
    end

    if not http_result.body then
        logger.warn("Api.getDownloadQuotaStatus - No response body")
        return { error = T("Failed to fetch download quota status (no response body).") }
    end

    local success, data = pcall(json.decode, http_result.body, json.decode.simple)
    if not success or not data then
        logger.warn("Api.getDownloadQuotaStatus - Failed to decode JSON: ", http_result.body)
        return { error = T("Failed to parse download quota status response.") }
    end

    if not (data.success == 1 and type(data.user) == "table" and data.user.downloads_today ~= nil )then
        logger.warn("Api.getDownloadQuotaStatus - API error: ", http_result.body)
        return { error = data.message or T("API returned an error for download quota status.") }
    end

    return { quota_status = {today = data.user.downloads_today, limit = data.user.downloads_limit}}
end

function Api.getFavoriteBookIds(user_id, user_key)
    local url = Config.getFavoriteBookIdsUrl()
    if not url then
        logger.warn("Api.getFavoriteBookIds - Base URL not configured")
        return { error = T("Z-library server URL not configured.") }
    end

    local headers = _authedHeaders(user_id, user_key)

    local http_result = Api.makeHttpRequest{
        url = url,
        method = "GET",
        headers = headers,
        timeout = Config.getPopularTimeout(),
        onRedirect = Config.getFavoriteBookIdsUrl,
    }

    if http_result.error then
        logger.warn("Api.getFavoriteBookIds - HTTP request error: ", http_result.error)
        return { error = http_result.error }
    end

    if not http_result.body then
        logger.warn("Api.getFavoriteBookIds - No response body")
        return { error = T("Failed to fetch favorite-book IDs (no response body).") }
    end

    local success, data = pcall(json.decode, http_result.body, json.decode.simple)
    if not success or not data then
        logger.warn("Api.getFavoriteBookIds - Failed to decode JSON: ", http_result.body)
        return { error = T("Failed to parse favorite-book IDs.") }
    end
    
    if not (data.success == 1 and data.books) then
        logger.warn("Api.getFavoriteBookIds - API error: ", http_result.body)
        return { error = data.message or T("API returned an error for favorite-book IDs.") }
    end
    
    return { books = data.books }
end

function Api.favoriteBook(user_id, user_key, book_stub)
    local url = Config.getFavoriteUrl(book_stub.id)
    if not url then
        logger.warn("Api.favoriteBook - Base URL not configured")
        return { error = T("Z-library server URL not configured.") }
    end

    local headers = _authedHeaders(user_id, user_key)

    local http_result = Api.makeHttpRequest{
        url = url,
        method = "GET",
        headers = headers,
        timeout = Config.getPopularTimeout(),
        onRedirect = function()
            return Config.getFavoriteUrl(book_stub.id)
        end,
    }

    if http_result.error then
        logger.warn("Api.favoriteBook - HTTP request error: ", http_result.error)
        return { error = http_result.error }
    end

    if not http_result.body then
        logger.warn("Api.favoriteBook - No response body")
        return { error = T("Failed to fetch favorite book (no response body).") }
    end

    local success, data = pcall(json.decode, http_result.body, json.decode.simple)
    if not success or not data then
        logger.warn("Api.favoriteBook - Failed to decode JSON: ", http_result.body)
        return { error = T("Failed to parse favorite book response.") }
    end

    if data.success ~= 1 then
        logger.warn("Api.favoriteBook - API error: ", http_result.body)
        return { error = data.message or T("API returned an error for favorite book.") }
    end

    return { success = true }
end

return Api
