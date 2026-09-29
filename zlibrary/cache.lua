local lfs = require("libs/libkoreader-lfs")
local ffiUtil = require("ffi/util")
local util = require("util")
local md5 = require("ffi/sha2").md5
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local logger = require("logger")

local DEF_TTL_CACHE_EXPIRY = 432000 -- 5 days
-- Hidden, and that is the whole point of the dot.
--
-- These directories used to be <data>/cache/zlibrary, which on Android is inside SHARED storage --
-- DataStorage:getDataDir() is android.getExternalStoragePath() .. "/koreader" -- so Android's
-- media scanner indexed every cover and they surfaced as a wall of book covers in the phone's
-- file manager and gallery. Whatever the reader was searching for, it was on display to anyone
-- who picked up their phone.
--
-- A directory whose name begins with a dot is skipped by MediaStore and hidden by default in
-- essentially every Android file manager, which is why it is the fix rather than .nomedia alone:
-- it does not depend on the particular file manager honouring a convention file. The .nomedia
-- goes in as well, because it costs an empty file.
local BASE_CACHE_DIR = DataStorage:getDataDir() .. "/cache/.zlibrary"
local LEGACY_CACHE_DIR = DataStorage:getDataDir() .. "/cache/zlibrary"

-- An empty .nomedia asks Android's media scanner to skip the directory. Belt to the hidden
-- directory's braces; on every other platform it is an inert empty file.
local _nomedia_checked = {}
local function _ensureNoMedia(dir)
    if _nomedia_checked[dir] then return end
    _nomedia_checked[dir] = true
    local marker = dir .. "/.nomedia"
    if util.fileExists(marker) then return end
    local fh = io.open(marker, "w")
    if fh then fh:close() end
end

-- Remove a cache directory and its contents.
--
-- Two levels is the whole shape of this tree -- <base>/covers/<hash>.jpg,
-- <base>/bookinfos/<hash>_info.lua, and the kv .lua files beside them -- and the depth limit is
-- the rail on a function that deletes. symlinkattributes rather than attributes for the same
-- reason: a cache directory that has become a link to somewhere else is not followed there, it is
-- unlinked like any other entry.
local function _removeCacheTree(dir, depth)
    depth = depth or 0
    if depth > 2 then return false end
    if lfs.symlinkattributes(dir, "mode") ~= "directory" then return false end
    local listed, iter, dir_obj = pcall(lfs.dir, dir)
    if not listed then return false end
    local ok = true
    for entry in iter, dir_obj do
        if entry ~= "." and entry ~= ".." then
            local path = dir .. "/" .. entry
            if lfs.symlinkattributes(path, "mode") == "directory" then
                ok = _removeCacheTree(path, depth + 1) and ok
            else
                ok = (os.remove(path) and true or false) and ok
            end
        end
    end
    return (lfs.rmdir(dir) and true or false) and ok
end

-- Move an existing cache out of the visible directory, once.
--
-- Pointing new writes at the hidden path would fix nothing for anyone who already has the old
-- one, and the files already sitting there are the entire complaint. So the old directory is
-- emptied either way: by the rename when that works, and by deletion when it does not. Deleting
-- costs re-downloading covers once -- they are a cache, capped at 20MB and replaceable -- and
-- leaving them costs exactly what was reported.
local function _migrateLegacyCacheDir()
    if lfs.attributes(LEGACY_CACHE_DIR, "mode") ~= "directory" then return "none" end

    if lfs.attributes(BASE_CACHE_DIR, "mode") == nil
        and os.rename(LEGACY_CACHE_DIR, BASE_CACHE_DIR) then
        logger.info("Zlibrary:Cache - moved the cache out of shared storage into " .. BASE_CACHE_DIR)
        return "moved"
    end

    logger.warn("Zlibrary:Cache - could not move " .. LEGACY_CACHE_DIR
        .. " to " .. BASE_CACHE_DIR .. "; removing it instead, it is a replaceable cache")
    _removeCacheTree(LEGACY_CACHE_DIR, 0)
    return "removed"
end

-- At load, before any cache instance can write to either path.
_migrateLegacyCacheDir()

-- book_hash arrives verbatim from the server's JSON and is pasted straight into a filesystem path,
-- so it has to be treated as untrusted: a hash containing a slash or ".." would steer the cache's
-- writes, reads and unlinks outside BASE_CACHE_DIR. Real z-library hashes are hex, so accepting only
-- word characters, underscores and dashes rejects traversal without rejecting anything genuine.
local function _isValidBookHash(book_hash)
    return type(book_hash) == "string" and book_hash:match("^[%w_-]+$") ~= nil
end

local BaseCache = {}
BaseCache.__index = BaseCache

function BaseCache:_ensurePath(dir)
    if not util.directoryExists(dir) then
        util.makePath(dir)
        if not util.directoryExists(dir) then
            -- ffiUtil.execute execs the arguments directly with no shell on any platform (execl
            -- off-Android, android.execute's argv table on Android), so they must go in separately;
            -- one quoted command string would be looked up as a single executable name and never run.
            ffiUtil.execute("mkdir", "-p", dir)
        end
        _ensureNoMedia(BASE_CACHE_DIR)
    end
    -- Checked on every ensure rather than only after creating the directory: an install that
    -- predates this already has its directories, and would otherwise never get the marker.
    _ensureNoMedia(dir)
    return dir
end

function BaseCache:_safeCopy(from, to)
    local ok = os.rename(from, to)
    if not ok then
        -- ffiUtil.copyFile never raises: it returns an error string on failure and nil on
        -- success, so pcall's own result says nothing about whether the copy happened.
        local copy_ok, copy_err = pcall(ffiUtil.copyFile, from, to)
        if copy_ok and copy_err == nil then
            util.removeFile(from)
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

function KVCache:get(key, cache_expiry, skip_rm)
    if not self._cache or type(key) ~= "string" then return nil end
    local entry = self._cache:readSetting(key)
    -- _at comes out of a LuaSettings file that can be hand-edited or corrupted; arithmetic on a
    -- non-number would raise, so coerce first and treat anything uncoercible as a miss.
    local at = type(entry) == "table" and tonumber(entry._at) or nil
    if not at then
        if entry and not skip_rm then self:remove(key) end
        return nil
    end

    local expiry = tonumber(cache_expiry) or DEF_TTL_CACHE_EXPIRY
    local diff = os.time() - at
    if diff < 0 or (expiry > 0 and diff > expiry) then
        if not skip_rm then self:remove(key) end
        return nil
    end
    return entry.data
end

function KVCache:remove(key)
    if not self._cache or type(key) ~= "string" or not self._cache.delSetting then return false end
    self._cache:delSetting(key)
    if self._cache.data and not next(self._cache.data) then
        self:clear()
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
end

function BookInfoCache:getPath(book_hash)
    return ("%s/%s_info.lua"):format(self._target_dir, book_hash or "")
end

function BookInfoCache:insert(book_hash, info_table)
    if not _isValidBookHash(book_hash) or type(info_table) ~= "table" then return false end
    self:_ensurePath(self._target_dir)
    local path = self:getPath(book_hash)
    local book_cache = LuaSettings:open(path)
    book_cache:saveSetting("info", info_table)
    book_cache:saveSetting("_at", os.time())
    book_cache:flush()
    return true
end

function BookInfoCache:get(book_hash, cache_expiry, skip_rm)
    if not _isValidBookHash(book_hash) then return nil end
    local path = self:getPath(book_hash)
    if not util.fileExists(path) then return nil end

    local book_cache = LuaSettings:open(path)
    local info = book_cache:readSetting("info")
    if not info then
        if not skip_rm then book_cache:purge() end
        return nil 
    end

    -- Same coercion as KVCache:get: a non-numeric _at in a hand-edited file is treated as
    -- expired rather than raised on.
    local _at = tonumber(book_cache:readSetting("_at"))
    if type(cache_expiry) == "number" then
        if not _at then
            if not skip_rm then book_cache:purge() end
            return nil
        end
        local diff = os.time() - _at
        if diff < 0 or (cache_expiry > 0 and diff > cache_expiry) then
            if not skip_rm then book_cache:purge() end
            return nil
        end
    end
    return info
end

function BookInfoCache:remove(book_hash)
    if not _isValidBookHash(book_hash) then return false end
    local path = self:getPath(book_hash)
    if util.fileExists(path) then
        return os.remove(path)
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
end

function CoverCache:getPath(book_hash)
    return ("%s/%s.jpg"):format(self._target_dir, book_hash or "")
end

function CoverCache:getTempPath(book_hash)
    if not _isValidBookHash(book_hash) then return nil end
    self:_ensurePath(self._target_dir)
    return ("%s/%s.jpg.downloading"):format(self._target_dir, book_hash)
end

function CoverCache:insert(book_hash, source_file_path)
    if not _isValidBookHash(book_hash) or type(source_file_path) ~= "string" then return false end
    if not util.fileExists(source_file_path) then return false end
    self:_ensurePath(self._target_dir)
    local target_path = self:getPath(book_hash)
    if self:_safeCopy(source_file_path, target_path) then
        return target_path
    end
    return false
end

function CoverCache:get(book_hash, cache_expiry)
    if not _isValidBookHash(book_hash) then return nil end
    local path = self:getPath(book_hash)
    if util.fileExists(path) then 
        if type(cache_expiry) == "number" then
            local attr = lfs.attributes(path)
            local file_time = attr and (attr.modification or attr.access)
            if type(file_time) ~= "number" then return path end
            local diff = os.time() - file_time
             if diff < 0 or (cache_expiry > 0 and diff > cache_expiry) then
                self:remove(book_hash)
                return nil
            end
        end
        return path 
    end
    return nil
end

function CoverCache:remove(book_hash)
    if not _isValidBookHash(book_hash) then return false end
    local path = self:getPath(book_hash)
    local temp_path = self:getTempPath(book_hash)
    
    local deleted = false
    if util.fileExists(path) and util.removeFile(path) then deleted = true end
    if util.fileExists(temp_path) then util.removeFile(temp_path) end
    
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

    -- Keyed by name for kv, because that is what decides which file it opens: two callers asking
    -- for "_domains_cache" want the same cache, and building one each meant two LuaSettings copies
    -- of one file, each unaware of the other's writes -- so the later flush quietly undid the
    -- earlier one, and the menu's "clear domains cache" could be written straight back by a
    -- discovery run still holding the old table. Re-reading and re-parsing the file on every call
    -- was the cheaper half of the problem: getSeedUrls builds one on each call, inside a sweep.
    local instance_key = ctype == "kv" and ("kv:" .. tostring(o.name or "default_kv")) or ctype
    if _instances[instance_key] then
        return _instances[instance_key]
    end

    if ctype == "kv" then
        local obj = setmetatable(o, KVCache)
        if obj.init then obj:init() end
        _instances[instance_key] = obj
        return obj
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

-- The store that remembers when the last sweep ran is passed in rather than fetched.
--
-- Reaching for Config here made the two modules require each other: config needs Cache because
-- it constructs cache instances, and this was the only thing pulling the other way. The cycle
-- was real but hidden, deferred to call time by requiring inside the function, which meant it
-- worked while leaving the modules mutually dependent. Cache is a leaf again now.
function M.autoCacheCleanup(timestamp_store)
    if not timestamp_store then
        logger.warn("Cache.autoCacheCleanup - called with no timestamp store, skipping the sweep")
        return
    end
    local CACHE_CLEAN_INTERVAL = 86400
    local current_time = os.time()
    local last_cleaned_at = tonumber(timestamp_store:get("last_cleaned_at"))
    if not last_cleaned_at or (current_time - last_cleaned_at) > CACHE_CLEAN_INTERVAL then
        timestamp_store:insert("last_cleaned_at", os.time())
        logger.info("Cache: Starting global GC clean...")
        local cover_cache = M:new({type="cover"})
        cover_cache:gc_clean()
        local info_cache = M:new({type="bookinfo"})
        info_cache:gc_clean()
        logger.info("Cache: Global GC clean finished.")
    end
end

return M