-- Does zlibrary.api still expose exactly what it did before it was split into parts?
--
-- api.lua was one 2,182-line module. It is now a facade over api_core, api_transport, api_login,
-- api_books, api_downloads, api_account and api_mirrors, which all fill the one Api table, with
-- the private helpers they share in api_shared (deliberately not on Api). Seven modules call
-- Api.<name> and none of them changed, so the split is only safe if every name is still there
-- with the same kind of value -- and no internal leaked onto the table.
--
-- The list below was recorded from the real, unsplit api.lua on 2026-11-10 (33 fields, 29 of them
-- functions). Unlike config_surface_harness there is no allowed extra. Added since: downloadToFile
-- (2026-11-11, shared by the cover and OTA downloads).

local PLUGIN = assert(arg[1], "usage: luajit api_surface_harness.lua <plugin-root> <luasocket-src>")
local LUASOCKET = assert(arg[2], "usage: luajit api_surface_harness.lua <plugin-root> <luasocket-src>")

package.path = PLUGIN .. "/?.lua;" .. package.path
local support = dofile(PLUGIN .. "/test/support.lua")
support.preload_socket(LUASOCKET)
support.preload_koreader_stubs()
local r = support.reporter()

-- Nothing in api.lua reads Config, json or the transport at load time; the module only has to
-- resolve its requires for its table to be inspected.
package.preload["zlibrary.config"] = function() return {} end
package.preload["json"] = function() return { decode = { simple = {} } } end
package.preload["socket.http"] = function() return { request = function() end } end

local Api = require("zlibrary.api")

local EXPECTED = {
    "BLOCKED_TEXT:string",
    "CREDENTIALS_REJECTED_TEXT:string",
    "DNS_ERROR_TEXT:string",
    "DOWNLOAD_LIMIT_HTML_TEXT:string",
    "LOGIN_ENDPOINTS:table",
    "deleteDownloadedBook:function",
    "discardDownloadTempFile:function",
    "downloadBook:function",
    "downloadBookCover:function",
    "downloadToFile:function",
    "favoriteBook:function",
    "fetchDynamicDomains:function",
    "getBookComments:function",
    "getBookDetails:function",
    "getBooklistBooks:function",
    "getBooklists:function",
    "getDownloadLink:function",
    "getDownloadQuotaStatus:function",
    "getDownloadTempPath:function",
    "getDownloadedBooks:function",
    "getFavoriteBookIds:function",
    "getFavoriteBooks:function",
    "getMostPopularBooks:function",
    "getRecommendedBooks:function",
    "getSimilarBooks:function",
    "healthCheck:function",
    "isAuthenticationError:function",
    "isBlockedError:function",
    "isCredentialRejection:function",
    "isRateLimited:function",
    "loggableUrl:function",
    "login:function",
    "makeHttpRequest:function",
    "search:function",
    "unfavoriteBook:function",
    "usableCoverUrl:function",
}

local actual = {}
for k, v in pairs(Api) do actual[k .. ":" .. type(v)] = true end
local expected = {}
for _, entry in ipairs(EXPECTED) do expected[entry] = true end

local missing, extra = {}, {}
for entry in pairs(expected) do if not actual[entry] then missing[#missing + 1] = entry end end
for entry in pairs(actual) do if not expected[entry] then extra[#extra + 1] = entry end end
table.sort(missing)
table.sort(extra)

r.check(string.format("all %d recorded Api fields are still there, with the same type", #EXPECTED),
        #missing == 0, "missing: " .. table.concat(missing, ", "))
r.check("and nothing was added -- no shared helper leaked onto Api",
        #extra == 0, "extra: " .. table.concat(extra, ", "))

r.finish()
