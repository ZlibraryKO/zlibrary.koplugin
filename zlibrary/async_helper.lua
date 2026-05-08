local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")
local Device = require("device")
local Trapper = require("ui/trapper")
local coroutine = require("coroutine")
local logger = require("logger")

local Channel = {}
Channel.__index = Channel

function Channel:new(name, max_workers, shared_cache)
    local obj = setmetatable({}, self)
    obj.name = name
    obj.max_workers = max_workers or 1
    obj.active_workers = 0
    obj.session = 0
    obj.queue = {}
    obj.cache = shared_cache
    return obj
end

-- NetworkMgr:isConnected() not Work in task
function Channel:pushTask(task_func, callback, opts)
    opts = opts or {}
    local cache_key = opts.cache_key
    if cache_key and self.cache[cache_key] then
        UIManager:nextTick(function()
            if opts.on_start then pcall(opts.on_start) end
            pcall(callback, true, self.cache[cache_key])
        end)
        return
    end
    table.insert(self.queue, {
        func = task_func,
        args = opts.args,
        on_start = opts.on_start,
        timeout = opts.timeout,
        callback = callback,
        cache_key = cache_key,
        returns_string = opts.returns_string or false,
        session = self.session
    })
    if self.active_workers < self.max_workers then
        self:_processNext()
    end
end

function Channel:_processNext()
    if #self.queue == 0 then return end
    self.active_workers = self.active_workers + 1

    local task = table.remove(self.queue, 1)
    local execute_func
    if task.args and type(task.args) == "table" then
        execute_func = function() return task.func(unpack(task.args)) end
    else
        execute_func = task.func
    end

    if type(task.on_start) == "function" then pcall(task.on_start) end
    
    local buffer = require("string.buffer")
    local timeout = task.timeout or 180

    Trapper:wrap(function()
        pcall(function() Device:enableCPUCores(2) end)
        logger.dbg("Channel:_processNext - START")
        
        local start_time = os.time()
        local pid, parent_read_fd = nil, nil
        local poll_count = 0
        local function deliver_result(ok, r1, r2)
            if parent_read_fd then
                pcall(ffiUtil.readAllFromFD, parent_read_fd)
                parent_read_fd = nil
            end
            local status, err = pcall(function() Device:enableCPUCores(1) end)
            if not status then
                logger.err('Channel:_processNext - Device.enableCPUCores err', tostring(err))
            end
            logger.dbg("Channel:_processNext - END")
            local completed, result = ok, r1
            if task.session == self.session then
                if completed and result ~= nil then
                    if task.cache_key then self.cache[task.cache_key] = result end
                    pcall(task.callback, true, result)
                else
                    pcall(task.callback, false, nil)
                end
            else
                logger.dbg("Channel: Dropped stale task for:", self.name)
            end
            self.active_workers = self.active_workers - 1
            UIManager:nextTick(function() self:_processNext() end)
        end
        pid, parent_read_fd = ffiUtil.runInSubProcess(function(_pid, child_write_fd)
            local job_ok, r1, r2 = pcall(execute_func)
            local ret_tbl = { ok = job_ok, r1 = r1, r2 = r2 }
            -- NOTE: LuaJIT's serializer currently doesn't support:
            --       functions, coroutines, non-numerical FFI cdata & full userdata.
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
            logger.dbg("Channel:_processNext - background task failed to start")
            deliver_result(false, "start_failed", parent_read_fd)
            return
        end
        local function poll()
            poll_count = poll_count + 1
            if timeout and os.difftime(os.time(), start_time) >= timeout then
                logger.dbg("Channel:_processNext - timeout reached, killing subprocess")
                ffiUtil.terminateSubProcess(pid)
                UIManager:scheduleIn(0.5, function()
                    deliver_result(false, "timeout")
                end)
                return
            end
            local subprocess_done = ffiUtil.isSubProcessDone(pid)
            local stuff_to_read = parent_read_fd and ffiUtil.getNonBlockingReadSize(parent_read_fd) ~= 0
            
            if subprocess_done or stuff_to_read then
                local ok, r1, r2 = false, nil, nil
                if parent_read_fd then
                    local ret_str = ffiUtil.readAllFromFD(parent_read_fd) or ""
                    local dec_ok, ret_tbl = pcall(buffer.decode, ret_str)

                    if dec_ok and ret_tbl and type(ret_tbl) == "table" then
                        ok, r1, r2 = ret_tbl.ok, ret_tbl.r1, ret_tbl.r2
                    else
                        logger.warn(string.format("Channel:_processNext - malformed data (len: %d)", #ret_str))
                        ok, r1, r2 = false, "decode_error", nil
                    end
                    ret_str = nil
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
    end)
end

function Channel:clearTasks()
    self.queue = {}
    self.session = self.session + 1
    logger.dbg("Channel: Tasks cleared. New session for:", self.name)
end


local AsyncHelper = {
    cache = {},
    channels = {}
}

function AsyncHelper:createChannel(name, max_workers)
    if not self.channels[name] then
        self.channels[name] = Channel:new(name, max_workers, self.cache)
        logger.dbg(string.format("AsyncHelper: Created channel '%s' (max_workers=%d)", name, max_workers or 1))
    end
    return self.channels[name]
end

function AsyncHelper:getChannel(name)
    return self.channels[name] or self:createChannel(name, 1)
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
