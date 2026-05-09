local UIManager = require("ui/uimanager")
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
-- task_func must have a return value
function Channel:pushTask(task_func, callback, opts)
    opts = opts or {}
    local cache_key = opts.cache_key
    if cache_key and self.cache[cache_key] then
        UIManager:nextTick(function()
            safe_call("on_start (cache)", opts.on_start, 0)
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
    self.active_workers = self.active_workers + 1
    local task = table.remove(self.queue, 1)

    local actual_args = task.args
    if type(task.args_generator) == "function" then
        local gen_ok, gen_args = safe_call("args_generator", task.args_generator, task.current_retry)
        if gen_ok then actual_args = gen_args else actual_args = nil end
    end

    local execute_func
    if actual_args and type(actual_args) == "table" then
        execute_func = function() return task.func(unpack(actual_args)) end
    else
        execute_func = task.func
    end

    safe_call("on_start", task.on_start, task.current_retry)
    
    local buffer = require("string.buffer")
    local timeout = task.timeout or 180

    -- first worker wakes CPU
    if self.active_workers == 1 then pcall(function() Device:enableCPUCores(2) end) end

    logger.dbg("Channel:_processNext - START", self.name)    
    local start_time = os.time()
    local pid, parent_read_fd = nil, nil
    local poll_count = 0

    local function deliver_result(ok, r1, r2)
        if parent_read_fd then
            pcall(ffiUtil.readAllFromFD, parent_read_fd)
            parent_read_fd = nil
        end
        logger.dbg("Channel:_processNext - END", self.name)
        local completed, result = ok, r1

        -- lifecycle hook
        if task.session == self.session then
            local success = (completed and result ~= nil and actual_args ~= nil)

            if not success and task.current_retry < task.max_retries then
                task.current_retry = task.current_retry + 1
                logger.warn(string.format("Channel '%s': Task failed, retrying... (%d/%d)", self.name, task.current_retry, task.max_retries))
                table.insert(self.queue, 1, task) -- failed task retry with priority
            else
                if success and task.cache_key then self.cache[task.cache_key] = result end
                
                safe_call("callback", task.callback, success, result, task.current_retry)
            end
        else
            logger.dbg("Channel: Dropped stale task for:", self.name)
        end
        self.active_workers = self.active_workers - 1
        if #self.queue == 0 and self.active_workers == 0 then
            -- no tasks, restore CPU core
            pcall(function() Device:enableCPUCores(1) end)
            UIManager:nextTick(function()
                if #self.queue == 0 and self.active_workers == 0 then
                    logger.dbg("Channel: Naturally drained:", self.name)
                    safe_call("on_finish (drain)", self.on_finish, false)
                end
            end)
        else
            UIManager:nextTick(function() self:_processNext() end)
        end
    end

    pid, parent_read_fd = ffiUtil.runInSubProcess(function(_pid, child_write_fd)
        local job_ok, r1, r2 = pcall(execute_func)
        local ret_tbl = { ok = job_ok, r1 = r1, r2 = r2 }
        
        local output_str = ""
        local enc_ok, str = pcall(buffer.encode, ret_tbl)
        if enc_ok and str then
            output_str = str
        else
            logger.warn("Channel:_processNext - serialization failed:", str or "unknown error")
            ret_tbl = { ok = false, r1 = "serialization_error", r2 = tostring(str)}
            output_str = buffer.encode(ret_tbl) or ""
        end 
        ffiUtil.writeToFD(child_write_fd, output_str, true)
    end, true)
    if not pid then
        logger.warn("Channel:_processNext - background task failed to start")
        deliver_result(false, "start_failed")
        return
    end
    local function poll()
        poll_count = poll_count + 1  
        if timeout and os.difftime(os.time(), start_time) >= timeout then
            logger.warn("Channel:_processNext - timeout reached, killing subprocess")
            ffiUtil.terminateSubProcess(pid)
            UIManager:scheduleIn(0.5, function()
                deliver_result(false, "timeout")
            end)
            return
        end
        local subprocess_done = ffiUtil.isSubProcessDone(pid)
        if subprocess_done then
            local ok, r1, r2 = false, nil, nil
            if parent_read_fd then
                local ret_str = ffiUtil.readAllFromFD(parent_read_fd) or ""
                if ret_str ~= "" then
                    local dec_ok, ret_tbl = pcall(buffer.decode, ret_str)
                    if dec_ok and type(ret_tbl) == "table" then
                        ok, r1, r2 = ret_tbl.ok, ret_tbl.r1, ret_tbl.r2
                    else
                        logger.warn(string.format("Channel:_processNext - malformed data (len: %d)", #ret_str))
                        ok, r1, r2 = false, "decode_error", nil
                    end
                else
                    ok, r1, r2 = false, "empty_pipe_error", nil
                end
                parent_read_fd = nil
            end
            logger.dbg("Channel:_processNext - background task completed")
            deliver_result(ok, r1, r2)
        else
            local next_delay = (poll_count <= 5) and 0.02 or 0.2
            UIManager:scheduleIn(next_delay, poll)
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
        local wrap_start = on_start and function(retry) on_start(i, item, retry) end or nil
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
            max_retries = params.max_retries
        })
    end
end

local AsyncHelper = {
    cache = {},
    channels = {}
}

function AsyncHelper:createChannel(name, max_workers, on_finish)
    if not self.channels[name] then
        self.channels[name] = Channel:new(name, max_workers, self.cache)
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
    local pending = true
    UIManager:scheduleIn(seconds, function()
        pending = false
        func()
    end)
    return function()
        if pending then
            pending = false
            UIManager:unschedule(func)
        end
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
