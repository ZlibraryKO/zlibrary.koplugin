-- Is a spent download quota recognised in every locale, not only English?
--
-- When the quota is gone the mirror answers the download itself with an HTML page, and
-- Api.downloadBook reports that as "Download limit reached or file is an HTML page" -- through
-- T(), so translated. Download.run then looked for the English literal in that message, which a
-- translated message never contains: outside English the quota notice never appeared, and the
-- raw message came up instead. The text is now Api.DOWNLOAD_LIMIT_HTML_TEXT and matched by value,
-- the way DNS_ERROR_TEXT and BLOCKED_TEXT already are.
--
-- Runs under a fake translation (every msgid upper-cased, so it no longer contains the English), so a match on the English
-- literal fails here exactly as it did on a device set to another language.

local PLUGIN = assert(arg[1], "usage: luajit download_limit_harness.lua <plugin-root> <luasocket-src>")
local LUASOCKET = assert(arg[2], "usage: luajit download_limit_harness.lua <plugin-root> <luasocket-src>")

package.path = PLUGIN .. "/?.lua;" .. package.path
local support = dofile(PLUGIN .. "/test/support.lua")
support.preload_socket(LUASOCKET)
support.preload_koreader_stubs()
local r = support.reporter()

local function translate(s) return "<" .. s:upper() .. ">" end
package.preload["zlibrary.gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return translate(s) end })
end

local Api = require("zlibrary.api_core")
local ENGLISH = "Download limit reached or file is an HTML page"

r.check("the download-limit text is exported, translated",
        Api.DOWNLOAD_LIMIT_HTML_TEXT == translate(ENGLISH), tostring(Api.DOWNLOAD_LIMIT_HTML_TEXT))

-- ---------------------------------------------------------------- what Api.downloadBook reports
local env = {
    type = type, tostring = tostring, string = string, pcall = pcall,
    T = translate,
    logger = { info = function() end, warn = function() end, err = function() end, dbg = function() end },
    Config = {
        getUserAgent = function() return "UA" end,
        getDownloadTimeout = function() return { 15, -1 } end,
    },
    socketutil = { file_sink = function() return function() return 1 end end },
    io = { open = function() return { close = function() end } end },
    os = { remove = function() return true end, rename = function() return true end },
    _sessionCookie = function() return nil end,
    _loggableUrl = function(u) return u end,
    Api = Api,
}
Api.getDownloadTempPath = function(p) return p .. ".downloading" end
Api.makeHttpRequest = function()
    return { status_code = 200, headers = { ["content-type"] = "text/html; charset=UTF-8" },
             bytes_received = 512 }
end
local block = support.extract_block(PLUGIN .. "/zlibrary/api_downloads.lua",
    "(\nfunction Api%.downloadBook%(.-\nend\n)\n")
local chunk = assert(loadstring(block, "=downloadBook"))
setfenv(chunk, env)
chunk()

local result = Api.downloadBook("https://dl.example/book?sig=secret", "/books/Book.epub", "1", "k")
r.check("an HTML answer to a download is reported with the exported text",
        result.success == false and result.error == Api.DOWNLOAD_LIMIT_HTML_TEXT, tostring(result.error))

-- ---------------------------------------------------------------- what Download.run recognises
-- The condition in on_error_download that picks the quota notice, compiled as written.
local cond = support.extract_block(PLUGIN .. "/zlibrary/download.lua",
    "\n%s*if (string%.find%(error_string, [^\n]-) then\n%s*Ui%.closeMessage%(loading_msg%)\n%s*Ui%.showErrorMessage%(T%(\"Download limit reached%.")
local function recognised(error_string)
    local f = assert(loadstring("return " .. cond, "=quota_condition"))
    setfenv(f, { string = string, Api = Api, T = translate, error_string = error_string })
    return f() ~= nil
end

r.check("the quota error is recognised in a translated locale", recognised(result.error), cond)
r.check("and with context around it", recognised("Error: " .. Api.DOWNLOAD_LIMIT_HTML_TEXT .. " (x)"))
r.check("a different error is not taken for the quota", not recognised(translate("HTTP Error") .. ": 500"))

r.finish()
