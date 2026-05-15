local time = require("ui/time")
local UIManager = require("ui/uimanager")
local buffer = require("string.buffer")
local ffiUtil = require("ffi/util")
local Device = require("device")
local Trapper = require("ui/trapper")
local coroutine = require("coroutine")
local logger = require("logger")

local function safe_call(tag, func, ...)
    if type(func) ~= "function" then return true, nil end
    local ok, res = pcall(func, ...)
    if not ok then
        logger.err(string.format("[AsyncHelper Panic Intercepted] %s execution error: %s", tag, tostring(res)))
    end
    return ok, res
end

local Channel = {}
Channel.__index = Channel

function Channel:new(name, max_workers, shared_cache, on_finish)
    local obj = setmetatable({}, self)
    obj.name = name
    obj.max_workers = max_workers or 1
    obj.active_workers = 0
    obj.session = 0
    obj.queue = {}
    obj.cache = shared_cache
    obj.session_abort_hooks = {}
    obj.on_finish = on_finish
    return obj
end

-- NetworkMgr:isConnected() not Work in task
function Channel:pushTask(task_func, callback, opts)
    opts = opts or {}
    local cache_key = opts.cache_key
    if cache_key and self.cache[cache_key] then
        UIManager:nextTick(function()
            safe_call("on_start (cache)", opts.on_start)
            safe_call("callback (cache)", callback, true, self.cache[cache_key], 0)
        end)
        return
    end
    local task_node = {
        func = task_func,
        args = opts.args,
        args_generator = opts.args_generator,
        on_start = opts.on_start,
        timeout = opts.timeout,
        callback = callback,
        cache_key = cache_key,
        returns_string = opts.returns_string or false,
        session = self.session,
        max_retries = opts.max_retries or 0,
        current_retry = 0
    }
    if opts.insert_at_head then
        table.insert(self.queue, 1, task_node)
    else
        table.insert(self.queue, task_node)
    end
    if self.active_workers < self.max_workers then
        self:_processNext()
    end
end

function Channel:_processNext()
    if #self.queue == 0 then return end
    local task = table.remove(self.queue, 1)

    local actual_args = task.args
    if type(task.args_generator) == "function" then
        local ok, gen_args = safe_call("args_generator", task.args_generator, task.current_retry)
        actual_args = ok and gen_args or nil 
        if not actual_args then
            logger.err("Channel: Args generation failed, aborting task", self.name)
            safe_call("callback", task.callback, false, "Arguments generation failed", task.current_retry)
            UIManager:nextTick(function() self:_processNext() end)
            return
        end
    end

    actual_args = actual_args or {} 
    local execute_func
    if actual_args and type(actual_args) == "table" then
        local unpack_func = table.unpack or unpack
        execute_func = function() return task.func(unpack_func(actual_args)) end
    else
        execute_func = task.func
    end

     logger.dbg("Channel:_processNext - START", self.name)    
    self.active_workers = self.active_workers + 1

    -- first worker wakes CPU
    if self.active_workers == 1 then pcall(function() Device:enableCPUCores(2) end) end
    if task.on_start then
        safe_call("on_start", task.on_start)
        task.on_start = nil
    end

    local timeout = task.timeout or 180
    local task_returns_simple_string =  task.returns_string
    local start_time = time.now()
    local pid, parent_read_fd = nil, nil
    local poll_count = 0

    local function deliver_result(ok, r1, r2)
        logger.dbg("Channel:_processNext - END", self.name)
        local completed, ret1, ret2 = ok, r1, r2
        -- lifecycle hook
        if task.session == self.session then
            local success = false
            local final_result = nil
            local final_error = nil
            if not completed then
                success = false
                final_error = tostring(ret1)
            elseif ret1 == false then
                success = false
                final_error = ret2 or "Task soft-failed without error message"
            else
                success = true
                final_result = ret1
            end
            if success then
                safe_call("callback", task.callback, true, final_result, task.current_retry)
            else
                if task.current_retry < task.max_retries then
                    task.current_retry = task.current_retry + 1
                    table.insert(self.queue, 1, task)
                    logger.warn(string.format("Channel '%s': Task failed, retrying... (%d/%d)", self.name, task.current_retry, task.max_retries))
                else
                    logger.err("Channel: Task failure or returned nil:", self.name)
                    final_error = final_error or "task failure or returned nil"
                    safe_call("callback", task.callback, false, final_error, task.current_retry)
                end
            end
        else
            logger.dbg("Channel: Dropped stale task for:", self.name)
        end
        self.active_workers = self.active_workers - 1
        if #self.queue == 0 and self.active_workers == 0 then
            -- no tasks, restore CPU core
            pcall(function() Device:enableCPUCores(1) end)
            if self.on_finish then
                UIManager:nextTick(function()
                    if #self.queue == 0 and self.active_workers == 0 then
                        logger.dbg("Channel: Naturally drained:", self.name)
                        safe_call("on_finish (drain)", self.on_finish, false)
                    end
                end)
            end
        else
            UIManager:nextTick(function() self:_processNext() end)
        end
    end
    pid, parent_read_fd = ffiUtil.runInSubProcess(function(_pid, child_write_fd)
        local job_ok, r1, r2 = pcall(execute_func)
        local output_str = nil
        
        local need_pack = not task_returns_simple_string
        if task_returns_simple_string then
            if job_ok and type(r1) == "string" then
                output_str = r1
                need_pack = false
            else
                -- error occurred, revert to batch mode
                need_pack = true 
                if not job_ok then
                    logger.warn("Channel:_processNext - execute_func crashed:", r1)
                else
                    logger.warn("Channel:_processNext - returned value from task_func is not a string")
                    r1 = "returned value from task_func is not a string"
                    job_ok = false
                end
            end
        end
        if need_pack then
            local ret_tbl = { ok = job_ok, r1 = r1, r2 = r2 }
            local enc_ok, str = pcall(buffer.encode, ret_tbl)
            if enc_ok and str then
                output_str = str
            else
                logger.warn("Channel:_processNext - serialization failed:", str or "unknown error")
                ret_tbl = { ok = false, r1 = "serialization_error", r2 = tostring(str) }
                output_str = buffer.encode(ret_tbl) or ""
            end 
        end
        ffiUtil.writeToFD(child_write_fd, output_str or "", true)
        end, true)
        if not pid then
            logger.warn("Channel:_processNext - background task failed to start")
            deliver_result(false, "start_failed")
            return
        end
    local check_interval_sec = 0.125 
    local function poll()
        poll_count = poll_count + 1
        local function safe_collect_and_clean(target_pid, fd_to_close, max_retries, retry_interval, debug_tag)
            local retry_count = 0
            local function cleaner_step()
                retry_count = retry_count + 1
                if ffiUtil.isSubProcessDone(target_pid) then
                   if fd_to_close then ffiUtil.readAllFromFD(fd_to_close) end
                    logger.dbg(string.format("Channel:_processNext - %s collected successfully.", debug_tag))
                elseif retry_count >= max_retries then
                    -- max retries reached, abort to avoid infinite recursion
                    logger.warn(string.format("Channel:_processNext - %s failed to collect PID %d after %d retries. Forcibly terminating!", debug_tag, target_pid, max_retries))
                    ffiUtil.terminateSubProcess(target_pid)
                    UIManager:scheduleIn(1, function()
                        if ffiUtil.isSubProcessDone(target_pid) then
                            logger.warn("Channel:_processNext - cleaner_step max_retries, force killed and exited", target_pid)
                            if fd_to_close then ffiUtil.readAllFromFD(fd_to_close) end
                        end
                    end)
                else
                    if fd_to_close and ffiUtil.getNonBlockingReadSize(fd_to_close) ~= 0 then
                        ffiUtil.readAllFromFD(fd_to_close)
                        fd_to_close = nil 
                    end
                    UIManager:scheduleIn(retry_interval, cleaner_step)
                end
            end
            cleaner_step()
        end

        local duration_seconds = tonumber(time.to_s(time.since(start_time))) or 0
        if timeout and duration_seconds >= timeout then
            logger.warn("Channel:_processNext - timeout reached, killing subprocess", pid, duration_seconds)
            ffiUtil.terminateSubProcess(pid)
            safe_collect_and_clean(pid, parent_read_fd, 5, 3, "timed-out subprocess")
            parent_read_fd = nil
            deliver_result(false, "timeout")
            return
        end

        local subprocess_done = ffiUtil.isSubProcessDone(pid)
        local stuff_to_read = parent_read_fd and ffiUtil.getNonBlockingReadSize(parent_read_fd) ~= 0

        if subprocess_done or stuff_to_read then
            -- Subprocess is gone or nearly gone
            local ok, r1, r2 = false, nil, nil
            
            if stuff_to_read then
                local ret_str = ffiUtil.readAllFromFD(parent_read_fd) or ""
                parent_read_fd = nil
                
                if ret_str ~= "" or (ret_str == "" and task_returns_simple_string and subprocess_done) then
                    if task_returns_simple_string then
                        ok, r1, r2= true, ret_str, nil 
                    else
                        local dec_ok, ret_tbl = pcall(buffer.decode, ret_str)
                        if dec_ok and type(ret_tbl) == "table" then
                            ok, r1, r2 = ret_tbl.ok, ret_tbl.r1, ret_tbl.r2
                        else
                            logger.warn("Channel:_processNext - malformed serialized data")
                            ok, r1, r2 = false, "decode_error", nil
                        end
                    end
                else
                    ok, r1, r2 = false, "empty_pipe_error", nil
                end
                -- data fully read, but process hasn't exited yet
                if not subprocess_done then
                    safe_collect_and_clean(pid, parent_read_fd, 3, 1, "pre-read subprocess")
                end
            else -- subprocess_done: process exited with no output
                   if parent_read_fd then ffiUtil.readAllFromFD(parent_read_fd) end
                    -- no ret_values
            end
            logger.dbg("Channel:_processNext - background task completed")
            deliver_result(ok, r1, r2)
        else
            -- backoff polling
            if check_interval_sec < 1 and poll_count % 10 == 0 then
                check_interval_sec = math.min(check_interval_sec * 2, 1)
            end
            UIManager:scheduleIn(check_interval_sec, poll)
        end
    end
    poll()
end

function Channel:clearTasks()
    local had_tasks = (#self.queue > 0 or self.active_workers > 0)
    self.queue = {}
    self.session = self.session + 1
    local hooks = self.session_abort_hooks
    self.session_abort_hooks = {} 
    for _, hook in pairs(hooks) do 
        safe_call("session_abort_hook", hook) 
    end
    if had_tasks and self.on_finish then
        logger.warn("Channel: Forcefully aborted:", self.name)
        safe_call("on_finish (abort)", self.on_finish, true)
    end
    logger.dbg("Channel: Tasks cleared. New session for:", self.name)
end

function Channel:executeBatch(params)
    local items = params.items or {}
    local task_func = params.task_func
    local get_task_args = params.get_task_args
    local on_start = params.on_start
    local on_item_end = params.on_item_end
    local on_batch_end = params.on_batch_end
    local aggregate = params.aggregate or false

    if not task_func then error("executeBatch: task_func is required") end
    self:clearTasks()
    local total_count = #items
    if total_count == 0 then
        if on_batch_end then safe_call("on_batch_end (empty)", on_batch_end, false, {}) end
        return
    end

    local completed_count = 0
    local is_aborted = false
    local results_map = aggregate and {} or nil 
    local batch_id = tostring({}) 

    self.session_abort_hooks[batch_id] = function()
        if not is_aborted then
            is_aborted = true
            logger.warn(string.format("Channel '%s': Batch externally aborted!", self.name))
            if on_batch_end then safe_call("on_batch_end (abort)", on_batch_end, true, results_map) end
        end
    end

    for i, item in ipairs(items) do
        local wrap_start = on_start and function() on_start(i, item) end or nil
        local args_gen = get_task_args and function(retry) return get_task_args(item, retry) end or nil
        local static_args = (not args_gen) and {item} or nil
        
        local wrap_end = function(success, result, retries_used)
            if is_aborted then return end 
            completed_count = completed_count + 1
            if aggregate then
                results_map[i] = { success = success, result = result, retries_used = retries_used }
            end
            
            local should_abort = false
            if on_item_end then
                -- if on_item_end crashes, return nil here, convert to false without blocking subsequent tasks
                local ok, req_abort = safe_call("on_item_end", on_item_end, i, item, success, result, retries_used)
                should_abort = (ok and req_abort == true)
            end
            
            if should_abort or completed_count == total_count then
                is_aborted = true
                self.session_abort_hooks[batch_id] = nil
                
                if should_abort then
                    self:clearTasks()
                    if on_batch_end then safe_call("on_batch_end (fused)", on_batch_end, true, results_map) end
                else
                    if on_batch_end then safe_call("on_batch_end (done)", on_batch_end, false, results_map) end
                end
            end
        end

        self:pushTask(task_func, wrap_end, {
            args = static_args, 
            args_generator = args_gen,
            on_start = wrap_start,
            max_retries = params.max_retries,
            returns_string = params.returns_string,
        })
    end
end

local AsyncHelper = {
    cache = {},
    channels = {}
}

function AsyncHelper:createChannel(name, max_workers, on_finish)
    if not self.channels[name] then
        self.channels[name] = Channel:new(name, max_workers, self.cache, on_finish)
        logger.dbg(string.format("AsyncHelper: Created channel '%s' (max_workers=%d)", name, max_workers or 1))
    end
    return self.channels[name]
end

function AsyncHelper:getChannel(name)
    return self.channels[name] or self:createChannel(name, 1)
end

function AsyncHelper:destroyChannel(name)
    local ch = self.channels[name]
    if ch then
        ch:clearTasks() 
        self.channels[name] = nil
        logger.dbg("AsyncHelper: Completely destroyed channel:", name)
    end
end

function AsyncHelper:clearCache()
    self.cache = {}
    logger.dbg("AsyncHelper: Global cache cleared.")
end

function AsyncHelper.delay(seconds, func)
    local is_cancelled = false
    local wrapper
    wrapper = function()
        if not is_cancelled then
            func()
        end
    end
    UIManager:scheduleIn(seconds, wrapper)
    return function()
        is_cancelled = true
        UIManager:unschedule(wrapper)
    end
end

function AsyncHelper.run(task_func, on_success, on_error, loading_msg_widget_to_close)
    logger.dbg("AsyncHelper.run - START")

    local co = coroutine.create(function()
        logger.dbg("AsyncHelper.run - Coroutine START")
        local success, result = pcall(task_func)
        logger.dbg("AsyncHelper.run - Coroutine task_func finished. OK: %s", tostring(success))

        if success then
            return { ok = true, data = result }
        else
            return { ok = false, error = result }
        end
    end)

    local function close_loading_message()
        if loading_msg_widget_to_close then
            UIManager:close(loading_msg_widget_to_close)
            logger.dbg("AsyncHelper.run - Closed loading message widget.")
        end
    end

    local function resume_handler()
        logger.dbg("AsyncHelper.run - Resuming coroutine.")
        local co_resume_success, returned_value = coroutine.resume(co)

        if not co_resume_success then
            logger.err(string.format("AsyncHelper.run - Coroutine resumption failed: %s", tostring(returned_value)))
            close_loading_message()
            if on_error then on_error("AsyncHelper: Coroutine resumption failed: " .. tostring(returned_value)) end
            return
        end

        if coroutine.status(co) == "dead" then
            logger.dbg("AsyncHelper.run - Coroutine is dead.")
            close_loading_message()
            if returned_value.ok then
                logger.dbg("AsyncHelper.run - Task successful.")
                if returned_value.data and returned_value.data.error then
                    logger.err(string.format("AsyncHelper.run - Task error: %s", tostring(returned_value.data.error)))
                    if on_error then on_error(tostring(returned_value.data.error)) end
                else
                    logger.dbg("AsyncHelper.run - Calling on_success callback.")
                    if on_success then on_success(returned_value.data) end
                end
            else
                logger.err(string.format("AsyncHelper.run - Task failed: %s", tostring(returned_value.error)))
                if on_error then on_error(tostring(returned_value.error)) end
            end
        else
            logger.dbg("AsyncHelper.run - Coroutine is not dead, scheduling next tick.")
            UIManager:nextTick(resume_handler)
        end
    end

    UIManager:nextTick(resume_handler)
    logger.dbg("AsyncHelper.run - END")
end

return AsyncHelper
