-- Downloading a URL straight into a file: covers, and the OTA update archive.
--
-- The sink closes the file handle when it receives its terminating chunk, and only then. A request
-- that fails at connect time never calls the sink at all, so the handle has to be closed by hand
-- before the partial file is removed -- os.remove on a still-open file is what the OTA download
-- used to do. A failure also has to hand back the HTTP status when there is one: the cover preloader
-- stops retrying a book on 404 and 410.
--
-- Drives the real Api.downloadToFile, and the Api.downloadBookCover that calls it, out of
-- zlibrary/api_downloads.lua with io, os and the request stubbed, so nothing is written anywhere.
-- Ota.downloadUpdate's call is checked in ota_update_harness.

local PLUGIN = assert(arg[1], "usage: luajit file_download_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local URL = "https://example.org/cover.jpg"
local PATH = "/cache/covers/abc.jpg.tmp"

local rig
local function reset(response, open_fails)
    rig = { response = response, open_fails = open_fails, events = {}, requests = {} }
end

local env = {
    type = type, tostring = tostring, string = string, pcall = pcall,
    T = function(s) return s end,
    -- Only used to keep queries out of the log; log_redaction_harness checks what it does.
    _loggableUrl = function(url) return tostring(url) end,
    logger = { info = function() end, warn = function() end, err = function() end, dbg = function() end },
    Config = {
        getUserAgent = function() return "UA" end,
        getCoverTimeout = function() return { 5, 10 } end,
    },
    socketutil = { file_sink = function(f) return { sink_for = f } end },
    io = {
        open = function(path, mode)
            table.insert(rig.events, "open " .. path .. " " .. mode)
            if rig.open_fails then return nil, "Permission denied" end
            return { close = function() table.insert(rig.events, "close") end }
        end,
    },
    os = {
        remove = function(path)
            table.insert(rig.events, "remove " .. path)
            return true
        end,
    },
}
env.Api = {
    makeHttpRequest = function(options)
        table.insert(rig.requests, options)
        return rig.response
    end,
}

local block = support.extract_block(PLUGIN .. "/zlibrary/api_downloads.lua",
    "(\nfunction Api%.downloadToFile%(.-\nfunction Api%.downloadBookCover%(.-\nend\n)")
local chunk = assert(loadstring(block, "=downloadToFile"))
setfenv(chunk, env)
chunk()

local HEADERS = { ["User-Agent"] = "Given-UA" }
local TIMEOUT = { 15, -1 }

local function download(response, open_fails)
    reset(response, open_fails)
    return env.Api.downloadToFile(URL, PATH, HEADERS, TIMEOUT)
end

local function events() return table.concat(rig.events, ", ") end

-- ---------------------------------------------------------------- the file cannot be opened
do
    local result = download({ status_code = 200 }, true)
    r.check("an unopenable file is an error", result.error ~= nil and not result.success, result.error)
    r.check("an unopenable file makes no request", #rig.requests == 0)
    r.check("an unopenable file removes nothing", #rig.events == 1, events())
end

-- ---------------------------------------------------------------- connect-time failure
do
    local result = download({ error = "connection refused" })
    r.check("a connect-time failure is an error", result.error ~= nil and not result.success)
    r.check("a connect-time failure closes the handle before removing the file",
            rig.events[2] == "close" and rig.events[3] == "remove " .. PATH and #rig.events == 3, events())
    r.check("a connect-time failure has no status", result.status_code == nil)
end

-- ---------------------------------------------------------------- HTTP status errors
do
    local result = download({ status_code = 404, headers = {} })
    r.check("a 404 is an error", result.error ~= nil and not result.success)
    r.check("a 404 closes the handle before removing the file",
            rig.events[2] == "close" and rig.events[3] == "remove " .. PATH and #rig.events == 3, events())
    r.check("a 404 hands back its status", result.status_code == 404, tostring(result.status_code))
end

do
    local result = download({ error = "HTTP Error: 410", status_code = 410, headers = {} })
    r.check("a request error with a status is an error", result.error ~= nil and not result.success)
    r.check("a request error with a status removes the file",
            rig.events[2] == "close" and rig.events[3] == "remove " .. PATH, events())
    r.check("a request error with a status hands it back", result.status_code == 410,
            tostring(result.status_code))
end

-- ---------------------------------------------------------------- success
do
    local result = download({ status_code = 200, headers = {} })
    r.check("a 200 is a success", result.success == true and result.error == nil)
    r.check("a 200 removes nothing", #rig.events == 1, events())
end

-- ---------------------------------------------------------------- the request itself
do
    download({ status_code = 200, headers = {} })
    local req = rig.requests[1] or {}
    r.check("the request is a GET of the URL", req.url == URL and req.method == "GET")
    r.check("the request writes into the opened file", type(req.sink) == "table" and req.sink.sink_for ~= nil)
    r.check("the request carries the given headers", req.headers == HEADERS)
    r.check("the request uses the given timeout", req.timeout == TIMEOUT)
    r.check("the request follows redirects", req.redirect == true)
end

-- ---------------------------------------------------------------- covers
do
    reset({ status_code = 404, headers = {} })
    local result = env.Api.downloadBookCover(URL, PATH)
    local req = rig.requests[1] or {}
    r.check("a cover is a GET of its URL into its path",
            req.url == URL and rig.events[1] == "open " .. PATH .. " wb", events())
    r.check("a cover carries the plugin's User-Agent", req.headers and req.headers["User-Agent"] == "UA")
    r.check("a cover uses the cover timeout",
            type(req.timeout) == "table" and req.timeout[1] == 5 and req.timeout[2] == 10)
    r.check("a cover failure hands back the status", result.status_code == 404 and not result.success)
end

r.finish()
