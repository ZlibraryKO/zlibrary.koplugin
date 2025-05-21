local util = require("frontend.util")
local DataStorage = require("datastorage")

local Config = {}

Config.SETTINGS_BASE_URL_KEY = "zlibrary_base_url"
Config.SETTINGS_USERNAME_KEY = "zlibrary_username"
Config.SETTINGS_PASSWORD_KEY = "zlibrary_password"
Config.SETTINGS_USER_ID_KEY = "zlib_user_id"
Config.SETTINGS_USER_KEY_KEY = "zlib_user_key"
Config.SETTINGS_SEARCH_LANGUAGES_KEY = "zlibrary_search_languages"
Config.SETTINGS_SEARCH_EXTENSIONS_KEY = "zlibrary_search_extensions"
Config.SETTINGS_DOWNLOAD_DIR_KEY = "zlibrary_download_dir"

Config.DEFAULT_DOWNLOAD_DIR_FALLBACK = DataStorage:getDataDir() .. "/downloads"
Config.REQUEST_TIMEOUT = 15 -- seconds
Config.SEARCH_RESULTS_LIMIT = 30

Config.SUPPORTED_LANGUAGES = {
    { name = "Arabic", value = "arabic" },
    { name = "Armenian", value = "armenian" },
    { name = "Azerbaijani", value = "azerbaijani" },
    { name = "Bengali", value = "bengali" },
    { name = "Chinese", value = "chinese" },
    { name = "Dutch", value = "dutch" },
    { name = "English", value = "english" },
    { name = "French", value = "french" },
    { name = "Georgian", value = "georgian" },
    { name = "German", value = "german" },
    { name = "Greek", value = "greek" },
    { name = "Hindi", value = "hindi" },
    { name = "Indonesian", value = "indonesian" },
    { name = "Italian", value = "italian" },
    { name = "Japanese", value = "japanese" },
    { name = "Korean", value = "korean" },
    { name = "Malaysian", value = "malaysian" },
    { name = "Pashto", value = "pashto" },
    { name = "Polish", value = "polish" },
    { name = "Portuguese", value = "portuguese" },
    { name = "Russian", value = "russian" },
    { name = "Serbian", value = "serbian" },
    { name = "Spanish", value = "spanish" },
    { name = "Telugu", value = "telugu" },
    { name = "Thai", value = "thai" },
    { name = "Traditional Chinese", value = "traditional chinese" },
    { name = "Turkish", value = "turkish" },
    { name = "Ukrainian", value = "ukrainian" },
    { name = "Urdu", value = "urdu" },
    { name = "Vietnamese", value = "vietnamese" },
}

Config.SUPPORTED_EXTENSIONS = {
    { name = "AZW", value = "AZW" },
    { name = "AZW3", value = "AZW3" },
    { name = "CBZ", value = "CBZ" },
    { name = "DJV", value = "DJV" },
    { name = "DJVU", value = "DJVU" },
    { name = "EPUB", value = "EPUB" },
    { name = "FB2", value = "FB2" },
    { name = "LIT", value = "LIT" },
    { name = "MOBI", value = "MOBI" },
    { name = "PDF", value = "PDF" },
    { name = "RTF", value = "RTF" },
    { name = "TXT", value = "TXT" },
}

function Config.getBaseUrl()
    local configured_url = Config.getSetting(Config.SETTINGS_BASE_URL_KEY)
    if configured_url == nil or configured_url == "" then
        return nil
    end
    return configured_url
end

function Config.setAndValidateBaseUrl(url_string)
    if not url_string or url_string == "" then
        return false, "Error: URL cannot be empty."
    end

    url_string = util.trim(url_string)

    if not (string.sub(url_string, 1, 8) == "https://" or string.sub(url_string, 1, 7) == "http://") then
        url_string = "https://" .. url_string
    end

    if not string.find(url_string, "%.") then
        return false, "Error: URL must include a valid domain name (e.g., example.com)."
    end

    if string.sub(url_string, -1) == "/" then
        url_string = string.sub(url_string, 1, -2)
    end

    Config.saveSetting(Config.SETTINGS_BASE_URL_KEY, url_string)
    return true, nil
end

function Config.getRpcUrl()
    local base = Config.getBaseUrl()
    if not base then return nil end
    return base .. "/rpc.php"
end

function Config.getSearchUrl(query)
    local base = Config.getBaseUrl()
    if not base then return nil end
    return base .. "/eapi/book/search"
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

function Config.getSetting(key, default)
    return G_reader_settings:readSetting(key) or default
end

function Config.saveSetting(key, value)
    if type(value) == "string" then
        G_reader_settings:saveSetting(key, util.trim(value))
    else
        G_reader_settings:saveSetting(key, value)
    end
end

function Config.deleteSetting(key)
    G_reader_settings:delSetting(key)
end

function Config.getCredentials()
    return {
        username = Config.getSetting(Config.SETTINGS_USERNAME_KEY),
        password = Config.getSetting(Config.SETTINGS_PASSWORD_KEY),
    }
end

function Config.getUserSession()
    return {
        user_id = Config.getSetting(Config.SETTINGS_USER_ID_KEY),
        user_key = Config.getSetting(Config.SETTINGS_USER_KEY_KEY),
    }
end

function Config.saveUserSession(user_id, user_key)
    Config.saveSetting(Config.SETTINGS_USER_ID_KEY, user_id)
    Config.saveSetting(Config.SETTINGS_USER_KEY_KEY, user_key)
end

function Config.clearUserSession()
    Config.deleteSetting(Config.SETTINGS_USER_ID_KEY)
    Config.deleteSetting(Config.SETTINGS_USER_KEY_KEY)
end

function Config.getDownloadDir()
    return Config.getSetting(Config.SETTINGS_DOWNLOAD_DIR_KEY, Config.DEFAULT_DOWNLOAD_DIR_FALLBACK)
end

function Config.getSearchLanguages()
    return Config.getSetting(Config.SETTINGS_SEARCH_LANGUAGES_KEY, {})
end

function Config.getSearchExtensions()
    return Config.getSetting(Config.SETTINGS_SEARCH_EXTENSIONS_KEY, {})
end

return Config
