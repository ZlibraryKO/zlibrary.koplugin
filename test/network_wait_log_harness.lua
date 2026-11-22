-- Every action that waits for Wi-Fi says so in the log, and says so again when it re-runs.
--
-- NetworkMgr:willRerunWhenOnline turns Wi-Fi on and calls the action again once connected. When
-- KOReader drops that re-run instead (a failed scan, a connection attempt it thinks is still in
-- progress), nothing is shown and, without these lines, nothing is logged either: most actions
-- write nothing until their request finishes. With them, a dropped re-run is a "waiting" line
-- with no "re-running" after it. Checked on every call site in main.lua and zlibrary/*.lua, so a
-- new one cannot be added without them; and run for real on the search, which must keep the
-- query itself out of the info log.

local PLUGIN = assert(arg[1], "usage: luajit network_wait_log_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local function read(path)
    local fh = assert(io.open(path))
    local s = fh:read("*a")
    fh:close()
    return s
end

local files = { "main.lua" }
local ls = assert(io.popen('ls "' .. PLUGIN .. '/zlibrary"'))
for f in ls:lines() do
    if f:match("%.lua$") then files[#files + 1] = "zlibrary/" .. f end
end
ls:close()

-- ---------------------------------------------------------------- every call site
local sites = 0
for _, rel in ipairs(files) do
    local src = read(PLUGIN .. "/" .. rel)
    local pos = 1
    while true do
        local s = src:find("NetworkMgr:willRerunWhenOnline(function()", pos, true)
        if not s then break end
        sites = sites + 1
        local line = select(2, src:sub(1, s):gsub("\n", "")) + 1
        -- The closure runs to "end) then"; the branch taken while waiting runs to its "return".
        local closure_end = src:find("end) then", s, true)
        local closure = closure_end and src:sub(s, closure_end) or ""
        local branch = closure_end and src:sub(closure_end, (src:find("return", closure_end, true) or closure_end)) or ""
        local where = string.format("%s:%d", rel, line)
        r.check(where .. " logs when it re-runs", closure:find("re-running", 1, true) ~= nil,
                "the re-run is silent, so a dropped one cannot be told from a finished one")
        r.check(where .. " logs that it is waiting", branch:find("waiting for the network", 1, true) ~= nil,
                "nothing records that the action was asked for at all")
        pos = s + 1
    end
end
r.check("found the call sites", sites >= 7, sites .. " found")

-- ---------------------------------------------------------------- the search, run for real
local logged = {}
local rerun
local env = {
    T = function(s) return s end,
    logger = {
        info = function(...) logged[#logged + 1] = table.concat({ ... }, " ") end,
        dbg = function() end, warn = function() end, err = function() end,
    },
    NetworkMgr = { willRerunWhenOnline = function(_, fn) rerun = fn; return true end },
}
local body = support.extract_block(PLUGIN .. "/zlibrary/plugin_search.lua",
    "(\nfunction Zlibrary:performSearch%(.-\n)end\n")
local chunk = assert(loadstring("local Zlibrary = {}\n" .. body .. "end\nreturn Zlibrary", "=performSearch"))
setfenv(chunk, env)
local Z = chunk()

local QUERY = "a very private query"
local reran_with
local plugin = setmetatable({ performSearch = function(_, q) reran_with = q end }, { __index = Z })
Z.performSearch(plugin, QUERY)
r.check("offline, the search logs that it is waiting",
        logged[1] ~= nil and logged[1]:find("waiting for the network", 1, true) ~= nil, tostring(logged[1]))
rerun()
r.check("and logs the re-run once the network is up",
        logged[2] ~= nil and logged[2]:find("re-running", 1, true) ~= nil, tostring(logged[2]))
r.check("and the re-run is the same search", reran_with == QUERY, tostring(reran_with))
local leaked = false
for _, line in ipairs(logged) do if line:find(QUERY, 1, true) then leaked = true end end
r.check("the query itself stays out of the info log", not leaked, "a search query was logged at info")

r.finish()
