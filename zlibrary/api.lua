local Config = require("zlibrary.config")
local util = require("util")
local logger = require("logger")
local json = require("json")
local ltn12 = require("ltn12")
local http = require("socket.http")
local socket = require("socket")
local T = require("zlibrary.gettext")

local Api = {}

local function _transformApiBookData(api_book)
    if not api_book or type(api_book) ~= "table" then
        return nil
    end
    return {
        id = api_book.id,
        hash = api_book.hash,
        title = util.trim(api_book.title or "Unknown Title"),
        author = util.trim(api_book.author or "Unknown Author"),
        year = api_book.year or "N/A",
        format = api_book.extension or "N/A",
        size = api_book.filesizeString or api_book.filesize or "N/A",
        lang = api_book.language or "N/A",
        rating = api_book.interestScore or "N/A",
        href = api_book.href,
        download = api_book.dl,
        cover = api_book.cover,
        description = api_book.description,
        publisher = api_book.publisher,
        series = api_book.series,
        pages = api_book.pages,
        identifier = api_book.identifier,
    }
end

function Api.makeHttpRequest(options)
    logger.dbg(string.format("Zlibrary:Api.makeHttpRequest - START - URL: %s, Method: %s", options.url, options.method or "GET"))

    local response_body_table = {}
    local result = { body = nil, status_code = nil, error = nil, headers = nil }

    local sink_to_use = options.sink
    if not sink_to_use then
        response_body_table = {}
        sink_to_use = ltn12.sink.table(response_body_table)
    end

    local request_params = {
        url = options.url,
        method = options.method or "GET",
        headers = options.headers,
        source = options.source,
        sink = sink_to_use,
        redirect = options.redirect or false,
    }
    logger.dbg(string.format("Zlibrary:Api.makeHttpRequest - Request Params: URL: %s, Method: %s, Redirect: %s", request_params.url, request_params.method, tostring(request_params.redirect)))

    local req_ok, r_val, r_code, r_headers_tbl, r_status_str = pcall(http.request, request_params)

    logger.dbg(string.format("Zlibrary:Api.makeHttpRequest - pcall result: ok=%s, r_val=%s (type %s), r_code=%s (type %s), r_headers_tbl type=%s, r_status_str=%s",
        tostring(req_ok), tostring(r_val), type(r_val), tostring(r_code), type(r_code), type(r_headers_tbl), tostring(r_status_str)))

    if not req_ok then
        result.error = "Network request failed: " .. tostring(r_val)
        logger.err(string.format("Zlibrary:Api.makeHttpRequest - END (pcall error) - Error: %s", result.error))
        return result
    end

    result.status_code = r_code
    result.headers = r_headers_tbl

    if not options.sink then
        result.body = table.concat(response_body_table)
    end

    if type(result.status_code) ~= "number" then
        result.error = "Invalid HTTP response: status code missing or not a number. Got: " .. tostring(result.status_code)
        logger.err(string.format("Zlibrary:Api.makeHttpRequest - END (Invalid response code type) - Error: %s", result.error))
        return result
    end

    if result.status_code ~= 200 and result.status_code ~= 206 then
        if not result.error then
            result.error = string.format("HTTP Error: %s (%s)", result.status_code, r_status_str or "Unknown Status")
        end
    end

    logger.dbg(string.format("Zlibrary:Api.makeHttpRequest - END - Status: %s, Headers found: %s, Error: %s",
        result.status_code, tostring(result.headers ~= nil), tostring(result.error)))
    return result
end

function Api.login(email, password)
    logger.info(string.format("Zlibrary:Api.login - START"))
    local result = { user_id = nil, user_key = nil, error = nil }

    local rpc_url = Config.getRpcUrl()
    if not rpc_url then
        result.error = "The Zlibrary server address (URL) is not set. Please configure it in the Zlibrary plugin settings."
        logger.err(string.format("Zlibrary:Api.login - END (Configuration error) - Error: %s", result.error))
        return result
    end

    local body_data = {
        isModal = "true",
        email = email,
        password = password,
        site_mode = "books",
        action = "login",
        gg_json_mode = "1"
    }
    local body_parts = {}
    for k, v in pairs(body_data) do
        table.insert(body_parts, util.urlEncode(k) .. "=" .. util.urlEncode(v))
    end
    local body = table.concat(body_parts, "&")

    local http_result = Api.makeHttpRequest{
        url = rpc_url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8",
            ["Accept"] = "application/json, text/javascript, */*; q=0.01",
            ["User-Agent"] = Config.USER_AGENT,
            ["X-Requested-With"] = "XMLHttpRequest",
            ["Content-Length"] = tostring(#body),
        },
        source = ltn12.source.string(body),
        redirect = true,
    }

    if http_result.error then
        result.error = "Login request failed: " .. http_result.error
        logger.err(string.format("Zlibrary:Api.login - END (HTTP error) - Error: %s", result.error))
        return result
    end

    local data, _, err_msg = json.decode(http_result.body)

    if not data or type(data) ~= "table" then
        result.error = "Login failed: Invalid response format. " .. (err_msg or "")
        logger.err(string.format("Zlibrary:Api.login - END (JSON error) - Error: %s", result.error))
        return result
    end

    local session = data.response or {}
    local user_id = tostring(session.user_id or "")
    local user_key = session.user_key or ""

    if user_id == "" or user_key == "" then
        result.error = "Login failed: " .. (session.message or "Credentials rejected or invalid response.")
        logger.warn(string.format("Zlibrary:Api.login - END (Credentials error) - Error: %s", result.error))
        return result
    end

    result.user_id = user_id
    result.user_key = user_key
    logger.info(string.format("Zlibrary:Api.login - END (Success) - UserID: %s", result.user_id))
    return result
end

function Api.search(query, user_id, user_key, languages, extensions, order, page)
    logger.info(string.format("Zlibrary:Api.search - START - Query: %s, Page: %s", query, tostring(page)))
    local result = { results = nil, total_count = nil, error = nil }

    local search_url = Config.getSearchUrl()
    if not search_url then
        result.error = "The Zlibrary server address (URL) is not set. Please configure it in the Zlibrary plugin settings."
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
        ["User-Agent"] = Config.USER_AGENT,
        ["Accept"] = "application/json, text/javascript, */*; q=0.01",
        ["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8",
        ["Content-Length"] = tostring(#body),
    }
    if user_id and user_key then
        headers["Cookie"] = string.format("remix_userid=%s; remix_userkey=%s", user_id, user_key)
    end

    logger.dbg(string.format("Zlibrary:Api.search - Request URL: %s, Body: %s", search_url, body))

    local http_result = Api.makeHttpRequest{
        url = search_url,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(body),
        redirect = true,
    }

    if http_result.error then
        result.error = "Search request failed: " .. http_result.error
        result.status_code = http_result.status_code
        logger.err(string.format("Zlibrary:Api.search - END (HTTP error) - Error: %s, Status: %s", result.error, tostring(result.status_code)))
        return result
    end

    if not http_result.body then
        result.error = "Search request failed: Empty response body."
        logger.err(string.format("Zlibrary:Api.search - END (Empty body) - Error: %s", result.error))
        return result
    end

    local data, _, err_msg = json.decode(http_result.body)

    if not data or type(data) ~= "table" then
        result.error = "Search request failed: Invalid JSON response. " .. (err_msg or "")
        logger.err(string.format("Zlibrary:Api.search - END (JSON error) - Error: %s, Body: %s", result.error, http_result.body))
        return result
    end

    if data.error then
        result.error = "Search API error: " .. (data.error.message or data.error)
        logger.warn(string.format("Zlibrary:Api.search - END (API error in response) - Error: %s", result.error))
        return result
    end

    local books_from_api = {}
    if data.books and type(data.books) == "table" then
        books_from_api = data.books
    elseif data.exactMatch and data.exactMatch.books and type(data.exactMatch.books) == "table" then
        books_from_api = data.exactMatch.books
    end

    local transformed_books = {}
    if #books_from_api > 0 then
        for _, api_book_item in ipairs(books_from_api) do
            local transformed_book = _transformApiBookData(api_book_item)
            if transformed_book then
                table.insert(transformed_books, transformed_book)
            else
                logger.warn("Zlibrary:Api.search - Failed to transform an API book item, skipping.")
            end
        end
    end
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

function Api.downloadBook(download_url, target_filepath, user_id, user_key, referer_url)
    logger.info(string.format("Zlibrary:Api.downloadBook - START - URL: %s, Target: %s", download_url, target_filepath))
    local result = { success = false, error = nil }
    local file, err_open = io.open(target_filepath, "wb")
    if not file then
        result.error = "Failed to open target file: " .. (err_open or "Unknown error")
        logger.err(string.format("Zlibrary:Api.downloadBook - END (File open error) - Error: %s", result.error))
        return result
    end

    local headers = { ["User-Agent"] = Config.USER_AGENT }
    if user_id and user_key then
        headers["Cookie"] = string.format("remix_userid=%s; remix_userkey=%s", user_id, user_key)
    end
    if referer_url then
        headers["Referer"] = referer_url
    end

    local http_result = Api.makeHttpRequest{
        url = download_url,
        method = "GET",
        headers = headers,
        sink = ltn12.sink.file(file),
        timeout = 300,
        redirect = true
    }

    if http_result.error and not (http_result.status_code and http_result.headers) then
        result.error = "Download failed: " .. http_result.error
        pcall(os.remove, target_filepath)
        logger.err(string.format("Zlibrary:Api.downloadBook - END (Request error) - Error: %s", result.error))
        return result
    end

    local content_type = http_result.headers and http_result.headers["content-type"]
    if content_type and string.find(string.lower(content_type), "text/html") then
        result.error = "Download limit reached or file is an HTML page."
        pcall(os.remove, target_filepath)
        logger.warn(string.format("Zlibrary:Api.downloadBook - END (HTML content detected) - URL: %s, Status: %s, Content-Type: %s", download_url, tostring(http_result.status_code), content_type))
        return result
    end

    if http_result.error or (http_result.status_code and http_result.status_code ~= 200) then
        result.error = "Download failed: " .. (http_result.error or string.format("HTTP Error: %s", http_result.status_code))
        pcall(os.remove, target_filepath)
        logger.err(string.format("Zlibrary:Api.downloadBook - END (Download error) - Error: %s, Status: %s", result.error, tostring(http_result.status_code)))
        return result
    else
        result.success = true
        logger.info(string.format("Zlibrary:Api.downloadBook - END (Success) - Target: %s", target_filepath))
        return result
    end
end

function Api.downloadBookCover(download_url, target_filepath)
    logger.info(string.format("Zlibrary:Api.downloadBookCover - START - URL: %s, Target: %s", download_url, target_filepath))
    local result = { success = false, error = nil }
    local file, err_open = io.open(target_filepath, "wb")
    if not file then
        result.error = "Failed to open target file: " .. (err_open or "Unknown error")
        logger.err(string.format("Zlibrary:Api.downloadBookCover - END (File open error) - Error: %s", result.error))
        return result
    end

    local headers = { ["User-Agent"] = Config.USER_AGENT }

    local http_result = Api.makeHttpRequest{
        url = download_url,
        method = "GET",
        headers = headers,
        sink = ltn12.sink.file(file),
        timeout = 100,
        redirect = true
    }

    if http_result.error and not (http_result.status_code and http_result.headers) then
        result.error = "Download failed: " .. http_result.error
        pcall(os.remove, target_filepath)
        logger.err(string.format("Zlibrary:Api.downloadBookCover - END (Request error) - Error: %s", result.error))
        return result
    end

    if http_result.error then
        result.error = "Download network request failed: " .. http_result.error
        pcall(os.remove, target_filepath)
        logger.err("Zlibrary:Api.downloadBookCover - END (HTTP error from Api.makeHttpRequest) - Error: " .. result.error .. ", Status: " .. tostring(http_result.status_code))
        return result
    end

    if http_result.status_code ~= 200 then
        result.error = string.format("Download HTTP Error: %s", http_result.status_code)
        pcall(os.remove, target_filepath)
        logger.err("Zlibrary:Api.downloadBookCover - END (HTTP status error) - Error: " .. result.error)
        return result
    end

    logger.info("Zlibrary:Api.downloadBookCover - END (Success)")
    result.success = true
    return result
end

function Api.getRecommendedBooks(user_id, user_key)
    local url = Config.getRecommendedBooksUrl()
    if not url then
        logger.warn("Api.getRecommendedBooks - Base URL not configured")
        return { error = T("Z-library server URL not configured.") }
    end

    local headers = {
        ['Content-Type'] = 'application/x-www-form-urlencoded',
        ["User-Agent"] = Config.USER_AGENT,
    }
    if user_id and user_key then
        headers["Cookie"] = string.format("remix_userid=%s; remix_userkey=%s", user_id, user_key)
    end

    local http_result = Api.makeHttpRequest{
        url = url,
        method = "GET",
        headers = headers,
    }

    if http_result.error then
        logger.warn("Api.getRecommendedBooks - HTTP request error: ", http_result.error)
        return { error = string.format("%s: %s", T("Failed to fetch recommended books"), http_result.error) }
    end

    if not http_result.body then
        logger.warn("Api.getRecommendedBooks - No response body")
        return { error = T("Failed to fetch recommended books (no response body).") }
    end

    local success, data = pcall(json.decode, http_result.body)
    if not success or not data then
        logger.warn("Api.getRecommendedBooks - Failed to decode JSON: ", http_result.body)
        return { error = T("Failed to parse recommended books response.") }
    end

    if data.success ~= 1 or not data.books then
        logger.warn("Api.getRecommendedBooks - API error: ", http_result.body)
        return { error = data.message or T("API returned an error for recommended books.") }
    end

    local transformed_books = {}
    for _, book_data in ipairs(data.books) do
        local transformed_book = _transformApiBookData(book_data)
        if transformed_book then
            table.insert(transformed_books, transformed_book)
        else
            logger.warn("Api.getRecommendedBooks - Failed to transform book data: ", book_data.id)
        end
    end

    return { books = transformed_books }
end

function Api.getMostPopularBooks(user_id, user_key)
    local url = Config.getMostPopularBooksUrl()
    if not url then
        logger.warn("Api.getMostPopularBooks - Base URL not configured")
        return { error = T("Z-library server URL not configured.") }
    end

    local headers = {
        ['Content-Type'] = 'application/x-www-form-urlencoded',
        ["User-Agent"] = Config.USER_AGENT,
    }
    if user_id and user_key then
        headers["Cookie"] = string.format("remix_userid=%s; remix_userkey=%s", user_id, user_key)
    end

    local http_result = Api.makeHttpRequest{
        url = url,
        method = "GET",
        headers = headers,
    }

    if http_result.error then
        logger.warn("Api.getMostPopularBooks - HTTP request error: ", http_result.error)
        return { error = string.format("%s: %s", T("Failed to fetch most popular books"), http_result.error) }
    end

    if not http_result.body then
        logger.warn("Api.getMostPopularBooks - No response body")
        return { error = T("Failed to fetch most popular books (no response body).") }
    end

    local success, data = pcall(json.decode, http_result.body)
    if not success or not data then
        logger.warn("Api.getMostPopularBooks - Failed to decode JSON: ", http_result.body)
        return { error = T("Failed to parse most popular books response.") }
    end

    if data.success ~= 1 or not data.books then
        logger.warn("Api.getMostPopularBooks - API error: ", http_result.body)
        return { error = data.message or T("API returned an error for most popular books.") }
    end

    local transformed_books = {}
    for _, book_data in ipairs(data.books) do
        local transformed_book = _transformApiBookData(book_data)
        if transformed_book then
            table.insert(transformed_books, transformed_book)
        else
            logger.warn("Api.getMostPopularBooks - Failed to transform book data: ", book_data.id)
        end
    end

    return { books = transformed_books }
end

function Api.getBookDetails(user_id, user_key, book_id, book_hash)
    local url = Config.getBookDetailsUrl(book_id, book_hash)
    if not url then
        logger.warn("Api.getBookDetails - URL could not be constructed. Base URL configured? Book ID/Hash provided?")
        return { error = T("Z-library server URL not configured or book identifiers missing.") }
    end

    local headers = {
        ["User-Agent"] = Config.USER_AGENT,
        ['Content-Type'] = 'application/x-www-form-urlencoded',
    }
    if user_id and user_key then
        headers["Cookie"] = string.format("remix_userid=%s; remix_userkey=%s", user_id, user_key)
    end

    local http_result = Api.makeHttpRequest{
        url = url,
        method = "GET",
        headers = headers,
    }

    if http_result.error then
        logger.warn("Api.getBookDetails - HTTP request error: ", http_result.error)
        return { error = string.format("%s: %s", T("Failed to fetch book details"), http_result.error) }
    end

    if not http_result.body then
        logger.warn("Api.getBookDetails - No response body")
        return { error = T("Failed to fetch book details (no response body).") }
    end

    local success, data = pcall(json.decode, http_result.body)
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

return Api
