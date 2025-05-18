local UIManager = require("ui/uimanager")
local coroutine = require("coroutine")
local logger = require("logger")

local AsyncHelper = {}

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
            logger.err("AsyncHelper.run - Coroutine resumption failed: %s", tostring(returned_value))
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
                    logger.err("AsyncHelper.run - Task error: %s", tostring(returned_value.data.error))
                    if on_error then on_error(tostring(returned_value.data.error)) end
                else
                    logger.dbg("AsyncHelper.run - Calling on_success callback.")
                    if on_success then on_success(returned_value.data) end
                end
            else
                logger.err("AsyncHelper.run - Task failed: %s", tostring(returned_value.error))
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
