-- Does the discover channel's on_finish close the CURRENT run's loading message?
--
-- It used to close the first run's. Discovery.run builds a safe_close_loading_msg closure over
-- its own loading_msg upvalue and hands it to AsyncHelper:createChannel -- but createChannel
-- caches channels by name, so the argument only lands on the first invocation. Every later run
-- reused a channel whose on_finish still pointed at the first run's (long-dead) loading
-- message, and the current run's "Searching for working Z-library server..." survived the
-- drain/abort hook that was meant to close it. The fix re-points channel.on_finish on each
-- run; this harness drives the real Discovery.run twice and drains the channel.
--
-- The whole of run() is extracted, so the KOReader modules it touches are stubbed just far
-- enough to walk the non-interactive path: cached domains -> executeDiscovery ->
-- start_discover_task, with executeBatch recorded but never run.

local PLUGIN = assert(arg[1], "usage: luajit discovery_channel_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local rig = {
    channels = {},        -- AsyncHelper's name -> channel cache
    created = 0,          -- how often createChannel actually built one
    batches = 0,          -- executeBatch calls
    closed = {},          -- widgets handed to UIManager:close
    loading_seq = 0,      -- token generator for loading messages
}

local env = setmetatable({
    logger = { dbg = function() end, info = function() end, warn = function() end, err = function() end },
    NetworkMgr = {
        willRerunWhenOnline = function() return false end,
        isConnected = function() return true end,
    },
    AsyncHelper = {
        createChannel = function(_, name, max_workers, on_finish)
            if not rig.channels[name] then
                rig.created = rig.created + 1
                rig.channels[name] = {
                    name = name,
                    max_workers = max_workers,
                    on_finish = on_finish,
                    executeBatch = function() rig.batches = rig.batches + 1 end,
                    pushTask = function() end,
                    clearTasks = function() end,
                }
            end
            return rig.channels[name]
        end,
    },
    Cache = {
        new = function()
            return {
                -- A cached domain list, so run() goes straight to executeDiscovery.
                get = function(_, key) if key == "domains" then return { "seed.example" } end end,
                insert = function() end,
            }
        end,
    },
    Config = {
        getSeedUrls = function() return { { url = "http://seed.example", src = "X" } } end,
    },
    Api = {},
    Device = {},
    UIManager = {
        close = function(_, widget) table.insert(rig.closed, widget) end,
        nextTick = function() end,
    },
    Ui = {
        showLoadingMessage = function(text)
            rig.loading_seq = rig.loading_seq + 1
            return { id = rig.loading_seq, text = text }
        end,
        showInfoMessage = function() end,
        showErrorMessage = function() end,
    },
    T = function(s) return s end,
}, { __index = _G })

local body = support.extract_block(PLUGIN .. "/zlibrary/discovery.lua",
    "(\nfunction Discovery%.run%(.-\n)end\n")
local chunk = assert(loadstring("local Discovery = {}\n" .. body .. "end\nreturn Discovery", "=discovery_run"))
setfenv(chunk, env)
local Discovery = chunk()

-- Two non-interactive runs against the same plugin instance: the second must reuse the cached
-- channel but re-point its on_finish.
local plugin = {}
Discovery.run(plugin, false, nil)
local first_on_finish = plugin.discover_channel.on_finish
Discovery.run(plugin, false, nil)
local second_on_finish = plugin.discover_channel.on_finish

r.check("the channel is created once and cached by name", rig.created == 1,
        "created " .. rig.created .. " times")
r.check("both runs start a discovery batch", rig.batches == 2,
        "batches: " .. rig.batches)
r.check("the second run re-points on_finish at its own closer",
        first_on_finish ~= second_on_finish,
        "on_finish still belongs to the first run")

-- Drain the channel: the drain hook must close the SECOND run's loading message (id 2), not
-- the first run's (id 1).
plugin.discover_channel.on_finish(false)
r.check("draining closes exactly the current run's loading message",
        #rig.closed == 1 and rig.closed[1].id == 2,
        "closed ids: " .. table.concat((function()
            local ids = {}
            for _, w in ipairs(rig.closed) do table.insert(ids, w.id) end
            return ids
        end)(), ", "))

-- The closer is idempotent: a second drain after the message is gone closes nothing.
plugin.discover_channel.on_finish(false)
r.check("a second drain closes nothing", #rig.closed == 1,
        "closed " .. #rig.closed .. " widgets")

r.finish()
