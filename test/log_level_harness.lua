-- The plugin is quiet in crash.log unless debug logging is on.
--
-- KOReader writes info and above to crash.log by default, and the plugin used to log every
-- request's START and END, every successful fetch and three lines at each startup at info: about
-- a fifth of the whole log on a Kindle in daily use. Routine lines are dbg now: written only with
-- the plugin's own Detailed logging on (see log_detailed_harness) or KOReader's debug logging.
-- warn and err are unchanged. The "Zlibrary:network -" pair around a Wi-Fi wait was the last
-- exception; it went to dbg too (2026-11-22), so there is no plugin line at info at all. This fails
-- on any logger.info in main.lua or zlibrary/*.lua, so a new one has to be added here on purpose.

local PLUGIN = assert(arg[1], "usage: luajit log_level_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

-- Lines allowed at info, by the text they log.
local ALLOWED = {}

local files = { "main.lua" }
local ls = assert(io.popen('ls "' .. PLUGIN .. '/zlibrary"'))
for f in ls:lines() do
    if f:match("%.lua$") then files[#files + 1] = "zlibrary/" .. f end
end
ls:close()

local stray, allowed = {}, 0
for _, rel in ipairs(files) do
    -- log.lua is the one place that calls KOReader's logger.info by design: it is how Detailed
    -- logging writes dbg lines at info. log_detailed below checks it does that only when asked.
    if rel == "zlibrary/log.lua" then goto next_file end
    local n = 0
    for line in io.lines(PLUGIN .. "/" .. rel) do
        n = n + 1
        -- Any reference, not only a call: logger.info passed along as a function logs at info too.
        if line:find("logger%.info") and not line:match("^%s*%-%-") then
            local ok = false
            for _, a in ipairs(ALLOWED) do
                if line:find(a, 1, true) then ok = true end
            end
            if ok then allowed = allowed + 1 else stray[#stray + 1] = string.format("%s:%d", rel, n) end
        end
    end
    ::next_file::
end

r.check("nothing else logs at info", #stray == 0,
        #stray .. " line(s), first " .. tostring(stray[1]) .. " -- use logger.dbg, or add it to ALLOWED")
local wifi_dbg = 0
for _, rel in ipairs(files) do
    for line in io.lines(PLUGIN .. "/" .. rel) do
        if line:find('logger.dbg("Zlibrary:network - ', 1, true) then wifi_dbg = wifi_dbg + 1 end
    end
end
r.check("the Wi-Fi wait lines are at dbg", wifi_dbg >= 14, wifi_dbg .. " found")

r.finish()
