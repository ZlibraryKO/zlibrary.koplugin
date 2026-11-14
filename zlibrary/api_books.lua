-- Finding books: search, the recommended and most-popular lists, book details, similar books and
-- comments. Part of the Api facade; see api_core.lua.

local Config = require("zlibrary.config")
local util = require("util")
local logger = require("logger")
local json = require("json")
local T = require("zlibrary.gettext")
local Api = require("zlibrary.api_core")
local Shared = require("zlibrary.api_shared")
local _usableCoverUrl = Shared._usableCoverUrl
local _sessionCookie = Shared._sessionCookie
local _authedHeaders = Shared._authedHeaders
local _transformApiBookData = Shared._transformApiBookData

-- Also checked by the menu at fetch time: a list saved to the multi-search cache before a rule here
-- existed still carries the URLs it rejects.
Api.usableCoverUrl = _usableCoverUrl

function Api.search(query, user_id, user_key, languages, extensions, order, page, is_redir_callback)
    -- The query at dbg, not info: what someone searches for is theirs, and crash.log at the default level is
    -- what gets attached to bug reports. The page number is enough to follow a session there.
    logger.info(string.format("Zlibrary:Api.search - START - Page: %s", tostring(page)))
    logger.dbg(string.format("Zlibrary:Api.search - Query: %s", tostring(query)))
    local result = { results = nil, total_count = nil, error = nil }

    local search_url = Config.getSearchUrl()
    if not search_url then
        result.error = T("The Z-library server address (URL) is not set. Please configure it in the Z-library plugin settings.")
        logger.err(string.format("Zlibrary:Api.search - END (Configuration error) - Error: %s", result.error))
        return result
    end

    local page_num = page or 1
    local limit_num = Config.SEARCH_RESULTS_LIMIT

    local body_data_parts = {}
    table.insert(body_data_parts, "message=" .. util.urlEncode(query or ""))
    table.insert(body_data_parts, "page=" .. util.urlEncode(tostring(page_num)))
    table.insert(body_data_parts, "limit=" .. util.urlEncode(tostring(limit_num)))

    if languages and #languages > 0 then
        for i, lang in ipairs(languages) do
            table.insert(body_data_parts, string.format("languages[%d]=%s", i - 1, util.urlEncode(lang)))
        end
    end
    if extensions and #extensions > 0 then
        for i, ext in ipairs(extensions) do
            table.insert(body_data_parts, string.format("extensions[%d]=%s", i - 1, util.urlEncode(ext)))
        end
    end
    if order and #order > 0 then
            table.insert(body_data_parts, "order=" .. util.urlEncode(order[1]))
    end

    local body = table.concat(body_data_parts, "&")

    local headers = {
        ["User-Agent"] = Config.getUserAgent(),
        ["Accept"] = "application/json, text/javascript, */*; q=0.01",
        ["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8",
        ["Content-Length"] = tostring(#body),
    }
    headers["Cookie"] = _sessionCookie(user_id, user_key)

    logger.dbg(string.format("Zlibrary:Api.search - Request URL: %s, Body: %s", search_url, body))

    local http_result = Api.makeHttpRequest{
        url = search_url,
        method = "POST",
        headers = headers,
        body = body,
        timeout = Config.getSearchTimeout(),
        -- Retry once if the server accepts the connection and then never answers; the user
        -- asked for this, and such a stall is transient. See makeHttpRequest.
        retry_on_stall = true,
        onRedirect = (not is_redir_callback) and function()
            return function(redir_res) return Api.search(query, user_id, user_key, languages, extensions, order, page, true) end
        end,
    }

    if is_redir_callback then return http_result end
    if http_result.error then
        result.error = http_result.error
        result.status_code = http_result.status_code
        logger.err(string.format("Zlibrary:Api.search - END (HTTP error) - Error: %s, Status: %s", result.error, tostring(result.status_code)))
        return result
    end

    if not http_result.body then
        result.error = T("No response received from server - please try again")
        logger.err(string.format("Zlibrary:Api.search - END (Empty body) - Error: %s", result.error))
        return result
    end

    -- See Api.login: the pcall catches the unparseable body json.decode raises on, and
    -- json.decode.simple keeps json null from decoding to a truthy function sentinel.
    local success, data = pcall(json.decode, http_result.body, json.decode.simple)

    if not success or type(data) ~= "table" then
        result.error = T("Invalid response format from server")
        logger.err(string.format("Zlibrary:Api.search - END (JSON error) - Error: %s, Body: %s", result.error, tostring(http_result.body)))
        return result
    end

    if data.error then
        -- data.error may be a string or an object; guard the index the way _extractErrorFromJsonBody does.
        local api_message = (type(data.error) == "table" and data.error.message) or data.error
        result.error = T("Search API error") .. ": " .. tostring(api_message)
        logger.warn(string.format("Zlibrary:Api.search - END (API error in response) - Error: %s", result.error))
        return result
    end

    local books_from_api = {}
    if data.books and type(data.books) == "table" then
        books_from_api = data.books
    elseif data.exactMatch and data.exactMatch.books and type(data.exactMatch.books) == "table" then
        books_from_api = data.exactMatch.books
    end

    local transformed_books = _transformApiBookData(books_from_api)
    result.results = transformed_books

    if data.pagination and data.pagination.total_items then
        result.total_count = tonumber(data.pagination.total_items)
    elseif data.exactBooksCount then -- Fallback for exact match count
        result.total_count = tonumber(data.exactBooksCount)
    elseif #transformed_books > 0 and not result.total_count then
        logger.warn("Zlibrary:Api.search - Total count not found in API response pagination or exactBooksCount.")
    end

    logger.info(string.format("Zlibrary:Api.search - END (Success) - Found %d results, Total reported: %s", #result.results, tostring(result.total_count)))
    return result
end

function Api.getRecommendedBooks(user_id, user_key)
    local url = Config.getRecommendedBooksUrl()
    if not url then
        logger.warn("Api.getRecommendedBooks - Base URL not configured")
        return { error = T("Z-library server URL not configured.") }
    end

    local headers = _authedHeaders(user_id, user_key)
    
    local http_result = Api.makeHttpRequest{
        url = url,
        method = "GET",
        headers = headers,
        timeout = Config.getRecommendedTimeout(),
        retry_on_stall = true,
        onRedirect = Config.getRecommendedBooksUrl,
    }
    
    if http_result.error then
        logger.warn("Api.getRecommendedBooks - HTTP request error: ", http_result.error)
        return { error = http_result.error }
    end

    if not http_result.body then
        logger.warn("Api.getRecommendedBooks - No response body")
        return { error = T("Failed to fetch recommended books (no response body).") }
    end

    local success, data = pcall(json.decode, http_result.body, json.decode.simple)
    if not success or not data then
        logger.warn("Api.getRecommendedBooks - Failed to decode JSON: ", http_result.body)
        return { error = T("Failed to parse recommended books response.") }
    end

    if data.success ~= 1 or not data.books then
        logger.warn("Api.getRecommendedBooks - API error: ", http_result.body)
        return { error = data.message or T("API returned an error for recommended books.") }
    end
    
    local transformed_books = _transformApiBookData(data.books)
    return { books = transformed_books }
end

-- `languages` and `extensions` are the reader's search-language and search-format selections.
-- The most-popular endpoint ignores both -- the list is the same mostly-English one whatever is
-- asked for, switch-language included -- so narrowing that list here leaves nothing for most
-- languages. The search endpoint does filter by language and format on the server, and with an
-- empty query and the "popular" order it answers with the most popular books matching them,
-- which is what this tab should show. `filtered` tells the caller that an empty result means
-- "nothing matches those languages and formats".
function Api.getMostPopularBooks(user_id, user_key, languages, extensions, page)
    local url = Config.getMostPopularBooksUrl()
    if not url then
        logger.warn("Api.getMostPopularBooks - Base URL not configured")
        return { error = T("Z-library server URL not configured.") }
    end

    local has_languages = type(languages) == "table" and #languages > 0
    local has_extensions = type(extensions) == "table" and #extensions > 0
    if has_languages or has_extensions then
        local page_num = page or 1
        local res = Api.search("", user_id, user_key, has_languages and languages or nil,
            has_extensions and extensions or nil, { "popular" }, page_num)
        if res.error then return { error = res.error } end
        local books = res.results or {}
        -- The search pages, 30 books at a time, up to the 500 the server reports as its total;
        -- fetching only the first page left the tab at 30. Without a total, a full page is the
        -- best sign there is another.
        local has_more
        if res.total_count then
            has_more = page_num * Config.SEARCH_RESULTS_LIMIT < res.total_count
        else
            has_more = #books >= Config.SEARCH_RESULTS_LIMIT
        end
        return { books = books, filtered = true, has_more_results = has_more }
    end

    local headers = _authedHeaders(user_id, user_key)

    local http_result = Api.makeHttpRequest{
        url = url,
        method = "GET",
        headers = headers,
        timeout = Config.getPopularTimeout(),
        retry_on_stall = true,
        onRedirect = Config.getMostPopularBooksUrl,
    }

    if http_result.error then
        logger.warn("Api.getMostPopularBooks - HTTP request error: ", http_result.error)
        return { error = http_result.error }
    end

    if not http_result.body then
        logger.warn("Api.getMostPopularBooks - No response body")
        return { error = T("Failed to fetch most popular books (no response body).") }
    end

    local success, data = pcall(json.decode, http_result.body, json.decode.simple)
    if not success or not data then
        logger.warn("Api.getMostPopularBooks - Failed to decode JSON: ", http_result.body)
        return { error = T("Failed to parse most popular books response.") }
    end

    if data.success ~= 1 or not data.books then
        logger.warn("Api.getMostPopularBooks - API error: ", http_result.body)
        return { error = data.message or T("API returned an error for most popular books.") }
    end

    local transformed_books = _transformApiBookData(data.books)
    return { books = transformed_books }
end

function Api.getBookDetails(user_id, user_key, book_id, book_hash)
    local url = Config.getBookDetailsUrl(book_id, book_hash)
    if not url then
        logger.warn("Api.getBookDetails - URL could not be constructed. Base URL configured? Book ID/Hash provided?")
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
            return Config.getBookDetailsUrl(book_id, book_hash)
        end,
    }

    if http_result.error then
        logger.warn("Api.getBookDetails - HTTP request error: ", http_result.error)
        return { error = http_result.error }
    end

    if not http_result.body then
        logger.warn("Api.getBookDetails - No response body")
        return { error = T("Failed to fetch book details (no response body).") }
    end

    local success, data = pcall(json.decode, http_result.body, json.decode.simple)
    if not success or not data then
        logger.warn("Api.getBookDetails - Failed to decode JSON: ", http_result.body)
        return { error = T("Failed to parse book details response.") }
    end

    if data.success ~= 1 or not data.book then
        logger.warn("Api.getBookDetails - API error: ", http_result.body)
        return { error = data.message or T("API returned an error for book details.") }
    end

    local transformed_book = _transformApiBookData(data.book)
    if not transformed_book then
        logger.warn("Api.getBookDetails - Failed to transform book data: ", data.book.id)
        return { error = T("Failed to process book details.") }
    end

    return { book = transformed_book }
end

function Api.getSimilarBooks(user_id, user_key, book_id, book_hash)
    local url = Config.getSimilarBooksUrl(book_id, book_hash)
    if not url then
        logger.warn("Api.getSimilarBooks - Base URL not configured")
        return { error = T("Z-library server URL not configured.") }
    end

    local headers = _authedHeaders(user_id, user_key)

    local http_result = Api.makeHttpRequest{
        url = url,
        method = "GET",
        headers = headers,
        timeout = Config.getPopularTimeout(),
        onRedirect = function()
            return Config.getSimilarBooksUrl(book_id, book_hash)
        end,
    }

    if http_result.error then
        logger.warn("Api.getSimilarBooks - HTTP request error: ", http_result.error)
        return { error = http_result.error }
    end

    if not http_result.body then
        logger.warn("Api.getSimilarBooks - No response body")
        return { error = T("Failed to fetch similar books (no response body).") }
    end

    local success, data = pcall(json.decode, http_result.body, json.decode.simple)
    if not success or not data then
        logger.warn("Api.getSimilarBooks - Failed to decode JSON: ", http_result.body)
        return { error = T("Failed to parse similar books response.") }
    end

    if data.success ~= 1 or not data.books then
        logger.warn("Api.getSimilarBooks - API error: ", http_result.body)
        return { error = data.message or T("API returned an error for similar books.") }
    end

    local transformed_books = _transformApiBookData(data.books)
    return { books = transformed_books }
end

function Api.getBookComments(user_id, user_key, book_id)
    if not book_id then
        logger.warn("Api.getBookComments - Missing book_id parameter")
        return {
            error = T("Book ID is required.")
        }
    end

    local url = Config.getBookCommentsUrl(book_id)
    if not url then
        logger.warn("Api.getBookComments - URL could not be constructed. Base URL configured? Book ID provided?")
        return {
            error = T("Z-library server URL not configured or book identifiers missing.")
        }
    end

    local headers = {
        ["User-Agent"] = Config.getUserAgent()
    }

    local http_result = Api.makeHttpRequest {
        url = url,
        method = "GET",
        headers = headers,
        timeout = Config.getBookCommentsTimeout(),
        retry_on_stall = true,
        onRedirect = function()
            return Config.getBookCommentsUrl(book_id)
        end
    }

    if http_result.error then
        logger.warn("Api.getBookComments - HTTP request error: ", http_result.error)
        return {
            error = http_result.error
        }
    end

    if not http_result.body then
        logger.warn("Api.getBookComments - No response body")
        return {
            error = T("Failed to fetch book comments (no response body).")
        }
    end

    local success, data = pcall(json.decode, http_result.body, json.decode.simple)
    if not success or not data then
        logger.warn("Api.getBookComments - Failed to decode JSON: ", http_result.body)
        return {
            error = T("Failed to parse book comments response.")
        }
    end

    if data.success ~= 1 then
        logger.warn("Api.getBookComments - API error: ", http_result.body)
        return {
            error = data.message or T("API returned an error for book comments.")
        }
    end
    
    return {
        comments = data.comments
    }
end

return Api
