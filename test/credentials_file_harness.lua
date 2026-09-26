-- What zlibrary_credentials.lua can set, and what the plugin makes of it.
--
-- The file has always been able to supply a base URL, an email and a password. It can now also
-- supply a session (userId + userKey), for the situation this plugin keeps landing in: both of
-- Z-library's login endpoints have spent weeks refusing valid credentials (1.0.48, #239), and a
-- reader who can still sign in through a browser can copy the session out of it and go on reading.
-- Z-library's sessions have not been seen to expire.
--
-- For that to be worth anything, a session on its own has to count as having an account: the gates
-- in main.lua, download.lua and preloader.lua all ask Config.hasCredentials() before a request that
-- needs one, and a reader with a pasted session has no password for them to find.
--
-- Drives the real zlibrary.config against a LuaSettings double, the way base_url_harness does: the
-- behaviour under test is what these functions do to the settings, and an extracted copy would only
-- assert against itself.

local PLUGIN = assert(arg[1], "usage: luajit credentials_file_harness.lua <plugin-root> <luasocket-src>")
local LUASOCKET = assert(arg[2], "usage: luajit credentials_file_harness.lua <plugin-root> <luasocket-src>")

package.path = PLUGIN .. "/?.lua;" .. package.path
local support = dofile(PLUGIN .. "/test/support.lua")
support.preload_socket(LUASOCKET)
support.preload_koreader_stubs()
local r = support.reporter()

-- The real trim: saveSetting uses it, and it is what strips a newline off a pasted cookie.
package.preload["util"] = function()
    return {
        trim = function(s) return s:match("^%s*(.-)%s*$") end,
        urlEncode = function(s) return s end,
    }
end

local function make_settings(data)
    local s = { data = data or {}, flushes = 0 }
    function s:readSetting(key, default)
        local v = self.data[key]
        if v == nil then return default end
        return v
    end
    function s:saveSetting(key, value) self.data[key] = value return self end
    function s:delSetting(key) self.data[key] = nil return self end
    function s:flush() self.flushes = self.flushes + 1 return self end
    return s
end

-- What the credentials file holds for the next load; swapped between sections.
local creds_data = {}
local plugin_settings = make_settings()
package.preload["datastorage"] = function()
    return { getSettingsDir = function() return "/nonexistent-test-dir" end }
end
package.preload["luasettings"] = function()
    return { open = function(_, path)
        if string.find(path, "zlibrary_credentials%.lua$") then return make_settings(creds_data) end
        return plugin_settings
    end }
end
package.preload["zlibrary.cache"] = function()
    return { new = function()
        local store = {}
        return {
            get = function(_, k) return store[k] end,
            insert = function(_, k, v) store[k] = v return true end,
            remove = function(_, k) store[k] = nil return true end,
            clear = function() store = {} return true end,
        }
    end }
end
G_reader_settings = make_settings({ home_dir = "/home" })

local Config = require("zlibrary.config")

-- Each load starts from an empty settings store, so one section cannot pass on what an earlier one
-- wrote -- which is also how a device that has never been signed in starts.
local function load_with(data)
    creds_data = data
    plugin_settings.data = {}
    Config.loadCredentialsFromFile("/plugin/")
end

-- ---------------------------------------------------------------- a session from the file
load_with{ userId = "21699629", userKey = "f34263e7cd15732f40dcb9850f8c6cef" }
local session = Config.getUserSession()
r.check("userId and userKey become the stored session",
        session.user_id == "21699629" and session.user_key == "f34263e7cd15732f40dcb9850f8c6cef",
        "id=" .. tostring(session.user_id) .. " key=" .. tostring(session.user_key))
r.check("a session with no email or password still counts as having an account",
        Config.hasCredentials() == true,
        "hasCredentials() is false, so every gate would prompt for a sign-in that cannot be done")
r.check("and the plugin knows the session came from the file",
        Config.sessionComesFromFile() == true and Config.credentialsComeFromFile() == false,
        "session=" .. tostring(Config.sessionComesFromFile())
            .. " credentials=" .. tostring(Config.credentialsComeFromFile()))

-- The cookies are copied by hand out of a browser, so they arrive however the reader pasted them.
load_with{ userId = 21699629, userKey = "  f34263e7cd15732f40dcb9850f8c6cef\n" }
session = Config.getUserSession()
r.check("a numeric id is stored as a string, the way a sign-in stores it",
        session.user_id == "21699629", "id = " .. tostring(session.user_id)
            .. " (" .. type(session.user_id) .. ")")
r.check("whitespace around a pasted key is trimmed",
        session.user_key == "f34263e7cd15732f40dcb9850f8c6cef",
        "key = [" .. tostring(session.user_key) .. "]")

-- ---------------------------------------------------------------- half a session is no session
-- The API sends the two together and neither half authenticates on its own, so a file that sets one
-- must not leave a session that looks usable and is not.
load_with{ userKey = "f34263e7cd15732f40dcb9850f8c6cef" }
session = Config.getUserSession()
r.check("a key without an id sets no session",
        (session.user_id == nil or session.user_id == "") and Config.hasUserSession() == false,
        "id = " .. tostring(session.user_id))
r.check("and does not make the plugin think it has an account",
        Config.hasCredentials() == false and Config.sessionComesFromFile() == false,
        "hasCredentials=" .. tostring(Config.hasCredentials()))

load_with{ userId = "21699629" }
r.check("an id without a key sets no session either", Config.hasUserSession() == false,
        "key = " .. tostring(Config.getUserSession().user_key))

-- ---------------------------------------------------------------- the browser's own cookie names
load_with{ remixUserid = "21699629", remixUserkey = "f34263e7cd15732f40dcb9850f8c6cef" }
r.check("remixUserid/remixUserkey work too, since those are the cookie names being copied",
        Config.hasUserSession() == true, "session not set from the cookie-named keys")

-- ---------------------------------------------------------------- what the file used to do
load_with{ email = "reader@example.com", password = "correct horse" }
r.check("an email and password still set the credentials",
        Config.getSetting(Config.SETTINGS_USERNAME_KEY) == "reader@example.com"
            and Config.getSetting(Config.SETTINGS_PASSWORD_KEY) == "correct horse"
            and Config.credentialsComeFromFile() == true,
        "credentials did not come through")
r.check("and set no session", Config.hasUserSession() == false, "a session appeared from nowhere")

-- ---------------------------------------------------------------- nothing set
-- The flags live on the module table, which survives plugin re-instantiation, so a file that stops
-- setting a session must stop reporting one -- otherwise "Clear user session" keeps claiming the
-- file will put it back.
load_with{}
r.check("an empty file leaves no account behind",
        Config.hasCredentials() == false and Config.hasUserSession() == false,
        "hasCredentials=" .. tostring(Config.hasCredentials()))
r.check("and clears the from-file flags set by an earlier load",
        Config.sessionComesFromFile() == false and Config.credentialsComeFromFile() == false,
        "session=" .. tostring(Config.sessionComesFromFile())
            .. " credentials=" .. tostring(Config.credentialsComeFromFile()))

-- ---------------------------------------------------------------- the gates that depend on this
-- Asserted against the source because the cost of getting it wrong is invisible here: these call
-- sites are what turn a pasted session into a usable plugin.
local function read(path) local fh = assert(io.open(path)); local s = fh:read("*a"); fh:close(); return s end
r.check("the credentials template documents the session fields",
        read(PLUGIN .. "/zlibrary_credentials.lua"):find("userKey", 1, true) ~= nil,
        "zlibrary_credentials.lua no longer shows userId/userKey")
r.check("clearing the session warns when the file will set it again",
        read(PLUGIN .. "/main.lua"):find("Config.sessionComesFromFile()", 1, true) ~= nil,
        "main.lua reports a cleared session that comes straight back")

r.finish()
