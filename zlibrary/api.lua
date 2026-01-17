local Config = require("zlibrary.config")
local util = require("util")
local logger = require("logger")
local json = require("json")
local ltn12 = require("ltn12")
local http = require("socket.http")
local socketutil = require("socketutil")
local socket_url = require("socket.url")
local T = require("zlibrary.gettext")

local Api = {}

function Api.isAuthenticationError(error_message)
    if not error_message then
        return false
    end
    
    local error_str = tostring(error_message)

    if string.find(error_str, "Please login", 1, true) ~= nil or 
       string.find(error_str, "Incorrect email or password", 1, true) ~= nil then
        return true
    end
    

    if string.find(error_str, "Download limit reached", 1, true) ~= nil then
        return true
    end
    
    return false
end

local function _transformApiBookData(api_books)
    if not api_books or type(api_books) ~= "table" then
        return {}
    end

    local is_single = api_books.id ~= nil
    local books = is_single and { api_books } or api_books

    local transformed_books = {}

    for _, book in ipairs(books) do
        if book.id then

            -- Handle case where dl field contains 'exactEnd' - mark for detail fetch
            local download_url = book.dl
            local needs_detail_fetch = false
            if download_url and type(download_url) == "string" and download_url == "exactEnd" then
                needs_detail_fetch = true
                download_url = nil  -- Clear the invalid URL
            end

            table.insert(transformed_books, {
                id =book.id,
                hash =book.hash,
                title = util.trim(book.title) or "Unknown Title",
                author = util.trim(book.author) or "Unknown Author",
                year = book.year or "N/A",
                format = book.extension or "N/A",
                size = book.filesizeString or book.filesize or "N/A",
                filesize = book.filesize,
                lang = book.language or "N/A",
                rating = book.interestScore or "N/A",
                href = book.href,
                download = download_url,
                date_download = book.date_download,
                date_saved = book.date_saved,
                needs_detail_fetch = needs_detail_fetch,
                cover = book.cover,
                description = book.description,
                publisher = book.publisher,
                series = book.series,
                pages = book.pages,
                identifier = book.identifier,
            })
        else
            logger.warn("transformApiBookData - Failed to transform an API book item, skipping.", book)
        end
    end

    return is_single and transformed_books[1] or transformed_books
end

local function _checkAndHandleRedirect(skip_check, status_code, current_url)

    local result = { has_redirect = nil, real_url = nil, status_code = nil, error = nil }
    if skip_check or type(current_url) ~= "string" or current_url == "" or (status_code ~= 301 and 
                    status_code ~= 302 and status_code ~= 303 and status_code ~= 307) then
            return result
    end
    
    local http_result = Api.makeHttpRequest({
        url = current_url,
        method = "HEAD",
        headers = { ["User-Agent"] = Config.USER_AGENT },
        timeout = {5, 10},
        redirect = true,
    })
    
    result.has_redirect = true
    result.status_code = http_result.status_code

    local real_url = http_result.headers and (http_result.headers.location or http_result.headers.Location)
    if type(real_url) ~= "string" or real_url == "" then
        result.error = string.format("Redirect failed: empty Location header. %s", tostring(http_result.error))
        return result
    end

    local real_url_parse = socket_url.parse(real_url)
    local real_url_host = real_url_parse.host
    if real_url_host and real_url_parse.scheme and real_url_host ~= socket_url.parse(current_url).host then

        Config.setCacheRealUrl(current_url, socket_url.build({
                scheme = real_url_parse.scheme,
                host = real_url_host
        }))
        result.real_url = real_url
    else
        result.error = string.format("Invalid or unchanged Location header. %s", tostring(http_result.error))
    end
    return result
end

local function _extractErrorFromJsonBody(body)
    if not body or body == "" then
        return nil
    end
    
    local success, data = pcall(json.decode, body, json.decode.simple)
    if success and type(data) == "table" then
        if data.error then
            if type(data.error) == "table" and data.error.message then
                return tostring(data.error.message)
            else
                return tostring(data.error)
            end
        elseif data.message then
            return tostring(data.message)
        end
    end
    
    return nil
end

function Api.makeHttpRequest(options)
    logger.dbg(string.format("Zlibrary:Api.makeHttpRequest - START - URL: %s, Method: %s", options.url, options.method or "GET"))
    
    local response_body_table = {}
    local result = { body = nil, status_code = nil, error = nil, headers = nil }

    local sink_to_use = options.sink
    if not sink_to_use then
        response_body_table = {}
        sink_to_use = socketutil.table_sink(response_body_table)
    end

    if options.timeout then
        if type(options.timeout) == "table" then
            socketutil:set_timeout(options.timeout[1], options.timeout[2])
            logger.dbg(string.format("Zlibrary:Api.makeHttpRequest - Setting timeout to %s/%s seconds", options.timeout[1], options.timeout[2]))
        else
            socketutil:set_timeout(options.timeout)
            logger.dbg(string.format("Zlibrary:Api.makeHttpRequest - Setting timeout to %s seconds", options.timeout))
        end
    end

    local request_params = {
        url = options.url,
        method = options.method or "GET",
        headers = options.headers,
        source = options.source,
        sink = sink_to_use,
        -- zlibrary mirror redirects may break API paths; disabled by default.
        redirect = options.redirect or false,
    }

    logger.dbg(string.format("Zlibrary:Api.makeHttpRequest - Request Params: URL: %s, Method: %s, Timeout: %s", request_params.url, request_params.method, tostring(options.timeout)))

    local req_ok, r_val, r_code, r_headers_tbl, r_status_str = pcall(http.request, request_params)
    
    if options.timeout then
        socketutil:reset_timeout()
        logger.dbg("Zlibrary:Api.makeHttpRequest - Reset timeout to default")
    end

    logger.dbg(string.format("Zlibrary:Api.makeHttpRequest - pcall result: ok=%s, r_val=%s (type %s), r_code=%s (type %s), r_headers_tbl type=%s, r_status_str=%s",
        tostring(req_ok), tostring(r_val), type(r_val), tostring(r_code), type(r_code), type(r_headers_tbl), tostring(r_status_str)))

    if not req_ok then
        local error_msg = tostring(r_val)
        if string.find(error_msg, "timeout") or 
           string.find(error_msg, "wantread") or 
           string.find(error_msg, "closed") or 
           string.find(error_msg, "connection") or
           string.find(error_msg, "sink timeout") then
            result.error = T("Request timed out - please check your connection and try again")
        else
            result.error = T("Network request failed") .. ": " .. error_msg
        end
        logger.err(string.format("Zlibrary:Api.makeHttpRequest - END (pcall error) - Error: %s", result.error))
        return result
    end

    result.status_code = r_code
    result.headers = r_headers_tbl

    if not options.sink then
        result.body = table.concat(response_body_table)
    end

    if type(result.status_code) ~= "number" then
        local status_str = tostring(result.status_code)
        if string.find(status_str, "wantread") or 
           string.find(status_str, "timeout") or 
           string.find(status_str, "closed") or
           string.find(status_str, "sink timeout") then
            result.error = T("Request timed out - please check your connection and try again")
        else
            result.error = T("Network connection error - please check your internet connection and try again")
        end
        logger.err(string.format("Zlibrary:Api.makeHttpRequest - END (Invalid response code type) - Error: %s", result.error))
        return result
    end

    local is_skip_check = not (request_params.method == "GET" and type(options.getRedirectedUrl) == "function")
    local check_result = _checkAndHandleRedirect(is_skip_check, result.status_code, options.url)
    if check_result.has_redirect then
        if check_result.real_url then
            options.url = options.getRedirectedUrl()
            options.getRedirectedUrl = nil
            return Api.makeHttpRequest(options)
        elseif check_result.error then
            result = check_result
        end
    end

    if result.status_code ~= 200 and result.status_code ~= 206 then
        if not result.error then
            local json_error = _extractErrorFromJsonBody(result.body)
            if json_error then
                result.error = json_error
            else
                result.error = string.format("%s: %s (%s)", T("HTTP Error"), result.status_code, r_status_str or T("Unknown Status"))
            end
        end
    end

    logger.dbg(string.format("Zlibrary:Api.makeHttpRequest - END - Status: %s, Headers found: %s, Error: %s",
        result.status_code, tostring(result.headers ~= nil), tostring(result.error)))
    return result
end

function Api.login(email, password, is_retry)
    logger.info(string.format("Zlibrary:Api.login - START"))
    local result = { user_id = nil, user_key = nil, error = nil }

    local login_url = Config.getLoginUrl()
    if not login_url then
        result.error = T("The Z-library server address (URL) is not set. Please configure it in the Z-library plugin settings.")
        logger.err(string.format("Zlibrary:Api.login - END (Configuration error) - Error: %s", result.error))
        return result
    end

    local body_data = {
        email = email or "",
        password = password or "",
    }
    local body_parts = {}
    for k, v in pairs(body_data) do
        table.insert(body_parts, util.urlEncode(k) .. "=" .. util.urlEncode(v))
    end
    local body = table.concat(body_parts, "&")

    local http_result = Api.makeHttpRequest{
        url = login_url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8",
            ["Accept"] = "application/json, text/javascript, */*; q=0.01",
            ["User-Agent"] = Config.USER_AGENT,
            ["X-Requested-With"] = "XMLHttpRequest",
            ["Content-Length"] = tostring(#body),
        },
        source = ltn12.source.string(body),
        timeout = Config.getLoginTimeout(),
        -- Avoid redirects - 301/302 convert POST to GET per RFC.
        redirect = false,
    }

    local check_result = _checkAndHandleRedirect(is_retry, http_result.status_code, login_url)
    if check_result.has_redirect then
        if check_result.real_url then
            return Api.login(email, password, true)
        elseif check_result.error then
            http_result = check_result
        end
    end

    if not http_result.body or http_result.body == "" then
        result.error = http_result.error or T("Login failed: Empty response from server")
        logger.err(string.format("Zlibrary:Api.login - END (Empty body) - Error: %s", result.error))
        return result
    end

    local data, _, err_msg = json.decode(http_result.body)

    if not data or type(data) ~= "table" then
        result.error = http_result.error or (T("Login failed: Invalid response format") .. (err_msg and (". " .. err_msg) or ""))
        logger.err(string.format("Zlibrary:Api.login - END (JSON error) - Error: %s", result.error))
        return result
    end

    local success_flag = tonumber(data.success) or 0
    local session = data.user or data.response or {}

    if success_flag ~= 1 then
        local api_message = data.error or
                           (type(session) == "table" and session.message) or
                           data.message
        result.error = api_message and tostring(api_message) or (http_result.error or T("Login failed"))
        logger.warn(string.format("Zlibrary:Api.login - END (API error) - Error: %s", result.error))
        return result
    end

    if type(session) ~= "table" then
        result.error = T("Login failed: Invalid session data")
        logger.warn(string.format("Zlibrary:Api.login - END (Session error) - Error: %s", result.error))
        return result
    end

    local user_id = tostring(session.id or session.user_id or "")
    local user_key = session.remix_userkey or session.user_key or ""

    if user_id == "" or user_key == "" then
        result.error = T("Login failed") .. ": " .. (session.message or data.message or T("Credentials rejected or invalid response"))
        logger.warn(string.format("Zlibrary:Api.login - END (Credentials error) - Error: %s", result.error))
        return result
    end

    result.user_id = user_id
    result.user_key = user_key
    logger.info(string.format("Zlibrary:Api.login - END (Success) - UserID: %s", result.user_id))
    return result
end

function Api.search(query, user_id, user_key, languages, extensions, order, page, is_retry)
    logger.info(string.format("Zlibrary:Api.search - START - Query: %s, Page: %s", query, tostring(page)))
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
        timeout = Config.getSearchTimeout(),
    }

    local check_result = _checkAndHandleRedirect(is_retry, http_result.status_code, search_url)
    if check_result.has_redirect then
        if check_result.real_url then
            return Api.search(query, user_id, user_key, languages, extensions, order, page, true)
        elseif check_result.error then
            http_result = check_result
        end
    end  

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

    local data, _, err_msg = json.decode(http_result.body)

    if not data or type(data) ~= "table" then
        result.error = T("Invalid response format from server") .. (err_msg and (": " .. err_msg) or "")
        logger.err(string.format("Zlibrary:Api.search - END (JSON error) - Error: %s, Body: %s", result.error, http_result.body))
        return result
    end

    if data.error then
        result.error = T("Search API error") .. ": " .. (data.error.message or data.error)
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

function Api.downloadBook(download_url, target_filepath, user_id, user_key, referer_url, progress_callback)
    logger.info(string.format("Zlibrary:Api.downloadBook - START - URL: %s, Target: %s", download_url, target_filepath))

    if Config.isTestModeEnabled() then
        logger.info("Zlibrary:Api.downloadBook - Test mode enabled, creating fake successful download")
        logger.info(string.format("Zlibrary:Api.downloadBook - END (Test mode success) - Target: %s", target_filepath))
        return { success = true, error = nil }
    end

    local result = { success = false, error = nil }
    local file, err_open = io.open(target_filepath, "wb")
    if not file then
        result.error = T("Failed to open target file") .. ": " .. (err_open or T("Unknown error"))
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
        pcall(os.remove, target_filepath)
        logger.err(string.format("Zlibrary:Api.downloadBook - END (Request error) - Error: %s", result.error))
        return result
    end

    local content_type = http_result.headers and http_result.headers["content-type"]
    if content_type and string.find(string.lower(content_type), "text/html") then
        result.error = T("Download limit reached or file is an HTML page")
        pcall(os.remove, target_filepath)
        logger.warn(string.format("Zlibrary:Api.downloadBook - END (HTML content detected) - URL: %s, Status: %s, Content-Type: %s", download_url, tostring(http_result.status_code), content_type))
        return result
    end

    if http_result.error or (http_result.status_code and http_result.status_code ~= 200) then
        result.error = http_result.error or string.format("%s: %s", T("HTTP Error"), http_result.status_code)
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
        result.error = T("Failed to open target file") .. ": " .. (err_open or T("Unknown error"))
        logger.err(string.format("Zlibrary:Api.downloadBookCover - END (File open error) - Error: %s", result.error))
        return result
    end

    local headers = { ["User-Agent"] = Config.USER_AGENT }

    local http_result = Api.makeHttpRequest{
        url = download_url,
        method = "GET",
        headers = headers,
        sink = socketutil.file_sink(file),
        timeout = Config.getCoverTimeout(),
        redirect = true,
    }

    if http_result.error and not (http_result.status_code and http_result.headers) then
        result.error = http_result.error
        pcall(os.remove, target_filepath)
        logger.err(string.format("Zlibrary:Api.downloadBookCover - END (Request error) - Error: %s", result.error))
        return result
    end

    if http_result.error then
        result.error = http_result.error
        pcall(os.remove, target_filepath)
        logger.err("Zlibrary:Api.downloadBookCover - END (HTTP error from Api.makeHttpRequest) - Error: " .. result.error .. ", Status: " .. tostring(http_result.status_code))
        return result
    end

    if http_result.status_code ~= 200 then
        result.error = string.format("%s: %s", T("Download HTTP Error"), http_result.status_code)
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
        timeout = Config.getRecommendedTimeout(),
        getRedirectedUrl = Config.getRecommendedBooksUrl,
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
        timeout = Config.getPopularTimeout(),
        getRedirectedUrl = Config.getMostPopularBooksUrl,
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
        timeout = Config.getBookDetailsTimeout(),
        getRedirectedUrl = function()
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

function Api.getDownloadLink(user_id, user_key, book_id, book_hash)
    local url = Config.getDownloadLinkUrl(book_id, book_hash)
    if not url then
        logger.warn("Api.getDownloadLink - URL could not be constructed. Base URL configured? Book ID/Hash provided?")
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
        timeout = Config.getBookDetailsTimeout(),
        getRedirectedUrl = function()
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
        logger.warn("Api.getDownloadLink - No download link in response: ", http_result.body)
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

function Api.getSimilarBooks(user_id, user_key, book_id, book_hash)
    local url = Config.getSimilarBooksUrl(book_id, book_hash)
    if not url then
        logger.warn("Api.getSimilarBooks - Base URL not configured")
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
        timeout = Config.getPopularTimeout(),
        getRedirectedUrl = function()
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

function Api.getDownloadedBooks(user_id, user_key, page, order)

    page = page or 1

    local url = Config.getDownloadedBooksUrl(page, order)
    if not url then
        logger.warn("Api.getDownloadedBooks - Base URL not configured")
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
        timeout = Config.getPopularTimeout(),
        getRedirectedUrl = function()
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
        timeout = Config.getPopularTimeout(),
        getRedirectedUrl = function()
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

function Api.unfavoriteBook(user_id, user_key, book_stub)
    local url = Config.getUnFavoriteUrl(book_stub.id)
    if not url then
        logger.warn("Api.unfavoriteBook - Base URL not configured")
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
        timeout = Config.getPopularTimeout(),
        getRedirectedUrl = function()
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
        timeout = Config.getPopularTimeout(),
        getRedirectedUrl = Config.getDownloadQuotaUrl,
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
        timeout = Config.getPopularTimeout(),
        getRedirectedUrl = Config.getFavoriteBookIdsUrl,
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
        timeout = Config.getPopularTimeout(),
        getRedirectedUrl = function()
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

function Api.healthCheck(baseUrl)
    local url = baseUrl .. "/eapi/info/ok"

    local http_result = Api.makeHttpRequest{
        url = url,
        method = "GET",
        headers = {
            ["User-Agent"] = Config.USER_AGENT,
        },
        timeout = {5, 10},
        redirect = true,
    }

    if http_result.error then
        logger.dbg("Api.healthCheck - Failed for " .. baseUrl .. ": " .. tostring(http_result.error))
        return { success = false, error = http_result.error }
    end

    if not http_result.status_code or http_result.status_code < 200 or http_result.status_code >= 300 then
        logger.dbg("Api.healthCheck - Invalid status code " .. tostring(http_result.status_code) .. " for " .. baseUrl)
        return { success = false, error = "Invalid status code: " .. tostring(http_result.status_code) }
    end

    if not http_result.body or http_result.body == "" then
        logger.dbg("Api.healthCheck - No response body from " .. baseUrl)
        return { success = false, error = "No response body" }
    end

    local success_parse, data = pcall(json.decode, http_result.body, json.decode.simple)
    if not success_parse or not data then
        logger.dbg("Api.healthCheck - Failed to parse JSON from " .. baseUrl)
        return { success = false, error = "Invalid JSON response" }
    end

    if data.success == 1 then
        logger.info("Api.healthCheck - Success for " .. baseUrl .. " (status: " .. tostring(http_result.status_code) .. ")")
        return { success = true, url = baseUrl }
    end

    logger.dbg("Api.healthCheck - Invalid response data from " .. baseUrl .. ", success=" .. tostring(data.success))
    return { success = false, error = "Invalid API response" }
end

function Api.findWorkingBaseUrl()
    logger.info("Api.findWorkingBaseUrl - START - Checking SEED_URLS")
    
    for i, seed_url in ipairs(Config.SEED_URLS) do
        local clean_url = seed_url
        if string.sub(clean_url, -1) == "/" then
            clean_url = string.sub(clean_url, 1, -2)
        end
        
        logger.info(string.format("Api.findWorkingBaseUrl - Trying [%d/%d]: %s", i, #Config.SEED_URLS, clean_url))
        
        local result = Api.healthCheck(clean_url)
        if result.success then
            logger.info(string.format("Api.findWorkingBaseUrl - Found working URL: %s", clean_url))
            return { success = true, url = clean_url }
        end
    end
    
    logger.warn("Api.findWorkingBaseUrl - END - No working URL found")
    return { success = false, error = T("Could not find a working Z-library server. Please check your internet connection or set the base URL manually.") }
end


return Api
