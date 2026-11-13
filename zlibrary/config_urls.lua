-- The URL of every API endpoint, built on the current base URL. Part of the Config facade; see
-- config_core.lua.

local util = require("util")
local Config = require("zlibrary.config_core")

function Config.getSearchUrl()
    local base = Config.getBaseUrl()
    if not base then return nil end
    return base .. "/eapi/book/search"
end

-- The operator's own domain list, used as the last source in fetchDynamicDomains.
--
-- The singlelogin path, not the sibling /eapi/info/domains: that one answers with five
-- entries to this one's twenty-nine, and refreshDomainsCache replaces the cached list
-- rather than merging into it, so the short list would shrink the cache instead of filling
-- it. Both return the same {success, domains = {{domain = ...}}} shape assets/domains.json
-- has, so callers cannot tell which source answered -- and do not need to.
function Config.getDynamicDomainsUrl()
    local base = Config.getBaseUrl()
    if not base then return nil end
    return base .. "/eapi/info/domains/singlelogin"
end

function Config.getBookUrl(href)
    if not href then return nil end
    local base = Config.getBaseUrl()
    if not base then return nil end
    if not href:match("^/") then href = "/" .. href end
    return base .. href
end

function Config.getDownloadUrl(download_path)
    if not download_path then return nil end
    local base = Config.getBaseUrl()
    if not base then return nil end
    if not download_path:match("^/") then download_path = "/" .. download_path end
    return base .. download_path
end

function Config.getBookDetailsUrl(book_id, book_hash)
    local base = Config.getBaseUrl()
    if not base or not book_id or not book_hash then return nil end
    return base .. string.format("/eapi/book/%s/%s", book_id, book_hash)
end

function Config.getBookCommentsUrl(book_id)
    local base = Config.getBaseUrl()
    if not base or not book_id then return nil end
    return base .. string.format("/papi/comments/book/%s/0", book_id)
end

function Config.getDownloadLinkUrl(book_id, book_hash)
    local base = Config.getBaseUrl()
    if not base or not book_id or not book_hash then return nil end
    return base .. string.format("/eapi/book/%s/%s/file", book_id, book_hash)
end

function Config.getSimilarBooksUrl(book_id, book_hash)
    local base = Config.getBaseUrl()
    if not base or not book_id or not book_hash then return nil end
    return base .. string.format("/eapi/book/%s/%s/similar", book_id, book_hash)
end

function Config.getDownloadedBooksUrl(page, order)
    local base = Config.getBaseUrl()
    if not base then return nil end
    
    -- Note: the downloaded endpoint ignores order (verified against the live API -- every value
    -- returns the same sequence), unlike saved, which honours saved_date. So this value is inert.
    -- Sorting downloads by recency would have to be done client-side on each book's date_download,
    -- and was judged not worth the pagination complexity. Left as-is to avoid re-investigating.
    order = order or {"date"}
    page = page or 1

    local limit = Config.SEARCH_RESULTS_LIMIT
    local order_str = ""
    if #order > 0 then
        order_str = "&order=" .. util.urlEncode(order[1])
    end

    return string.format("%s/eapi/user/book/downloaded?page=%d&limit=%d%s",base, page, limit, order_str)
end

function Config.getFavoriteBooksUrl(page, order)
    local base = Config.getBaseUrl()
    if not base then return nil end

    -- Default to save date, newest first: a favourites list is most useful showing what you saved
    -- most recently. order=date sorts by the book's own date, which is unrelated to save order and
    -- is what made the list look wrongly sorted. The API's "A" suffix marks ascending (titleA,
    -- filesizeA), so bare "saved_date" is descending = most recent first, as getFavoriteBookIdsUrl
    -- already uses.
    order = order or {"saved_date"}
    page = page or 1
    
    local limit = Config.SEARCH_RESULTS_LIMIT
    local order_str = ""
    if #order > 0 then
        order_str = "&order=" .. util.urlEncode(order[1])
    end

    return string.format("%s/eapi/user/book/saved?page=%d&limit=%d%s",base, page, limit, order_str)
end

function Config.getBooklistsUrl()
    local base = Config.getBaseUrl()
    if not base then return nil end
    return base .. "/papi/booklist/current-user/0"
end

function Config.getBooklistBooksUrl(booklist_id, page)
    local base = Config.getBaseUrl()
    local id = tonumber(booklist_id)
    if not (base and id) then return nil end
    return string.format("%s/papi/booklist/%d/get-books/%d", base, id, page or 1)
end

function Config.getFavoriteBookIdsUrl()
    local base = Config.getBaseUrl()
    local limit = Config.SEARCH_RESULTS_LIMIT
    return base and (base .. "/eapi/user/book/saved?order=saved_date&page=1&limit=" .. limit)
end

function Config.getDeleteDownloadedUrl(book_id)
    local base = Config.getBaseUrl()
    if not base or not book_id then return nil end
    return base .. string.format("/eapi/user/book/%s/delete", book_id)
end

function Config.getUnFavoriteUrl(book_id)
    local base = Config.getBaseUrl()
    if not base or not book_id then return nil end
    return base .. string.format("/eapi/user/book/%s/unsave", book_id)
end

function Config.getFavoriteUrl(book_id)
    local base = Config.getBaseUrl()
    if not base or not book_id then return nil end
    return base .. string.format("/eapi/user/book/%s/save", book_id)
end

function Config.getDownloadQuotaUrl()
    local base = Config.getBaseUrl()
    return base and (base .. "/eapi/user/profile")
end

function Config.getRecommendedBooksUrl()
    local base = Config.getBaseUrl()
    if not base then return nil end
    return base .. "/eapi/user/book/recommended"
end

function Config.getMostPopularBooksUrl()
    local base = Config.getBaseUrl()
    if not base then return nil end
    return base .. "/eapi/book/most-popular"
end

return Config
