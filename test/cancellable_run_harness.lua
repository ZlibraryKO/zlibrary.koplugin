-- Does a cancellable request route its outcome to exactly one callback?
--
-- AsyncHelper.runCancellable (zlibrary/async_helper.lua) borrows the download mechanism: the
-- task runs in a forked child while an invisible trap widget catches a dismissing tap. Its
-- decision shape is the part a refactor can silently break:
--
--   * a finished child routes like AsyncHelper.run -- a result carrying .error, or a task that
--     raised, goes to on_error; anything else to on_success
--   * a dismiss (completed=false AFTER the poll loop yielded) closes the loading widget, shows
--     the cancelled notice, and calls on_cancel -- never on_error, so no retry dialog pops up
--     over a cancellation the user just asked for
--   * a fork failure (completed=false with NO yield -- the poll loop was never reached) is not
--     a cancellation: the request falls back to the in-process run so it still happens
--   * a child that finished without a usable answer falls back the same way, rather than
--     inventing an error the task never produced
--
-- The yielded/unyielded distinction is what keeps "this device cannot fork" from being reported
-- to the user as "you cancelled". Both sides of it are driven below.

local PLUGIN = assert(arg[1], "usage: luajit cancellable_run_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local ASYNC = PLUGIN .. "/zlibrary/async_helper.lua"

-- Compile the real runCancellable against a fresh environment per scenario. The AsyncHelper
-- table is injected, so its .run field doubles as the fallback recorder.
local function compile(env, AsyncHelper)
    local body = support.extract_block(ASYNC, "(\nfunction AsyncHelper%.runCancellable%(.-\n)end\n")
    local chunk = assert(loadstring("local AsyncHelper = ...\n" .. body .. "end\nreturn AsyncHelper",
                                    "=runCancellable"))
    setfenv(chunk, env)
    return chunk(AsyncHelper)
end

local function runScenario(scenario, task_func, with_on_cancel)
    local rig = {
        ticks = {}, closed = {}, shown = {}, fallbacks = {},
        successes = {}, errors = {}, cancels = 0,
        child_ran = false, cache_disabled = false,
    }

    local env = {
        pcall = pcall, tostring = tostring, type = type,
        logger = { dbg = function() end, info = function() end, warn = function() end, err = function() end },
        safe_call = function(_, fn, ...)
            if type(fn) ~= "function" then return true, nil end
            return pcall(fn, ...)
        end,
        T = function(s) return s end,
        InfoMessage = { new = function(_, opts) return { text = opts.text, timeout = opts.timeout } end },
        require = function(mod)
            assert(mod == "zlibrary.config", "unexpected require: " .. tostring(mod))
            return { disableRuntimeCacheWrites = function() rig.cache_disabled = true end }
        end,
    }

    env.UIManager = {
        nextTick = function(_, fn) table.insert(rig.ticks, fn) end,
        close = function(_, w) table.insert(rig.closed, w) end,
        show = function(_, w) table.insert(rig.shown, w) end,
    }

    env.Trapper = {
        -- The harness runs the wrapped function straight through: the coroutine is not what is
        -- being pinned here, the routing of what comes back is.
        wrap = function(_, func) func() end,
        dismissableRunInSubprocess = function(_, child_task, _)
            if scenario.fork_failed then
                -- The real thing returns completed=false without ever entering the poll loop,
                -- so no scheduled tick has run either.
                return false
            end
            rig.child_ran = true
            local envelope = child_task()
            if scenario.dismissed then
                -- A dismiss can only be processed once the poll loop yielded and UIManager got
                -- control -- which is also when the pending nextTick runs.
                local pending = rig.ticks
                rig.ticks = {}
                for _, fn in ipairs(pending) do fn() end
                return false
            end
            if scenario.no_output then
                return true -- child exited with nothing readable
            end
            return true, envelope
        end,
    }

    local AsyncHelper = {
        run = function(task, on_success, on_error, loading)
            table.insert(rig.fallbacks, { task = task, loading = loading })
        end,
    }
    compile(env, AsyncHelper)

    local loading = { name = "loading" }
    AsyncHelper.runCancellable(task_func,
        function(result) table.insert(rig.successes, result) end,
        function(err) table.insert(rig.errors, err) end,
        loading,
        with_on_cancel and function() rig.cancels = rig.cancels + 1 end or nil)
    rig.loading = loading
    return rig
end

local function closed_loading(rig)
    for _, w in ipairs(rig.closed) do
        if w == rig.loading then return true end
    end
    return false
end

-- ---------------------------------------------------------------- a finished child routes like run()
do
    local result = { results = { "a", "b" } }
    local rig = runScenario({}, function() return result end, true)
    r.check("a plain result goes to on_success untouched",
            #rig.successes == 1 and rig.successes[1] == result,
            "successes: " .. #rig.successes)
    r.check("and no other callback ran",
            #rig.errors == 0 and rig.cancels == 0 and #rig.fallbacks == 0,
            string.format("errors=%d cancels=%d fallbacks=%d", #rig.errors, rig.cancels, #rig.fallbacks))
    r.check("the loading widget is closed on success", closed_loading(rig))
    r.check("the child disabled runtime cache writes before running the task", rig.cache_disabled)
    r.check("no cancelled notice is shown on success", #rig.shown == 0,
            "shown: " .. #rig.shown)
end

do
    local rig = runScenario({}, function() return { error = "Download limit reached" } end, true)
    r.check("a result carrying .error goes to on_error, not on_success",
            #rig.errors == 1 and rig.errors[1] == "Download limit reached" and #rig.successes == 0,
            "errors: " .. #rig.errors .. ", successes: " .. #rig.successes)
end

do
    local rig = runScenario({}, function() error("explode") end, true)
    r.check("a crashed task goes to on_error with the raised message",
            #rig.errors == 1 and type(rig.errors[1]) == "string" and rig.errors[1]:find("explode") ~= nil,
            "errors: " .. #rig.errors .. " (" .. tostring(rig.errors[1]) .. ")")
    r.check("and a crash is neither a success nor a cancellation",
            #rig.successes == 0 and rig.cancels == 0,
            string.format("successes=%d cancels=%d", #rig.successes, rig.cancels))
end

-- ---------------------------------------------------------------- a dismiss is a cancellation
do
    local rig = runScenario({ dismissed = true }, function() return { results = {} } end, true)
    r.check("a dismiss reaches on_cancel",
            rig.cancels == 1, "cancels: " .. rig.cancels)
    r.check("and never on_error, so no retry dialog opens over a cancellation",
            #rig.errors == 0 and #rig.successes == 0,
            string.format("errors=%d successes=%d", #rig.errors, #rig.successes))
    r.check("the loading widget is closed on cancel", closed_loading(rig))
    r.check("a cancelled notice is shown",
            #rig.shown == 1 and rig.shown[1].text == "Request cancelled.",
            "shown: " .. #rig.shown)
end

do
    local rig = runScenario({ dismissed = true }, function() return { results = {} } end, false)
    r.check("a dismiss without an on_cancel handler still closes the loading widget",
            closed_loading(rig) and #rig.errors == 0 and #rig.successes == 0)
    r.check("and still shows the cancelled notice",
            #rig.shown == 1 and rig.shown[1].text == "Request cancelled.",
            "shown: " .. #rig.shown)
end

-- ---------------------------------------------------------------- a fork failure is not a cancellation
do
    local rig = runScenario({ fork_failed = true }, function() return {} end, true)
    r.check("a fork failure falls back to the in-process run",
            #rig.fallbacks == 1, "fallbacks: " .. #rig.fallbacks)
    r.check("and the child never ran",
            not rig.child_ran)
    r.check("and it is not reported as a cancellation",
            rig.cancels == 0 and #rig.shown == 0,
            string.format("cancels=%d shown=%d", rig.cancels, #rig.shown))
end

do
    local rig = runScenario({ no_output = true }, function() return {} end, true)
    r.check("a child that finished without a usable answer also falls back to the in-process run",
            #rig.fallbacks == 1, "fallbacks: " .. #rig.fallbacks)
    r.check("rather than inventing an error or a cancellation",
            #rig.errors == 0 and #rig.successes == 0 and rig.cancels == 0,
            string.format("errors=%d successes=%d cancels=%d", #rig.errors, #rig.successes, rig.cancels))
end

r.finish()
