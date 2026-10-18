-- Does a background task whose result is bigger than the pipe buffer come back?
--
-- It used to hang until the channel's timeout killed it. The child writes its whole result to a
-- pipe and exits; the parent only read once the child had exited. A pipe holds 64 KB, so a bigger
-- result left the child blocked in write() waiting for a reader, and the parent waiting for an
-- exit that write() was holding up -- for the full 180 seconds, after which the task was killed
-- and reported as a failure. The favourites warmer hit this on every menu open once a reader was
-- signed in: thirty saved books come back as about 72 KB.
--
-- The real async_helper is loaded with the KOReader modules it needs replaced by a clock, a
-- scheduler and a subprocess double. The double's pipe holds 64 KB, as the kernel's does: a child
-- that writes more stays alive until the parent reads.

local PLUGIN = assert(arg[1], "usage: luajit channel_pipe_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local PIPE_CAPACITY = 65536

-- ---------------------------------------------------------------- clock and scheduler
local clock = 0
local queue = {}
local UIManager = {}
function UIManager:scheduleIn(seconds, func)
    queue[#queue + 1] = { at = clock + seconds, func = func, seq = #queue }
end
function UIManager:nextTick(func) self:scheduleIn(0, func) end

local function run_until_idle(limit)
    while #queue > 0 and clock <= limit do
        table.sort(queue, function(a, b)
            if a.at ~= b.at then return a.at < b.at end
            return a.seq < b.seq
        end)
        local job = table.remove(queue, 1)
        clock = math.max(clock, job.at)
        job.func()
    end
end

-- ---------------------------------------------------------------- subprocess double
local procs = {}
local next_pid = 100
local ffiUtil = {}

function ffiUtil.runInSubProcess(func)
    next_pid = next_pid + 1
    local pid = next_pid
    local proc = { exited = false, blocked = false, data = nil }
    procs[pid] = proc
    -- The child runs up to its final write here. It exits at once unless that write is still
    -- waiting for room in the pipe.
    func(pid, pid)
    if not proc.blocked then proc.exited = true end
    return pid, pid
end

function ffiUtil.writeToFD(fd, str)
    local proc = procs[fd]
    -- A child told to hang never gets its write out, and never exits on its own.
    if proc.hang then proc.blocked = true return end
    proc.data = str
    proc.blocked = #str > PIPE_CAPACITY
end

function ffiUtil.getNonBlockingReadSize(fd)
    local proc = procs[fd]
    if not proc.data then return 0 end
    return math.min(#proc.data, PIPE_CAPACITY)
end

function ffiUtil.readAllFromFD(fd)
    local proc = procs[fd]
    local data = proc.data or ""
    proc.data = nil
    -- Reading drains the pipe, so a child blocked in write() can finish and exit.
    if proc.blocked then
        proc.blocked = false
        proc.exited = true
    end
    return data
end

function ffiUtil.isSubProcessDone(pid) return procs[pid].exited end

function ffiUtil.terminateSubProcess(pid)
    procs[pid].exited = true
    procs[pid].killed = true
end

-- ---------------------------------------------------------------- load the real module
local warnings = {}
local function record(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    warnings[#warnings + 1] = table.concat(parts, " ")
end

local stubs = {
    ["ui/time"] = {
        now = function() return clock end,
        since = function(t) return clock - t end,
        to_s = function(t) return t end,
    },
    ["ui/uimanager"] = UIManager,
    ["string.buffer"] = require("string.buffer"),
    ["ffi/util"] = ffiUtil,
    ["device"] = { enableCPUCores = function() end },
    ["coroutine"] = coroutine,
    ["logger"] = { dbg = function() end, info = function() end, warn = record, err = record },
    ["ui/trapper"] = {},
    ["ui/widget/infomessage"] = {},
    ["zlibrary.gettext"] = function(s) return s end,
    ["zlibrary.config"] = { disableSubprocessWrites = function() end },
}
for name, value in pairs(stubs) do
    package.preload[name] = function() return value end
end
local AsyncHelper = dofile(PLUGIN .. "/zlibrary/async_helper.lua")

-- ---------------------------------------------------------------- run a task
local function run_task(make_result, opts)
    clock, queue, warnings = 0, {}, {}
    local channel = AsyncHelper:createChannel("pipe-test-" .. next_pid, 2)
    local outcome = {}
    channel:pushTask(make_result, function(success, res)
        outcome.success, outcome.res, outcome.at = success, res, clock
    end, opts)
    run_until_idle(1000)
    outcome.proc = procs[next_pid]
    return outcome
end

local big_text = string.rep("x", 100 * 1024)

local small = run_task(function() return { books = { { id = 1 } } } end)
r.check("a small result comes back", small.success == true and small.res.books[1].id == 1,
        "success=" .. tostring(small.success))

local big = run_task(function() return { books = { { id = 1, description = big_text } } } end)
r.check("a result bigger than the pipe comes back",
        big.success == true and type(big.res) == "table" and #big.res.books[1].description == #big_text,
        "success=" .. tostring(big.success) .. " res=" .. tostring(big.res))
r.check("without waiting for the timeout", big.at ~= nil and big.at < 5,
        "delivered after " .. tostring(big.at) .. "s")
r.check("and the child is not killed", big.proc and not big.proc.killed,
        "the child was terminated: " .. table.concat(warnings, " | "))

local big_string = run_task(function() return big_text end, { returns_string = true })
r.check("a string result bigger than the pipe comes back too",
        big_string.success == true and big_string.res == big_text and big_string.at < 5,
        "success=" .. tostring(big_string.success) .. " after " .. tostring(big_string.at) .. "s")

-- A child that never answers must still be stopped by the timeout: reading early must not have
-- turned "no data yet" into "done".
local hung_pid
local hung = run_task(function()
    hung_pid = next_pid
    procs[hung_pid].hang = true
    return nil
end, { timeout = 30 })
r.check("a child that never finishes is still timed out",
        hung.success == false and hung.at ~= nil and hung.at >= 30 and procs[hung_pid].killed,
        "success=" .. tostring(hung.success) .. " after " .. tostring(hung.at) .. "s")

r.finish()
