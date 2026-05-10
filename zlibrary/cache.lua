local lfs = require("libs/libkoreader-lfs")
local ffiUtil = require("ffi/util")
local util = require("util")
local md5 = require("ffi/sha2").md5
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local logger = require("logger")

local DEF_TTL_CACHE_EXPIRY = 432000 -- 5 days
local BASE_CACHE_DIR = DataStorage:getDataDir() .. "/cache/zlibrary"

local BaseCache = {}
BaseCache.__index = BaseCache

function BaseCache:_ensurePath(dir)
    if not util.directoryExists(dir) then
        util.makePath(dir)
        if not util.directoryExists(dir) then
            ffiUtil.execute(string.format('mkdir -p "%s"', dir))
        end
    end
    return dir
end

function BaseCache:_safeCopy(from, to)
    local ok = os.rename(from, to)
    if not ok then
        local copy_ok = pcall(ffiUtil.copyFile, from, to)
        if copy_ok then
            pcall(os.remove, from)
        else
            logger.warn("Cache:_safeCopy failed to copy file: " .. tostring(from))
            return false
        end
    end
    return true
end

-- lru
function BaseCache:gc_clean()
    if not self._target_dir or not self.file_cache_size then return end
    
    local files = {}
    local total_size = 0
    local dir = self._target_dir
    
    local ok, err = pcall(function()
        if not util.directoryExists(dir) then return end
        for file in lfs.dir(dir) do
            if file ~= "." and file ~= ".." then
                local filepath = dir .. "/" .. file
                local attr = lfs.attributes(filepath)
                if attr and attr.mode == "file" then
                    total_size = total_size + (attr.size or 0)
                    table.insert(files, {
                        path = filepath,
                        size = attr.size or 0,
                        time = attr.access or attr.modification or 0 
                    })
                end
            end
        end

        if total_size <= self.file_cache_size then return end
        
        table.sort(files, function(a, b) return a.time > b.time end)
        while total_size > self.file_cache_size do
            local oldest = table.remove(files)
            if not oldest then break end
            if os.remove(oldest.path) then
                total_size = total_size - oldest.size
                logger.info("Cache LRU GC: Removed " .. oldest.path)
            end
        end
    end)
    
    if not ok then logger.warn("Cache.gc_clean error:", tostring(err)) end
end

local KVCache = setmetatable({}, {__index = BaseCache})
KVCache.__index = KVCache

function KVCache:init()
    self:_ensurePath(BASE_CACHE_DIR)
    local safe_name = self.name or "default_kv"
    self.path = ("%s/%s.lua"):format(BASE_CACHE_DIR, md5(safe_name))
    self._cache = LuaSettings:open(self.path)
end

function KVCache:getPath(book_hash)
    return self.path
end

function KVCache:insert(key, table_data)
    if not self._cache or type(key) ~= "string" or table_data == nil then return false end
    self._cache:saveSetting(key, { data = table_data, _at = os.time() })
    self._cache:flush() 
    return true
end

function KVCache:get(key, cache_expiry)
    if not self._cache or type(key) ~= "string" then return nil end
    local entry = self._cache:readSetting(key)
    if not entry or type(entry) ~= "table" or not entry._at then
        if entry then self:remove(key) end
        return nil
    end

    local expiry = tonumber(cache_expiry) or DEF_TTL_CACHE_EXPIRY
    if expiry > 0 and (os.time() - entry._at > expiry) then
        self:remove(key)
        return nil
    end
    return entry.data
end

function KVCache:remove(key)
    if not self._cache or type(key) ~= "string" or not self._cache.delSetting then return false end
    self._cache:delSetting(key)
    if self._cache.data and not next(self._cache.data) then
        self._cache:purge()
    else
        self._cache:flush()
    end
    return true
end

function KVCache:clear()
    if self._cache then 
        self._cache:purge() 
        self._cache = LuaSettings:open(self.path)
    end
    return true
end

local BookInfoCache = setmetatable({}, {__index = BaseCache})
BookInfoCache.__index = BookInfoCache

function BookInfoCache:init()
    self._target_dir = BASE_CACHE_DIR .. "/bookinfos"
    self.file_cache_size = 5 * 1024 * 1024 -- 5M
    self:_ensurePath(self._target_dir)
end

function BookInfoCache:getPath(book_hash)
    return ("%s/%s_info.lua"):format(self._target_dir, book_hash or "")
end

function BookInfoCache:insert(book_hash, info_table)
    if type(book_hash) ~= "string" or type(info_table) ~= "table" then return false end
    local path = self:getPath(book_hash)
    local book_cache = LuaSettings:open(path)
    book_cache:saveSetting("info", info_table)
    book_cache:saveSetting("_at", os.time())
    book_cache:flush()
    return true
end

function BookInfoCache:get(book_hash, cache_expiry)
    if type(book_hash) ~= "string" then return nil end
    local path = self:getPath(book_hash)
    if not util.fileExists(path) then return nil end

    local book_cache = LuaSettings:open(path)
    local info = book_cache:readSetting("info")
    if not info then
        book_cache:purge()
        return nil 
    end

    if cache_expiry then
        local _at = book_cache:readSetting("_at")
        local expiry = tonumber(cache_expiry)
        if _at and expiry and expiry > 0 and (os.time() - _at > expiry) then
            book_cache:purge()
            return nil
        end
    end
    return info
end

function BookInfoCache:remove(book_hash)
    if type(book_hash) ~= "string" then return false end
    local path = self:getPath(book_hash)
    if util.fileExists(path) then
        return pcall(os.remove, path)
    end
    return false
end

function BookInfoCache:clear(book_hash) 
    return self:remove(book_hash)
end


local CoverCache = setmetatable({}, {__index = BaseCache})
CoverCache.__index = CoverCache

function CoverCache:init()
    self._target_dir = BASE_CACHE_DIR .. "/covers"
    self.file_cache_size = 20 * 1024 * 1024 -- test 0.01* 1024 * 1024
    self:_ensurePath(self._target_dir)
end

function CoverCache:getPath(book_hash)
    return ("%s/%s.jpg"):format(self._target_dir, book_hash or "")
end

function CoverCache:getTempPath(book_hash)
    if type(book_hash) ~= "string" or book_hash == "" then return nil end
    return ("%s/%s.jpg.downloading"):format(self._target_dir, book_hash)
end

function CoverCache:insert(book_hash, source_file_path)
    if type(book_hash) ~= "string" or type(source_file_path) ~= "string" then return false end
    if not util.fileExists(source_file_path) then return false end
    
    local target_path = self:getPath(book_hash)
    if self:_safeCopy(source_file_path, target_path) then
        return target_path
    end
    return false
end

function CoverCache:get(book_hash)
    if type(book_hash) ~= "string" or book_hash == "" then return nil end
    local path = self:getPath(book_hash)
    if util.fileExists(path) then return path end
    return nil
end

function CoverCache:remove(book_hash)
    if type(book_hash) ~= "string" or book_hash == "" then return false end
    local path = self:getPath(book_hash)
    local temp_path = self:getTempPath(book_hash)
    
    local deleted = false
    if util.fileExists(path) and pcall(os.remove, path) then deleted = true end
    if util.fileExists(temp_path) then pcall(os.remove, temp_path) end
    
    return deleted
end

function CoverCache:clear(book_hash) 
    return self:remove(book_hash)
end

local M = {}
local _instances = {} --cover bookinfo
function M:new(o)
    o = o or {}
    local ctype = o.type or "kv"

    if ctype == "kv" then
        local obj = setmetatable(o, KVCache)
        if obj.init then obj:init() end
        return obj
    end

    local instance_key = ctype
    if _instances[instance_key] then
        return _instances[instance_key]
    end

    local obj
    if ctype == "bookinfo" then
        obj = setmetatable(o, BookInfoCache)
    elseif ctype == "cover" then
        obj = setmetatable(o, CoverCache)
    else
        logger.warn("Cache: Unknown cache type: " .. tostring(ctype))
        return nil
    end
    
    if obj.init then obj:init() end
    _instances[instance_key] = obj
    return obj
end

function M.cleanAllFiles()
    local logger = require("logger")
    logger.info("Cache: Starting global GC clean...")
    local cover_cache = M:new({type="cover"})
    cover_cache:gc_clean()
    local info_cache = M:new({type="bookinfo"})
    info_cache:gc_clean()
    logger.info("Cache: Global GC clean finished.")
end

return M