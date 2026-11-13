-- The reader's account: credentials typed in or set by zlibrary_credentials.lua, the session they
-- produce, and the caches and history that belong to one account. Part of the Config facade; see
-- config_core.lua.

local logger = require("logger")
local LuaSettings = require("luasettings")
local SearchHistory = require("zlibrary.search_history")
local Config = require("zlibrary.config_core")

function Config.loadCredentialsFromFile(plugin_path)
    -- This flag lives on the module table, which survives plugin re-instantiation, so each load
    -- attempt has to start clean: a file that no longer sets credentials must not keep reporting
    -- that it does because some earlier load in this session set them.
    Config._credentials_from_file = false
    Config._session_from_file = false
    local cred_file_path = plugin_path .. Config.CREDENTIALS_FILENAME
    local creds = LuaSettings:open(cred_file_path)
    if not creds.data or not next(creds.data) then
        logger.info(Config.CREDENTIALS_FILENAME .. " is undefined. Using UI settings if available.")
        return
    end
    logger.info("Successfully loaded credentials from " .. Config.CREDENTIALS_FILENAME)

    local base_url = creds:readSetting("baseUrl")
    if base_url then
        local success, err_msg = Config.setAndValidateBaseUrl(base_url)
        if success then
            logger.info("Overriding Base URL from " .. Config.CREDENTIALS_FILENAME)
        else
            logger.warn("Invalid Base URL from " .. Config.CREDENTIALS_FILENAME .. ": " .. (err_msg or "Unknown error"))
        end
    end
    local identity = creds:readSetting("username") or creds:readSetting("email")
    if identity then
        Config.saveSetting(Config.SETTINGS_USERNAME_KEY, identity)
        Config._credentials_from_file = true
        logger.info("Overriding Identity (Username/Email) from " .. Config.CREDENTIALS_FILENAME)
    end
    local password = creds:readSetting("password")
    if password then
        Config.saveSetting(Config.SETTINGS_PASSWORD_KEY, password)
        Config._credentials_from_file = true
        logger.info("Overriding Password from " .. Config.CREDENTIALS_FILENAME)
    end

    -- A session, for when signing in is not possible at all. Both of Z-library's login endpoints
    -- have spent weeks refusing valid credentials (1.0.48, #239), and there is nothing the plugin
    -- can do about that from here -- but a reader who can still sign in through a browser can copy
    -- the session out of it (the remix_userid and remix_userkey cookies) and keep reading. The
    -- sessions have not been seen to expire, so one pasted here goes on working.
    --
    -- Both halves or neither: the API sends them as a pair, and a key without an id authenticates
    -- nothing while looking like it should. Stored as strings, the way a sign-in stores them, since
    -- a hand-written file is as likely to give the id as a number.
    local user_id = creds:readSetting("userId") or creds:readSetting("remixUserid")
    local user_key = creds:readSetting("userKey") or creds:readSetting("remixUserkey")
    if user_id and user_key then
        Config.saveUserSession(tostring(user_id), tostring(user_key))
        Config._session_from_file = true
        logger.info("Overriding User Session from " .. Config.CREDENTIALS_FILENAME)
    elseif user_id or user_key then
        logger.warn(string.format("%s sets only %s -- a session needs both userId and userKey, ignoring it",
            Config.CREDENTIALS_FILENAME, user_id and "userId" or "userKey"))
    end
end

-- Whether the credentials in the settings came from zlibrary_credentials.lua rather than from
-- the user typing them. It matters when clearing: this file is re-read on every init, which
-- happens per UI, so anything it sets comes straight back and telling the user their
-- credentials are gone would be a lie.
function Config.credentialsComeFromFile()
    return Config._credentials_from_file == true
end

-- The same, for a session the file sets directly. Separate from the flag above because the two are
-- set independently: a file can carry a session and no password, which is the whole point of it.
function Config.sessionComesFromFile()
    return Config._session_from_file == true
end

function Config.getCredentials()
    return {
        username = Config.getSetting(Config.SETTINGS_USERNAME_KEY),
        password = Config.getSetting(Config.SETTINGS_PASSWORD_KEY),
    }
end

-- Whether an account has been set up at all. Operations that need one can ask before making a
-- request that cannot succeed, rather than waiting for the server to say "Please login" -- which
-- costs a round trip and depends on the server phrasing it that way.
--
-- Deliberately not consulted for search: the search endpoint answers without credentials, and
-- being able to browse before signing in is worth keeping.
function Config.hasCredentials()
    local email = Config.getSetting(Config.SETTINGS_USERNAME_KEY)
    local password = Config.getSetting(Config.SETTINGS_PASSWORD_KEY)
    if email ~= nil and email ~= "" and password ~= nil and password ~= "" then
        return true
    end
    -- A session on its own is an account too. zlibrary_credentials.lua can set one directly, for
    -- readers the login endpoints refuse, and it authenticates every request that needs an account
    -- without an email or password stored anywhere. Without this the gates that call this would
    -- send those readers to a sign-in they have no way to complete.
    return Config.hasUserSession()
end

-- Whether a usable session is stored, whoever put it there: a sign-in, or zlibrary_credentials.lua.
-- Both halves are required, since the API sends them as a pair.
function Config.hasUserSession()
    local session = Config.getUserSession()
    return session.user_id ~= nil and session.user_id ~= ""
        and session.user_key ~= nil and session.user_key ~= ""
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

-- Drop everything cached that belongs to one account. Signing out while this survives leaves the
-- next person looking at the previous reader's books.
--
-- What is deliberately kept: "popular" and its per-language/format variants are fetched unauthenticated
-- (requires_auth = false) and are the same list for everybody; api_real_url and the domain caches
-- describe the server, not the reader; and the book-info and cover caches hold public metadata. Favourite state is not among
-- them -- it lives in favorite_book_ids below. View settings need no keeping: they are a device
-- preference and live in the persistent settings file, not in any of these caches.
function Config.clearPersonalCaches()
    local runtime = Config.getConfigRuntimeCache()
    runtime:remove("download_quota_status")
    runtime:remove("favorite_book_ids")

    local multi_search = Config.getMultiSearchCache()
    for _, key in ipairs({ "recommended", "favorites", "downloaded", "booklists" }) do
        multi_search:remove(key)
    end
    multi_search:removePrefix("booklist_")

    Config.clearSearchHistory()
end

function Config.getSearchHistory()
    return Config.getSetting(Config.SETTINGS_SEARCH_HISTORY_KEY, {})
end

function Config.addSearchHistory(query)
    Config.saveSetting(Config.SETTINGS_SEARCH_HISTORY_KEY, SearchHistory.add(Config.getSearchHistory(), query))
end

function Config.removeSearchHistory(query)
    Config.saveSetting(Config.SETTINGS_SEARCH_HISTORY_KEY, SearchHistory.remove(Config.getSearchHistory(), query))
end

function Config.clearSearchHistory()
    Config.deleteSetting(Config.SETTINGS_SEARCH_HISTORY_KEY)
end

-- Forget the account entirely: the stored username and password, the session tokens, and
-- everything cached on their behalf. Clearing the session alone leaves the credentials behind,
-- and the plugin simply signs back in with them on the next request.
function Config.clearCredentials()
    Config.deleteSetting(Config.SETTINGS_USERNAME_KEY)
    Config.deleteSetting(Config.SETTINGS_PASSWORD_KEY)
    Config.clearUserSession()
    Config.clearPersonalCaches()
end

return Config
