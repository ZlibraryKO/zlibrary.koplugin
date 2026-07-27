-- Do view settings survive, and does the one-time migration behave?
--
-- View settings used to live in the runtime KV cache, whose default TTL is five days: five days
-- after the last save they were treated as expired, deleted, and the UI silently reverted to
-- defaults. They now live in the persistent settings file, with a one-time read-through
-- migration of the legacy cache entry. The seams that must hold:
--
--   * a persistent setting wins and the cache is not even consulted -- otherwise a stale cache
--     entry could migrate over a newer choice
--   * with no persistent setting, a legacy cache entry is returned, saved to settings, and
--     removed from the cache -- so the migration runs once and "Clear runtime cache" can no
--     longer take the settings with it
--   * neither present means defaults ({}), and nothing is written
--   * setViewSettings writes the settings file and drops the legacy entry, leaving a single
--     source of truth
--
-- The functions are extracted from the real config.lua; their Config collaborators
-- (getSetting/saveSetting, covered by base_url_harness) are stubbed on the injected table.

local PLUGIN = assert(arg[1], "usage: luajit view_settings_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local CONFIG = PLUGIN .. "/zlibrary/config.lua"

-- Both functions assign to fields of the Config table passed in, so one compile covers both.
-- Each extracted block stops short of its closing 'end', so each gets its own.
local function compile(Config)
    local body = support.extract_block(CONFIG, "(\nfunction Config%.setViewSettings%(.-\n)end\n") .. "end\n"
        .. support.extract_block(CONFIG, "(\nfunction Config%.getViewSettings%(.-\n)end\n") .. "end\n"
    local chunk = assert(loadstring("local Config = ...\n" .. body .. "return Config",
                                    "=view_settings"))
    setfenv(chunk, { type = type })
    return chunk(Config)
end

local function newRig(persistent, legacy)
    local rig = {
        store = { zlibrary_view_settings = persistent },
        saved = {}, removed = {}, cache_gets = 0,
    }
    local Config = {
        SETTINGS_VIEW_SETTINGS_KEY = "zlibrary_view_settings",
        -- config.lua calls these dot-style: Config.getSetting(key), not Config:getSetting(key).
        getSetting = function(key) return rig.store[key] end,
        saveSetting = function(key, value)
            rig.store[key] = value
            table.insert(rig.saved, { key = key, value = value })
        end,
        getConfigRuntimeCache = function()
            return {
                get = function(_, key, _)
                    rig.cache_gets = rig.cache_gets + 1
                    return key == "view_settings" and legacy or nil
                end,
                remove = function(_, key) table.insert(rig.removed, key) return true end,
            }
        end,
    }
    rig.Config = compile(Config)
    return rig
end

-- ---------------------------------------------------------------- persistent setting wins
do
    local kept = { search_per_page = 10, browse_per_page = 8 }
    local rig = newRig(kept, { search_per_page = 4 }) -- a stale legacy entry lurks
    local got = rig.Config.getViewSettings()
    r.check("a persistent view-settings table is returned as-is",
            got == kept, "did not get the persistent table")
    r.check("and the legacy cache is not even consulted",
            rig.cache_gets == 0, "cache consulted " .. rig.cache_gets .. " times")
    r.check("and nothing is migrated over it",
            #rig.saved == 0 and #rig.removed == 0,
            string.format("saved=%d removed=%d", #rig.saved, #rig.removed))
end

-- ---------------------------------------------------------------- legacy entry migrates once
do
    local legacy = { search_per_page = 12, show_cover_browse = false }
    local rig = newRig(nil, legacy)
    local got = rig.Config.getViewSettings()
    r.check("with no persistent setting the legacy cache entry is returned",
            got == legacy, "did not get the legacy table")
    r.check("and saved to the persistent settings under the view-settings key",
            #rig.saved == 1 and rig.saved[1].key == "zlibrary_view_settings"
                and rig.saved[1].value == legacy,
            "saved: " .. #rig.saved)
    r.check("and removed from the runtime cache, so clearing the cache can no longer lose it",
            #rig.removed == 1 and rig.removed[1] == "view_settings",
            "removed: " .. #rig.removed)

    local got_again = rig.Config.getViewSettings()
    r.check("the second read comes from the settings file, not the cache",
            got_again == legacy and rig.cache_gets == 1,
            "cache consulted " .. rig.cache_gets .. " times -- the migration is replaying")
end

-- ---------------------------------------------------------------- neither present: defaults, no writes
do
    local rig = newRig(nil, nil)
    local got = rig.Config.getViewSettings()
    r.check("with nothing stored the default is an empty table",
            type(got) == "table" and next(got) == nil, "got " .. tostring(got))
    r.check("and a fresh install writes nothing",
            #rig.saved == 0 and #rig.removed == 0,
            string.format("saved=%d removed=%d", #rig.saved, #rig.removed))
end

-- ---------------------------------------------------------------- setViewSettings: single source of truth
do
    local rig = newRig(nil, { search_per_page = 4 })
    local opts = { browse_per_page = 16 }
    rig.Config.setViewSettings(opts)
    r.check("setViewSettings saves to the persistent settings",
            #rig.saved == 1 and rig.saved[1].key == "zlibrary_view_settings"
                and rig.saved[1].value == opts,
            "saved: " .. #rig.saved)
    r.check("and drops the legacy cache entry",
            #rig.removed == 1 and rig.removed[1] == "view_settings",
            "removed: " .. #rig.removed)

    local rig_nil = newRig(nil, nil)
    rig_nil.Config.setViewSettings(nil)
    r.check("a non-table argument is stored as an empty table, not nil",
            #rig_nil.saved == 1 and type(rig_nil.saved[1].value) == "table",
            "saved value: " .. tostring(rig_nil.saved[1] and rig_nil.saved[1].value))
end

r.finish()
