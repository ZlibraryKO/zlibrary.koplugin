-- Helpers several API parts share: the session cookie and authenticated headers, turning API book
-- records into the plugin's shape, and reading an error out of a JSON body. Private to the API
-- layer -- returned as a table and aliased by each part that needs one, never put on Api.

local Config = require("zlibrary.config")
local util = require("util")
local logger = require("logger")
local json = require("json")
local socket_url = require("socket.url")

-- util.trim indexes its argument directly, with no nil guard, so a missing field raises instead of
-- falling back. Json null decodes to a function sentinel, which raises the same way, and a trimmed
-- empty string is truthy, so an `or` fallback after the call would not catch it either. Check the
-- type first and treat blank as missing.
local function _safeTrim(value, default)
    if type(value) ~= "string" then
        return default
    end
    local trimmed = util.trim(value)
    return trimmed ~= "" and trimmed or default
end

-- A cover is fetched straight from this URL, so it has to be absolute. z-library returns the relative
-- placeholder "/img/cover-not-exists.png" for books with no cover; that parses to no host, so trying
-- to download it fails at once with "invalid host" and then retries the whole way through the cover
-- channel's retry budget -- three dead requests per coverless book on every page. Treat any cover
-- without a host as absent so it is skipped everywhere item.cover is checked.
local function _usableCoverUrl(cover)
    if type(cover) ~= "string" or cover == "" then
        return nil
    end
    local parsed = socket_url.parse(cover)
    if not (parsed and parsed.host) then
        return nil
    end
    -- The downloaded-books list names every cover with an empty collection folder
    -- (".../collections//<hash>.jpg"). The real folder differs per book -- userbooks, genesis,
    -- foreignfiction... -- and only the book's details carry it, so that URL is always a 404. Treat
    -- it as absent too; the menu falls back to the cover in the book's cached details.
    if parsed.path and parsed.path:find("//", 1, true) then
        return nil
    end
    return cover
end

-- The header block every authenticated JSON call sends.
--
-- Twelve call sites wrote this out by hand, two of them with the keys in a different order, and
-- fourteen carried a verbatim copy of the cookie line. Nothing varied between them, so there was
-- nothing for the duplication to buy -- only twelve places to update if the session format ever
-- changes, and twelve chances to miss one.
--
-- Calls that genuinely differ keep their own headers: login sends a Content-Length, downloadBook
-- a Referer, and the cover fetch sends no cookie at all.
-- The session as the server expects to receive it. One definition, because it has to agree with
-- what Api.login stored and with what zlibrary_credentials.lua lets a reader paste in by hand.
-- Returns nil when there is no session, which is also what an absent Cookie header looks like.
local function _sessionCookie(user_id, user_key)
    if not (user_id and user_key) then
        return nil
    end
    return string.format("remix_userid=%s; remix_userkey=%s", user_id, user_key)
end

local function _authedHeaders(user_id, user_key)
    local headers = {
        ["Content-Type"] = "application/x-www-form-urlencoded",
        ["User-Agent"] = Config.getUserAgent(),
    }
    headers["Cookie"] = _sessionCookie(user_id, user_key)
    return headers
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
                title = _safeTrim(book.title, "Unknown Title"),
                author = _safeTrim(book.author, "Unknown Author"),
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
                cover = _usableCoverUrl(book.cover),
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

-- A URL as it may appear in the log: scheme://host[:port]/path, without the query or fragment.
-- A resolved download link carries its signature in the query, which is credential-equivalent,
-- and crash.log is what readers attach to bug reports. Anything that does not parse as an
-- absolute URL -- a relative Location, a garbled header -- is cut at the first ? or # instead,
-- so nothing reaches the log with its query intact.
local function _loggableUrl(url)
    if type(url) ~= "string" then return tostring(url) end
    local parsed = socket_url.parse(url)
    if parsed and parsed.scheme and parsed.host then
        return socket_url.build({
            scheme = parsed.scheme,
            host = parsed.host,
            port = parsed.port,
            path = parsed.path,
        })
    end
    return (url:gsub("[?#].*$", ""))
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

return {
    _safeTrim = _safeTrim,
    _usableCoverUrl = _usableCoverUrl,
    _sessionCookie = _sessionCookie,
    _authedHeaders = _authedHeaders,
    _transformApiBookData = _transformApiBookData,
    _extractErrorFromJsonBody = _extractErrorFromJsonBody,
    _loggableUrl = _loggableUrl,
}
