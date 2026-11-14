-- Does anything credential-equivalent or private reach the log?
--
-- A resolved download link is signed in its query string, and whoever holds it can fetch the
-- file on the account that requested it. download.lua already stripped the query before logging
-- the link, but Api.downloadBook logged the same URL whole at info, again at warn when the quota
-- page came back, and every failure in Api.makeHttpRequest logged it at err. Search queries went
-- to the log at info too. crash.log is what readers attach to bug reports, so both now stay out
-- of it at the default level: URLs lose their query (Api.loggableUrl), the query moves to dbg.
--
-- Drives the real Api.makeHttpRequest, Api.downloadBook and Api.search with a recording logger
-- and a scripted transport, and fails on any line that carries the secret.

local PLUGIN = assert(arg[1], "usage: luajit log_redaction_harness.lua <plugin-root> <luasocket-src>")
local LUASOCKET = assert(arg[2], "usage: luajit log_redaction_harness.lua <plugin-root> <luasocket-src>")

package.path = PLUGIN .. "/?.lua;" .. package.path
local support = dofile(PLUGIN .. "/test/support.lua")
support.preload_socket(LUASOCKET)
support.preload_koreader_stubs()
local r = support.reporter()

local lines = {}
local function recorder(level)
    return function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        table.insert(lines, { level = level, text = table.concat(parts, " ") })
    end
end
package.preload["logger"] = function()
    return { dbg = recorder("dbg"), info = recorder("info"), warn = recorder("warn"), err = recorder("err") }
end
package.preload["zlibrary.config"] = function()
    return {
        setCacheRealUrl = function() end,
        getCacheRealUrl = function() return nil end,
        clearCacheRealUrlIfPinned = function() return false end,
        markMirrorBlocked = function() end,
        getUserAgent = function() return "UA" end,
        getDownloadTimeout = function() return { 15, -1 } end,
        getSearchTimeout = function() return { 15, 15 } end,
        getSearchUrl = function() return "https://mirror.example/eapi/book/search" end,
        SEARCH_RESULTS_LIMIT = 30,
    }
end
local socketutil_stub = {
    set_timeout = function() end,
    reset_timeout = function() end,
    table_sink = function(tbl)
        return function(chunk) if chunk then table.insert(tbl, chunk) end return 1 end
    end,
    file_sink = function(f)
        return function(chunk)
            if chunk then f:write(chunk) else f:close() end
            return 1
        end
    end,
}
package.preload["socketutil"] = function() return socketutil_stub end

local serve
package.preload["socket.http"] = function()
    return { request = function(p) return serve(p) end }
end
local Api = require("zlibrary.api")

local SECRET = "sig=S3CRET-TOKEN"
local SIGNED = "https://dl.example:8443/dl/12345/abc?" .. SECRET .. "&expires=999#frag"

local function leaks(needle, levels)
    local found = {}
    for _, line in ipairs(lines) do
        if (not levels or levels[line.level]) and line.text:find(needle, 1, true) then
            table.insert(found, line.level .. ": " .. line.text)
        end
    end
    return found
end

-- ---------------------------------------------------------------- the redactor itself
r.check("an absolute URL keeps scheme, host, port and path",
        Api.loggableUrl(SIGNED) == "https://dl.example:8443/dl/12345/abc", Api.loggableUrl(SIGNED))
r.check("a relative URL is cut at its query",
        Api.loggableUrl("/eapi/x?" .. SECRET) == "/eapi/x", Api.loggableUrl("/eapi/x?" .. SECRET))
r.check("a non-string is described, not raised on", Api.loggableUrl(nil) == "nil")

-- ---------------------------------------------------------------- every failure path of the transport
local scenarios = {
    { "a raised transport error", function() error("closed") end },
    { "a transport failure",      function() return nil, "connection refused" end },
    { "a 5xx answer",             function() return 1, 502, {}, "HTTP/1.1 502" end },
    { "a stall that is retried",  function() return nil, "timeout" end, { retry_on_stall = true } },
    { "a redirect loop",          function(p) return 1, 307, { location = p.url }, "HTTP/1.1 307" end },
    { "a redirect without Location", function() return 1, 302, {}, "HTTP/1.1 302" end },
}
for _, s in ipairs(scenarios) do
    lines = {}
    serve = s[2]
    local opts = { url = SIGNED, method = "GET", headers = {} }
    for k, v in pairs(s[3] or {}) do opts[k] = v end
    Api.makeHttpRequest(opts)
    local found = leaks(SECRET)
    r.check("the transport logs no signed query on " .. s[1], #found == 0, found[1])
    r.check("but still logs which host it was (" .. s[1] .. ")", #leaks("dl.example") > 0)
end

-- ---------------------------------------------------------------- the download itself
local tmpdir = os.tmpname()
os.remove(tmpdir)
assert(os.execute("mkdir -p '" .. tmpdir .. "'") == 0)
local target = tmpdir .. "/Book.epub"

for _, case in ipairs({
    { "a quota page", function(p)
        p.sink("<html>limit</html>"); p.sink(nil)
        return 1, 200, { ["content-type"] = "text/html" }, "HTTP/1.1 200"
    end },
    { "a good download", function(p)
        p.sink("PK\3\4book"); p.sink(nil)
        return 1, 200, { ["content-type"] = "application/epub+zip" }, "HTTP/1.1 200"
    end },
}) do
    lines = {}
    serve = case[2]
    Api.downloadBook(SIGNED, target, "1", "key", nil, nil)
    local found = leaks(SECRET)
    r.check("Api.downloadBook logs no signed query on " .. case[1], #found == 0, found[1])
end
os.remove(target)
os.remove(tmpdir)

-- ---------------------------------------------------------------- download.lua's own line
local download_src = assert(io.open(PLUGIN .. "/zlibrary/download.lua")):read("*a")
r.check("download.lua logs the download link through Api.loggableUrl",
        download_src:find("Api.loggableUrl(link_result.download_link)", 1, true) ~= nil)

-- ---------------------------------------------------------------- what was searched for
lines = {}
serve = function(p) p.sink('{"books":[]}') return 1, 200, {}, "HTTP/1.1 200" end
local QUERY = "a very private search"
Api.search(QUERY, nil, nil, {}, {}, {}, 1)
local found = leaks(QUERY, { info = true, warn = true, err = true })
r.check("the search query is not logged above dbg", #found == 0, found[1])
r.check("the search is still logged at info (page only)", #leaks("Api.search - START", { info = true }) == 1)

r.finish()
