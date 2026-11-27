-- The update notice: after a list of books appears, does the plugin check for a new release
-- quietly, at most once a day, and offer each new version once?
--
-- Until 1.0.65 the plugin only updated when a reader opened "Check for updates". After the search
-- outage of 2026-11-23, fixes shipped within a day, but readers who never open that menu kept the
-- broken plugin. Ota.maybeNotifyUpdate closes that gap, and its value depends on staying out of
-- the way: no Wi-Fi prompt, no loading message, no trap for taps, nothing shown unless there is
-- something to offer, and no offer repeated.
--
-- Drives the real Ota.maybeNotifyUpdate and Ota._offerUpdate from zlibrary/ota.lua with stubbed
-- KOReader modules, a scripted release, a fake clock and a fake background channel.

local PLUGIN = assert(arg[1], "usage: luajit update_notice_harness.lua <plugin-root> <luasocket-src>")

local support = dofile(PLUGIN .. "/test/support.lua")
local r = support.reporter()

local OTA = PLUGIN .. "/zlibrary/ota.lua"
local DAY = 24 * 60 * 60
local PATH = "/data/plugins/zlibrary.koplugin/"

local function release(tag)
    return { tag_name = tag, assets = {
        { name = "zlibrary_plugin_" .. tag .. ".zip",
          browser_download_url = "https://github.example/zlibrary_plugin_" .. tag .. ".zip" },
    } }
end

-- opts: installed, latest (a tag, or false for a failing check), connected, notice (setting),
-- now (clock), settings (initial stored values).
local function newRig(opts)
    opts = opts or {}
    local rig = {
        now = opts.now or 1000000000,
        connected = opts.connected ~= false,
        notice = opts.notice ~= false,
        latest = opts.latest == nil and "v1.0.65" or opts.latest,
        settings = opts.settings or {},
        fetches = 0, shown = {}, finals = {}, wifi_asks = 0, loading = 0, channels = 0,
        pending = opts.pending, downloading = opts.downloading or false,
    }
    local env = setmetatable({
        logger = { dbg = function() end, info = function() end, err = function() end, warn = function() end },
        T = function(s) return s end,
        os = setmetatable({ time = function() return rig.now end }, { __index = os }),
        NetworkMgr = {
            isConnected = function() return rig.connected end,
            willRerunWhenOnline = function() rig.wifi_asks = rig.wifi_asks + 1; return false end,
        },
        Config = {
            SETTINGS_UPDATE_NOTICE_LAST_CHECK_KEY = "last",
            SETTINGS_UPDATE_NOTICE_OFFERED_KEY = "offered",
            getUpdateNotice = function() return rig.notice end,
            getSetting = function(k) return rig.settings[k] end,
            saveSetting = function(k, v) rig.settings[k] = v end,
            deleteSetting = function(k) rig.settings[k] = nil end,
        },
        Download = { isActive = function() return rig.downloading end },
        Ui = { showCancellableLoadingMessage = function() rig.loading = rig.loading + 1; return {} end },
        UIManager = { show = function(_, w) table.insert(rig.shown, w) end },
        ConfirmBox = { new = function(_, spec) return spec end },
        -- The background channel runs the task right away and hands the callback what the real
        -- one does: success and the task's result.
        AsyncHelper = {
            createChannel = function()
                rig.channels = rig.channels + 1
                return { pushTask = function(_, task, callback)
                    local ok, res = pcall(task)
                    callback(ok and not (type(res) == "table" and res.error), res)
                end }
            end,
            runCancellable = function() error("the notice must not use runCancellable: it traps taps") end,
        },
        selectUpdateAsset = support.extract_function(OTA, "selectUpdateAsset", {
            type = type, ipairs = ipairs,
            UPDATE_ASSET_NAME_PATTERN = assert(loadstring("return " .. support.extract_block(OTA,
                "\nlocal UPDATE_ASSET_NAME_PATTERN = (\"[^\n]-\")\n")))(),
        }),
        isVersionOlder = support.extract_function(OTA, "isVersionOlder", {
            string = string, table = table, math = math, tonumber = tonumber }),
        getCurrentPluginVersion = function() return opts.installed or "1.0.64" end,
        _show_ota_final_message = function(text) table.insert(rig.finals, text) end,
        _close_current_ota_status_widget = function() end,
    }, { __index = _G })
    local body = support.extract_block(OTA, "(\nlocal function _fetchReleaseSummary%(.-\n)return Ota")
    local chunk = assert(loadstring("local Ota = {}\n" .. body .. "return Ota", "=ota"))
    setfenv(chunk, env)
    rig.Ota = chunk()
    rig.Ota.pendingRestartVersion = function() return rig.pending end
    rig.Ota.fetchLatestReleaseInfo = function()
        rig.fetches = rig.fetches + 1
        if rig.start_download_during_fetch then rig.downloading = true end
        if not rig.latest then return { error = "HTTP Error: 403 (rate limited)" } end
        return { release_info = release(rig.latest) }
    end
    rig.show_list = function(path) rig.Ota.maybeNotifyUpdate(path or PATH) end
    return rig
end

local function offered(rig)
    local dialog = rig.shown[#rig.shown]
    return dialog and dialog.title == "Update available" and dialog.text or nil
end

-- ---------------------------------------------------------------- a new version is offered
do
    local rig = newRig()
    rig.show_list()
    r.check("a newer release is offered after a list appears",
            #rig.shown == 1 and offered(rig) ~= nil and offered(rig):find("1.0.65", 1, true) ~= nil,
            "shown " .. #rig.shown)
    r.check("and the offer names the installed version too",
            offered(rig) ~= nil and offered(rig):find("1.0.64", 1, true) ~= nil)
    r.check("while checking, no loading message and no Wi-Fi prompt",
            rig.loading == 0 and rig.wifi_asks == 0,
            string.format("loading %d, wifi asks %d", rig.loading, rig.wifi_asks))
    r.check("the version is remembered as offered", rig.settings.offered == "1.0.65",
            tostring(rig.settings.offered))
end

-- ---------------------------------------------------------------- once a day
do
    local rig = newRig()
    rig.show_list()
    rig.now = rig.now + DAY - 60
    rig.show_list()
    r.check("a second list within the day makes no request", rig.fetches == 1, "fetches " .. rig.fetches)
    rig.now = rig.now + 120
    rig.show_list()
    r.check("a list a day later checks again", rig.fetches == 2, "fetches " .. rig.fetches)

    local skewed = newRig({ now = 1000, settings = { last = 5000 } })
    skewed.show_list()
    r.check("a clock that went backwards does not stop checks for good", skewed.fetches == 1,
            "fetches " .. skewed.fetches)
end

-- ---------------------------------------------------------------- offered once
do
    local rig = newRig({ settings = { offered = "1.0.65" } })
    rig.show_list()
    r.check("a version offered before is not offered again", rig.fetches == 1 and #rig.shown == 0,
            string.format("fetches %d, shown %d", rig.fetches, #rig.shown))

    rig.latest = "v1.0.66"
    rig.now = rig.now + DAY + 1
    rig.show_list()
    r.check("but the next version is", offered(rig) ~= nil and offered(rig):find("1.0.66", 1, true) ~= nil)
end

-- ---------------------------------------------------------------- nothing to offer: silence
do
    local current = newRig({ installed = "1.0.65" })
    current.show_list()
    r.check("an up-to-date plugin shows nothing", #current.shown == 0 and #current.finals == 0,
            string.format("shown %d, messages %d", #current.shown, #current.finals))

    local failing = newRig({ latest = false })
    failing.show_list()
    r.check("a failing check shows nothing", #failing.shown == 0 and #failing.finals == 0,
            string.format("shown %d, messages %d", #failing.shown, #failing.finals))
    r.check("and is not retried within the day", (function()
        failing.show_list(); return failing.fetches == 1 end)(), "fetches " .. failing.fetches)

    local odd = newRig({ latest = "nightly" })
    odd.show_list()
    r.check("a release tag it cannot read shows nothing", #odd.shown == 0 and #odd.finals == 0,
            string.format("shown %d, messages %d", #odd.shown, #odd.finals))
end

-- ---------------------------------------------------------------- when it does not run
do
    local offline = newRig({ connected = false })
    offline.show_list()
    r.check("offline: no request and no Wi-Fi prompt", offline.fetches == 0 and offline.wifi_asks == 0,
            string.format("fetches %d, wifi asks %d", offline.fetches, offline.wifi_asks))
    r.check("and the day is not used up", offline.settings.last == nil, tostring(offline.settings.last))

    local off = newRig({ notice = false })
    off.show_list()
    r.check("with the setting off, nothing is checked", off.fetches == 0, "fetches " .. off.fetches)

    local elsewhere = newRig()
    elsewhere.show_list("/mnt/us/extensions/zlib/")
    r.check("an unsupported install location is not checked", elsewhere.fetches == 0,
            "fetches " .. elsewhere.fetches)
end

-- ---------------------------------------------------------------- the manual check is unchanged
do
    local rig = newRig({ installed = "1.0.65" })
    rig.Ota._offerUpdate(PATH, release("v1.0.65"))
    r.check("Check for updates still says when the plugin is current",
            #rig.finals == 1 and rig.finals[1]:find("already on the latest version", 1, true) ~= nil,
            tostring(rig.finals[1]))
    local again = newRig({ settings = { offered = "1.0.65" } })
    again.Ota._offerUpdate(PATH, release("v1.0.65"))
    r.check("and still offers a version the notice offered before", offered(again) ~= nil)
end

-- ---------------------------------------------------------------- an update waits for a restart
do
    local rig = newRig({ pending = "1.0.65" })
    rig.show_list()
    r.check("no notice while an installed update waits for the restart",
            rig.fetches == 0 and #rig.shown == 0 and rig.settings.last == nil,
            string.format("fetches %d, shown %d", rig.fetches, #rig.shown))
end

-- ---------------------------------------------------------------- not over a download
do
    local rig = newRig({ downloading = true })
    rig.show_list()
    r.check("no check while a book downloads, and none recorded",
            rig.fetches == 0 and #rig.shown == 0 and rig.settings.last == nil,
            string.format("fetches %d, last %s", rig.fetches, tostring(rig.settings.last)))
    rig.downloading = false
    rig.show_list()
    r.check("the next list after the download checks and offers",
            rig.fetches == 1 and offered(rig) ~= nil, "fetches " .. rig.fetches)
end

do
    local rig = newRig()
    rig.start_download_during_fetch = true
    rig.show_list()
    r.check("a download that started during the check holds the offer back",
            #rig.shown == 0 and rig.settings.offered == nil, "shown " .. #rig.shown)
    r.check("and forgets the check, so the next list asks again",
            rig.settings.last == nil, tostring(rig.settings.last))
    rig.start_download_during_fetch, rig.downloading = false, false
    rig.show_list()
    r.check("which then offers it", offered(rig) ~= nil and rig.settings.offered == "1.0.65")
end

-- ---------------------------------------------------------------- nothing loads after startup
-- An update installed without restarting KOReader swaps the plugin's files on disk while the old
-- version keeps running. A module loaded for the first time after that would be the new version
-- inside the old one. Book details used to load on first use; now nothing does. A require inside
-- a function body is allowed only for modules loaded at startup anyway, or during startup itself.
do
    local allowed = {
        ["zlibrary/async_helper.lua:zlibrary.config"] = true, -- loaded at startup; a forked child's handle
        ["main.lua:zlibrary.preloader"] = true,               -- Zlibrary:init, at startup
        ['main.lua:zlibrary." .. part'] = true,               -- the plugin_* parts, at load
    }
    local late = {}
    local files = { "main.lua" }
    for name in io.popen('ls "' .. PLUGIN .. '/zlibrary"'):lines() do
        if name:match("%.lua$") then table.insert(files, "zlibrary/" .. name) end
    end
    for _, rel in ipairs(files) do
        local n = 0
        for line in io.lines(PLUGIN .. "/" .. rel) do
            n = n + 1
            local mod = line:match('^%s%s%s%s+.-require%("(zlibrary%.[^)]-)%)')
            if mod and not line:match("^%s*%-%-") then
                mod = mod:gsub('"$', "")
                if not allowed[rel .. ":" .. mod] then table.insert(late, rel .. ":" .. n .. " " .. mod) end
            end
        end
    end
    r.check("no plugin module is loaded for the first time after startup", #late == 0,
            table.concat(late, ", "))
end

r.finish()
