-- Does asking for a channel again apply what you asked for?
--
-- AsyncHelper caches channels by name. It used to return the cached one and drop the caller's
-- arguments in silence, which matters because discovery asks for its channel on every run with an
-- on_finish that closes THAT run's loading message: the channel kept the first run's closure, so
-- a drain closed a widget that was already gone and left the current message on screen. Discovery
-- worked around it by reassigning the field by hand; the workaround is gone and createChannel
-- applies the arguments itself, so this pins the behaviour discovery_channel_harness now assumes.
--
-- createChannel and getChannel are extracted rather than required: async_helper pulls in the
-- widget and ffi stack, and the caching decision is all of what is under test here.

local PLUGIN = assert(arg[1], "usage: luajit channel_config_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local built = 0
local env = {
    string = string,
    logger = { dbg = function() end, warn = function() end, err = function() end, info = function() end },
    Channel = {
        new = function(_, name, max_workers, on_finish)
            built = built + 1
            return { name = name, max_workers = max_workers, on_finish = on_finish }
        end,
    },
}
env.AsyncHelper = { channels = {} }

for _, name in ipairs{ "createChannel", "getChannel" } do
    local block = support.extract_block(PLUGIN .. "/zlibrary/async_helper.lua",
        "(\nfunction AsyncHelper:" .. name .. "%(.-\nend\n)")
    local chunk = assert(loadstring(block, "=AsyncHelper:" .. name))
    setfenv(chunk, env)
    chunk()
end
local AsyncHelper = env.AsyncHelper

local first_closer = function() end
local second_closer = function() end

local one = AsyncHelper:createChannel("discovery", 3, first_closer)
r.check("the first call builds the channel it was asked for",
        built == 1 and one.max_workers == 3 and one.on_finish == first_closer,
        "workers=" .. tostring(one.max_workers))

local two = AsyncHelper:createChannel("discovery", 3, second_closer)
r.check("asking again returns the same channel", two == one and built == 1,
        built .. " channel(s) built for one name")
r.check("and re-points it at the closer this caller passed",
        two.on_finish == second_closer,
        "the channel kept an earlier run's on_finish, which closes a widget that is already gone")

AsyncHelper:createChannel("discovery", 5)
r.check("a new worker count is applied too", one.max_workers == 5,
        "workers = " .. tostring(one.max_workers))
r.check("and omitting the closer leaves the one already set",
        one.on_finish == second_closer,
        "a caller that passed no on_finish silently cleared the existing one")

-- getChannel is the reason createChannel must not treat "no argument" as "reset": it asks for a
-- default of one worker, and a channel that already runs four (the cover channel) must keep them.
local covers = AsyncHelper:createChannel("covers", 4)
local same_covers = AsyncHelper:getChannel("covers")
r.check("getChannel hands back an existing channel untouched",
        same_covers == covers and covers.max_workers == 4,
        "workers = " .. tostring(covers.max_workers))

local fresh = AsyncHelper:getChannel("brand-new")
r.check("and builds a single-worker one when there is none",
        fresh ~= nil and fresh.max_workers == 1, "workers = " .. tostring(fresh and fresh.max_workers))

r.finish()
