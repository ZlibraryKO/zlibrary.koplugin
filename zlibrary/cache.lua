local util = require("util")
local md5 = require("ffi/sha2").md5
local logger = require("logger")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

-- default cache lifetime: 5 days
local DEF_CACHE_EXPIRY = 432000

local Cache = {
    name = nil,
    path = nil,
    _cache = nil,
    _has_cache = nil,
    _dir = DataStorage:getDataDir() .. "/cache/zlibrary"
}

function Cache:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    if o.init then
        o:init()
    end
    return o
end

function Cache:init()
    if not self.path and self.name then
        self.path = self:makePath()
    end
end

function Cache:makePath(...)
    local name = select('#', ...) > 0 and table.concat({...}, "_") or self.name
    return ("%s/%s"):format(
        self._dir,
        md5(name)
    )
end

-- lazy Initialization
function Cache:_ensureInit()
    if self._cache then return end

    assert(self.path, "Cache.ensureInit: cache_path is undefined")

    local fileExists = util.fileExists(self.path)
    if not fileExists then
        local dir = util.splitFilePathName(self.path)
        if not util.directoryExists(dir) then
            util.makePath(dir)
            if not util.directoryExists(dir) then
                os.execute(string.format('"mkdir -p "%s"', dir))
            end
        end
    end

    self._cache = LuaSettings:open(self.path)
end

function Cache:get(key, cache_expiry)
    if type(key) ~= "string" or key == "" then
        return nil
    end
    self:_ensureInit()

    local expiry = tonumber(cache_expiry) or DEF_CACHE_EXPIRY
    local uptime_key = key .. "_ut"
    local uptime = self._cache:readSetting(uptime_key)

    if expiry <= 0 then
        return nil
    end
    if not uptime or (os.time() - uptime > expiry) then
        self._cache:delSetting(key)
        return nil
    end

    local value = self._cache:readSetting(key)
    if not value then
        return nil
    end

    self._has_cache = true
    return value
end

function Cache:insert(key, object)
    if not (type(key) == "string" and type(object) == "table" and next(object)) then
        return
    end
    self:_ensureInit()
    local uptime_key = key .. "_ut"
    self._cache:saveSetting(key, object)
    self._cache:saveSetting(uptime_key, os.time()):flush()
    self._has_cache = true
    return true
end

function Cache:remove(key)
    if type(key) ~= "string" or key == "" then
        return nil
    end
    self:_ensureInit()
    if not self._cache.delSetting then
        return nil
    end
    self._cache:delSetting(key)
    return true
end

function Cache:hasValidCache()
    return self._has_cache
end

function  Cache:getCacheDir()
    return self._dir
end

function  Cache:getCachePath()
    return self.path
end

function Cache:clear()
    if self.path and util.fileExists(self.path) then
        pcall(os.remove, self.path)
        self._cache = nil
    end
end

return Cache
