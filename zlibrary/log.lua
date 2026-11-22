-- The plugin's logger: KOReader's own, with one switch of its own on top.
--
-- Routine lines go out at dbg, which KOReader writes to crash.log only with Developer options ->
-- Enable debug logging -- and that also turns on KOReader's own debug output, which is far louder
-- than the plugin's. "Detailed logging" in the plugin's Advanced settings is the narrower switch:
-- with it on, the plugin's dbg lines are written at info, so they reach crash.log with nothing
-- else's debug output alongside them. info, warn and err pass straight through either way.
--
-- A leaf: it requires nothing of the plugin's. Config owns the setting and calls setDetailed when
-- it changes, and main.lua's init applies the stored value before anything else is logged.
--
-- KOReader's logger functions are looked up on every call rather than captured here, because
-- Logger:setLevel replaces them in place (with a no-op below the level), so a captured one would
-- keep the level KOReader had when this module was loaded.

local logger = require("logger")

local Log = {}

local detailed = false

function Log.setDetailed(on)
    detailed = on == true
end

function Log.isDetailed()
    return detailed
end

function Log.dbg(...)
    if detailed then
        return logger.info(...)
    end
    return logger.dbg(...)
end

function Log.info(...) return logger.info(...) end
function Log.warn(...) return logger.warn(...) end
function Log.err(...) return logger.err(...) end

return Log
